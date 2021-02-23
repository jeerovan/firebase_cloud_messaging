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
    start ->
      gproc:reg({p,l,processes}),
      gproc:reg({p,l,fcm_process}),
      self() ! connect,
      fcm(State#{created => erlang:system_time(seconds),
                 connection_state => {init,erlang:system_time(seconds)}});
    connect ->
      UpperBound = filesettings:get(fcm_process_pool_upper_bound,95),
      LowerBound = filesettings:get(fcm_process_pool_lower_bound,50),
      applog:info(?MODULE,"Connecting~n",[]),
      NewState =
        case ssl:connect(?HOST,5235,[binary,{active,true}]) of
          {ok,Socket} ->
            ssl:send(Socket,?INIT),
            State#{socket => Socket,
                   state => connecting,
                   created => erlang:system_time(seconds),
                   connection_state => {init,erlang:system_time(seconds)},
                   upper_bound => UpperBound,
                   lower_bound => LowerBound,
                   pool => 0,
                   packet => <<>>};
          Error ->
            self() ! connect,
            applog:info(?MODULE,"~p:Error Connecting:~p~n",[self(),Error]),
            timer:sleep(5000),
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
          State;
        IsSuccess ->
          ssl:send(Socket,?INIT),
          State;
        IsBind ->
          ssl:send(Socket,?BIND),
          State;
        IsConnected ->
          applog:info(?MODULE,"~p:Connected~n",[self()]),
          self() ! start_acker,
          State#{state => connected,
                 connection_state => {active,erlang:system_time(seconds)}};
        binary_part(Packet,{byte_size(Packet),-10}) =:= <<"</message>">> ->
          applog:verbose(?MODULE,"~p:Received Ended Message:~p~n",[self(),Packet]),
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
          applog:verbose(?MODULE,"~p:Received Begun Message:~p~n",[self(),Packet]),
          #{packet := PreviousPacket} = State,
          NewPacket = <<PreviousPacket/binary,Packet/binary>>,
          State#{packet => NewPacket};
        true ->
          #{packet := PreviousPacket} = State,
          NewPacket = 
            case PreviousPacket of
              <<>> ->
                applog:error(?MODULE,"~p:Unhandled -> ~p~n",[self(),Packet]),
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
      applog:error(?MODULE,"~p:SSL closed,Reconnting After ~p State~n",[self(),S]),
      self() ! reconnect,
      fcm(State);
    start_acker ->
      #{socket := Socket} = State,
      Acker = spawn(fcm_acker,acker,[Socket]),
      fcm_manager:add_fcm_process(self()),
      fcm(State#{acker => Acker});
    {send_message,FcmId,DataMap} ->
      #{state := S,pool := Pool,acker := Acker} = State,
      case true of
        true when S =:= connected, Pool < 99 ->
          applog:verbose(out,"~p~n",[DataMap]),
          Map = get_message_map(FcmId,DataMap),
          Acker ! {send_message,Map},
          timeout:update_fcm_id_send_time(FcmId,false);
        true ->
          self() ! unreserve_pool
      end,
      fcm(State);
    unreserve_pool ->
      #{pool := Pool,
        lower_bound := PoolLowerBound,
        state := Status} = State,
      NewPool = if Pool > 0 -> Pool - 1; true -> 0 end,
      case true of
        true when NewPool =:= 0, Status =:= closing ->
          applog:info(?MODULE,"~p:Was Closing, Pool Became Zero,reconnecting~n",[self()]),
          self() ! reconnect;
        true when NewPool < PoolLowerBound, Status =/= closing ->
          fcm_manager:add_fcm_process(self());
        true ->
          ok
      end,
      fcm(State#{pool => NewPool});
    connection_closing ->
      fcm_manager:remove_fcm_process(self()),
      #{pool := Pool} = State,
      case Pool =:= 0 of
        true ->
          self() ! reconnect;
        false ->
          applog:info(?MODULE,"~p->Connection Closing But Pool Not 0~n",[self()])
      end,
      fcm(State#{connection_state => {closing,erlang:system_time(seconds)},state => closing});
    reserve_pool ->
      #{pool := Pool, upper_bound := PoolUpperBound} = State,
      NewPool = Pool + 1,
      case NewPool > PoolUpperBound of
        true ->
          fcm_manager:remove_fcm_process(self());
        false ->
          ok
      end,
      fcm(State#{pool => NewPool});
    reconnect ->
      %--- Stop Acker --
      Acker = maps:get(acker,State,notfound),
      case Acker of
        notfound ->
          applog:error(?MODULE,"~p:Acker Not Found,Reconnecting~n",[self()]);
        _ ->
          Acker ! stop
      end,
      %--- Stop FCM Process --
      Socket = maps:get(socket,State,notfound),
      case Socket of
        notfound ->
          applog:error(?MODULE,"~p:Socket Not Found While Reconnecting~n",[self()]);
        _ ->
          applog:info(?MODULE,"~p:Closing SSL.~n",[self()]),
          fcm_manager:remove_fcm_process(self()),
          ssl:close(Socket)
      end,
      self() ! connect,
      fcm(State#{state => connecting,acker => notfound,socket => notfound});
    disconnect ->
      %--- Stop Acker --
      Acker = maps:get(acker,State,notfound),
      case Acker of
        notfound ->
          ok;
        _ ->
          Acker ! stop
      end,
      case maps:get(socket,State,notfound) of
        notfound ->
          ok;
        Socket ->
          fcm_manager:remove_fcm_process(self()),
          ssl:close(Socket)
      end;
    {ssl_error, _, Reason} ->
      applog:error(?MODULE,"~p:SSL Error : ~p~n",[self(),Reason]),
      self() ! reconnect,
      fcm(State);
    {process_xml,XMLs} ->
      #{acker := Acker} = State,
      [ begin
          <<">",PD/binary>> = XML,
          Data = binary:replace(PD,<<"<">>,<<>>,[global]),
          AllData = jsx:decode(Data,[return_maps]),
          %-------- Check if its a control message about connection draining --------
          case maps:get(<<"message_type">>,AllData,notfound) of
            notfound ->
              #{<<"message_id">> := Mid,<<"from">> := From,<<"data">> := #{<<"data">> := JsonDataString}} = AllData,
              Ack = get_ack_message(Mid,From),
              Acker ! {send_message,Ack},
              IncomingCounter = ets:update_counter(sequences,incoming_message_counter,{2,1},{incoming_message_counter,0}),
              JsonData = jsx:decode(JsonDataString,[return_maps]),
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
              ShouldRetry =
                case NackError of
                  <<"DEVICE_UNREGISTERED">> ->
                    IncomingMessage = #{<<"type">> => <<"fcm_id_deregistered">>,<<"fcm_id">> => FcmId},
                    IncomingCounter = ets:update_counter(sequences,incoming_message_counter,{2,1},{incoming_message_counter,0}),
                    ets:insert(incoming_message,{IncomingCounter,IncomingMessage}),
                    fcm_manager:set_device_unregistered(FcmId),
                    false;
                  <<"INTERNAL_SERVER_ERROR">> ->
                    applog:error(?MODULE,"~p:Internal Server Error While Processing:~p~n",[self(),AllData]),
                    self() ! connection_closing,
                    true;
                  <<"CONNECTION_DRAINING">> ->
                    applog:error(?MODULE,"~p:Connection Draining~n",[self()]),
                    self() ! connection_closing,
                    true;
                  <<"SERVICE_UNAVAILABLE">> ->
                    applog:error(?MODULE,"~p:Service Unavailable~n",[self()]),
                    self() ! connection_closing,
                    true;
                  <<"DEVICE_MESSAGE_RATE_EXCEEDED">> ->
                    applog:error(?MODULE,"~p:Device Message Rate Exceeded For:~p~n",[self(),FcmId]),
                    timeout:update_fcm_id_send_time(FcmId,true),
                    false;
                  _ ->
                    applog:error(?MODULE,"UNHANDLED NACK ERROR:~p~nData:~p~n",[NackError,AllData]),
                    false
                end,
              case ShouldRetry of
                true ->
                %------- Try To Resend Nacked Message -----
                case ets:lookup(fcm_sent_messages,NackedMessageIdInt) of
                  [] ->
                    ok;
                  [{NackedMessageIdInt,FcmId,DataMap,_SentAt}] ->
                    %------- Do Not Re-Use MessageIds,They Are Unique To FcmConnection-----
                    downstream:create(FcmId,DataMap)
                end;
                false ->
                  ok
              end,
              ets:delete(fcm_sent_messages,NackedMessageIdInt);
            <<"control">> ->
              applog:error(?MODULE,"~p:Received CONTROL, Disconnecting.~n",[self()]),
              self() ! connection_closing;
            UnknownMessageType ->
              applog:error(?MODULE,"Unknown message_type:~p~n",[UnknownMessageType])
          end
        end
        ||
        [XML] <- XMLs],
      fcm(State#{connection_state => {active,erlang:system_time(seconds)}});
    {application_variable_update,Name,Value} ->
      NewState =
        case maps:is_key(Name,State) of
          true ->
            State#{Name => Value};
          false ->
            State
        end,
      fcm(NewState);
    {send_connection_state,From} ->
      #{connection_state := ConnectionState,created := CreatedAt} = State,
      From ! {fcm_state,self(),CreatedAt,ConnectionState},
      fcm(State);
    send_stats ->
      #{pool := Pool} = State,
      gproc:send({p,l,statsocket},{fcm_process,self(),Pool}),
      fcm(State);
    Unknown ->
      applog:error(?MODULE,"Unknown Message:~p~n",[Unknown]),
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
  Priority = maps:get(<<"priority">>,DataMap,<<"normal">>),
  Json = #{<<"to">> => FcmId,
           <<"message_id">> => MID,
           <<"data">> => DataMap,
           <<"priority">> => Priority,
           <<"time_to_live">> => 0},
  Payload = jsx:encode(Json),
  <<"<message id='",MID/binary,"'><gcm xmlns='google:mobile:data'>",Payload/binary,"</gcm></message>">>.
