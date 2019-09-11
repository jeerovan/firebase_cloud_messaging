-module(fcm_process).
-export([fcm/1]).

-define(INIT,<<"<stream:stream to='gcm.googleapis.com' version='1.0' "
                  "xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>">>).
-define(AUTH_SASL(B64), <<"<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' "
                                "mechanism='PLAIN'>", B64/binary, "</auth>">>).

-define(BIND, <<"<iq type='set'>"
                   "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                "</bind></iq>">>).
-define(HOST,"fcm-xmpp.googleapis.com").

fcm(State) ->
  receive
    connect ->
      gproc:reg({p,l,processes}),
      gproc:reg({p,l,fcm_process}),
      UpperBound = filesettings:get(fcm_process_pool_upper_bound,95),
      LowerBound = filesettings:get(fcm_process_pool_lower_bound,50),
      NewState =
        case ssl:connect(?HOST,5235,[binary,{active,true}]) of
          {ok,Socket} ->
            ssl:send(Socket,?INIT),
            State#{socket => Socket,
                   state => connecting,
                   connection_state => {init,erlang:system_time(seconds)},
                   upper_bound => UpperBound,
                   lower_bound => LowerBound,
                   overflow => false,
                   pool => 0,
                   packet => <<>>};
          Error ->
            self() ! disconnect,
            applog:error(?MODULE,"Error Connecting SSL:~p~n",[Error]),
            State#{state => connecting}
        end,
      fcm(NewState);
    {ssl,Socket,Packet} ->
      IsMechanism = re:run(Packet,<<"</mechanism></mechanisms>">>) =/= nomatch,
      IsSuccess = re:run(Packet,<<"<success">>) =/= nomatch,
      IsBind = re:run(Packet,<<"<stream:features><bind">>) =/= nomatch,
      IsConnected = re:run(Packet,<<"<jid>">>) =/= nomatch,
      NewState = if
        Packet =:= <<" ">> ->
          State#{connection_state => {idle,erlang:system_time(seconds)}};
        IsMechanism ->
          {ServerId,ServerPassword} = {list_to_binary(filesettings:get(fcm_sender_id,"")),
                                       list_to_binary(filesettings:get(fcm_server_key,""))},
          B64 = base64:encode(<<0, ServerId/binary, 0, ServerPassword/binary>>),
          ssl:send(Socket,?AUTH_SASL(B64)),
          State#{state => authenticating};
        IsSuccess ->
          ssl:send(Socket,?INIT),
          State#{state => binding};
        IsBind ->
          ssl:send(Socket,?BIND),
          State;
        IsConnected ->
          applog:info(?MODULE,"Connected~n",[]),
          self() ! start_acker,
          State#{state => connected,
                 connection_state => {active,erlang:system_time(seconds)}};
        binary_part(Packet,{byte_size(Packet),-10}) =:= <<"</message>">> ->
          #{packet := PreviousPacket} = State,
          NewPacket = <<PreviousPacket/binary,Packet/binary>>,
          case re:run(NewPacket,">{(.*?)}<",[global,{capture,first,binary}]) of
            {match,XMLs} ->
              self() ! {process_xml,XMLs};
            _ ->
              ok
          end,
          State#{packet => <<>>};
        binary_part(Packet,{0,8}) =:= <<"<message">> ->
          #{packet := PreviousPacket} = State,
          NewPacket = <<PreviousPacket/binary,Packet/binary>>,
          State#{packet => NewPacket};
        true ->
          #{packet := PreviousPacket} = State,
          NewPacket = 
            case PreviousPacket of
              <<>> ->
                applog:verbose(?MODULE,"Unhandled -> ~p~n",[Packet]),
                <<>>;
              _ ->
                <<PreviousPacket/binary,Packet/binary>>
            end,
          State#{packet => NewPacket}
      end,
      fcm(NewState);
    {ssl_closed,_} ->
      fcm_manager:remove_fcm_process(self()),
      #{state := S} = State,
      case S of
        disconnected ->
          self() ! disconnect;
        connecting ->
          self() ! disconnect;
        authenticating ->
          self() ! disconnect;
        binding ->
          self() ! disconnect;
        connected ->
          self() ! reconnect;
        closing ->
          self() ! reconnect
      end,
      fcm(State#{state => disconnected});
    start_acker ->
      #{socket := Socket} = State,
      Acker = spawn(fcm_acker,acker,[Socket]),
      fcm_manager:add_fcm_process(self()),
      fcm(State#{acker => Acker});
    {send_message,FcmId,DataMap} ->
      #{state := S,pool := Pool,acker := Acker} = State,
      case true of
        true when S =:= connected, Pool < 99 ->
          applog:verbose('OUT',"~p~n",[DataMap]),
          Map = get_message_map(FcmId,DataMap),
          Acker ! {send_message,Map},
          timeout:update_fcm_id_send_time(FcmId,false);
        true ->
          self() ! unreserve_pool
      end,
      fcm(State);
    unreserve_pool ->
      #{pool := Pool,
        overflow := Overflow,
        lower_bound := PoolLowerBound,
        state := Status} = State,
      NewPool = if Pool =:= 0 -> 0; true -> Pool - 1 end,
      NewState =
        case true of
          true when NewPool =:= 0, Status =:= closing ->
            applog:info(?MODULE,"Was Closing, Pool Became Zero,Disconnecting~n",[]),
            self() ! disconnect,
            State;
          true when NewPool < PoolLowerBound, Overflow =:= true, Status =/= closing ->
            fcm_manager:add_fcm_process(self()),
            State#{pool => NewPool,overflow => false};
          true ->
            State#{pool => NewPool}
        end,
      %---------- Send Stat ----------
      fcm(NewState);
    connection_closing ->
      fcm_manager:remove_fcm_process(self()),
      #{pool := Pool} = State,
      case Pool =:= 0 of
        true ->
          self() ! disconnect;
        false ->
          ok
      end,
      fcm(State#{state => closing});
    connection_unavailable ->
      fcm_manager:remove_fcm_process(self()),
      fcm(State#{connection_state => {unavailable,erlang:system_time(seconds)}});
    connection_available ->
      fcm_manager:add_fcm_process(self()),
      fcm(State#{connection_state => {idle,erlang:system_time(seconds)}});
    reserve_pool ->
      #{pool := Pool, upper_bound := PoolUpperBound} = State,
      NewPool = Pool + 1,
      NewState =
        case NewPool > PoolUpperBound of
          true ->
            fcm_manager:remove_fcm_process(self()),
            State#{pool => NewPool,overflow => true};
          false ->
            State#{pool => NewPool}
        end,
      fcm(NewState);
    reconnect ->
      Acker = maps:get(acker,State,notfound),
      case Acker of
        notfound ->
          ok;
        _ ->
          Acker ! stop
      end,
      gproc:unreg({p,l,processes}),
      gproc:unreg({p,l,fcm_process}),
      self() ! connect,
      fcm(State#{acker => notfound});
    {ssl_error, _, Reason} ->
      applog:error(?MODULE,"Socket Error : ~p~n",[Reason]),
      self() ! disconnect,
      fcm(State);
    disconnect ->
      %--- Stop Acker --
      Acker = maps:get(acker,State,notfound),
      case Acker of
        notfound ->
          ok;
        _ ->
          Acker ! stop
      end,
      %--- Stop FCM Process --
      Socket = maps:get(socket,State,notfound),
      case Socket of
        notfound ->
          ok;
        _ ->
          applog:info(?MODULE,"Disconnecting.~n",[]),
          ssl:close(Socket)
      end,
      case maps:get(state,State,<<>>) of
        connecting ->
          ok;
        _ ->
          fcm_manager:create_fcm_process()
      end;
    {process_xml,XMLs} ->
      #{acker := Acker} = State,
      [ begin
          <<">",PD/binary>> = XML,
          Data = binary:replace(PD,<<"<">>,<<>>,[global]),
          AllData = jsx:decode(Data,[return_maps]),
          %-------- Check if its a control message about connection draining --------
          case maps:get(<<"message_type">>,AllData,notfound) of
            notfound ->
              #{<<"message_id">> := Mid,<<"from">> := From,<<"data">> := #{<<"data">> := JsonData}} = AllData,
              Ack = get_ack_message(Mid,From),
              Acker ! {send_message,Ack},
              IncomingCounter = ets:update_counter(sequences,incoming_message_counter,{2,1},{incoming_message_counter,0}),
              IncomingMessage = #{<<"type">> => <<"upstream_data">>,<<"fcm_id">> => From,<<"data">> => JsonData},
              ets:insert(incoming_message,{IncomingCounter,IncomingMessage});
            <<"ack">> ->
              self() ! unreserve_pool,
              %------- <<"message_id">> Of Acked Message Sent ----
              #{<<"message_id">> := AckedMessageId} = AllData,
              ets:delete(fcm_sent_messages,binary_to_integer(AckedMessageId)),
              %------- registration_id may not be present always -------
              case maps:get(<<"registration_id">>,AllData,notfound) of
                notfound ->
                  ok;
                NewRegistrationId ->
                  #{<<"from">> := OldRegistrationId} = AllData,
                  IncomingMessage = #{<<"type">> => <<"fcm_id_updated">>,<<"fcm_id">> => NewRegistrationId,<<"old_fcm_id">> => OldRegistrationId},
                  IncomingCounter = ets:update_counter(sequences,incoming_message_counter,{2,1},{incoming_message_counter,0}),
                  ets:insert(incoming_message,{IncomingCounter,IncomingMessage}),
                  fcm_manager:update_registration_id(OldRegistrationId,NewRegistrationId)
              end;
            <<"nack">> ->
              self() ! unreserve_pool,
              #{<<"from">> := FcmId,<<"error">> := NackError,<<"message_id">> := NackedMessageId} = AllData,
              NackedMessageIdInt = binary_to_integer(NackedMessageId),
              case NackError of
                <<"DEVICE_UNREGISTERED">> ->
                  IncomingMessage = #{<<"type">> => <<"fcm_id_deregistered">>,<<"fcm_id">> => FcmId},
                  IncomingCounter = ets:update_counter(sequences,incoming_message_counter,{2,1},{incoming_message_counter,0}),
                  ets:insert(incoming_message,{IncomingCounter,IncomingMessage}),
                  fcm_manager:set_device_unregistered(FcmId);
                <<"INTERNAL_SERVER_ERROR">> ->
                  applog:error(?MODULE,"Internal Server Error While Processing:~p~n",[AllData]),
                  self() ! connection_closing;
                <<"SERVICE_UNAVAILABLE">> ->
                  %------- Try To Resend Nacked Message -----
                  case ets:lookup(fcm_sent_messages,NackedMessageIdInt) of
                    [] ->
                      ok;
                    [{NackedMessageIdInt,FcmId,DataMap,_SentAt}] ->
                      %------- Do Not Re-Use MessageIds,They Are Unique To FcmConnection-----
                      downstream:create(FcmId,DataMap)
                  end,
                  applog:error(?MODULE,"Service Unavailable~n",[]),
                  self() ! connection_unavailable;
                <<"DEVICE_MESSAGE_RATE_EXCEEDED">> ->
                  applog:error(?MODULE,"Device Message Rate Exceeded For:~p~n",[FcmId]),
                  timeout:update_fcm_id_send_time(FcmId,true);
                _ ->
                  applog:error(?MODULE,"UNHANDLED NACK ERROR:~p~nData:~p~n",[NackError,AllData])
              end,
              ets:delete(fcm_sent_messages,NackedMessageIdInt);
            <<"control">> ->
              applog:error(?MODULE,"Received CONTROL, Disconnecting.~n",[]),
              self() ! connection_closing;
            UnknownMessageType ->
              applog:error(?MODULE,"Unknown message_type On FCM:~p~n",[UnknownMessageType])
          end
        end
        ||
        [XML] <- XMLs],
      fcm(State#{connection_state => {active,erlang:system_time(seconds)}});
    {application_variable_update,Name,Value} ->
      NewState =
        case Name of
          fcm_process_pool_upper_bound ->
            State#{upper_bound => Value};
          fcm_process_pool_lower_bound ->
            State#{lower_bound => Value};
          _ ->
            State
        end,
      fcm(NewState);
    {send_connection_state,From} ->
      #{connection_state := ConnectionState} = State,
      From ! {fcm_state,self(),ConnectionState},
      fcm(State);
    send_stats ->
      #{pool := Pool} = State,
      gproc:send({p,l,statsocket},{fcm_process,self(),Pool}),
      fcm(State);
    Unknown ->
      applog:error(?MODULE,"Unknown Message On FCM Process : ~p~n",[Unknown]),
      self() ! disconnect,
      fcm(State)
  end.

%--------- Helper Functions ---------
get_ack_message(Mid,To) ->
  JSONPayload = #{<<"to">> => To,
                  <<"message_type">> => <<"ack">>,
                  <<"message_id">> => Mid},
  Payload = jsx:encode(JSONPayload),
  MID = integer_to_binary(ets:update_counter(sequences,fcm_ack_message_id_counter,{2,1},{fcm_ack_message_id_counter,0})),
  <<"<message id='",MID/binary,"'><gcm xmlns='google:mobile:data'>",Payload/binary,"</gcm></message>">>.

get_message_map(FcmId,DataMap) ->
  MidInt = ets:update_counter(sequences,fcm_message_id_counter,{2,1},{fcm_message_id_counter,0}),
  MID = integer_to_binary(MidInt),
  SendingAt = erlang:system_time(seconds),
  ets:insert(fcm_sent_messages,{MidInt,FcmId,DataMap,SendingAt}),
  %----- Validate These On Receiving DataMap -------
  Priority = maps:get(priority,DataMap,normal),
  Json = #{to => FcmId,
           message_id => MID,
           data => DataMap,
           priority => Priority,
           time_to_live => 0},
  Payload = jsx:encode(Json),
  <<"<message id='",MID/binary,"'><gcm xmlns='google:mobile:data'>",Payload/binary,"</gcm></message>">>.
