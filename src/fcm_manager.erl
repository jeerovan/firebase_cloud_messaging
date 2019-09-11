-module(fcm_manager).
-behaviour(gen_server).

%---- Manage Fcm Processes ----

%% API.
-export([start_link/0]).
%------- CALLS -------
-export([get_fcm_process/0]).
%------- CASTS -------

%------- DIRECT -------
-export([create_fcm_process/0,
         add_fcm_process/1,
         remove_fcm_process/1]).
-export([remove_unsent_messages/1]).
-export([update_registration_id/2,set_device_unregistered/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
                fcm_connection_limit = 0,
                fcm_fetch_process_number = 0
               }
       ).

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link({local,?MODULE},?MODULE, [], []).

%------ CALLS --------
get_fcm_process() ->
  case whereis(fcm_manager) of
    undefined ->
      no_one;
    _ ->
      gen_server:call(?MODULE,get_fcm_process)
  end.
create_fcm_process() ->
  {ServerIdList,ServerKeyList} = {filesettings:get(fcm_sender_id,fcm_sender_id@gcm_dot_googleapis_dot_com_in_double_quotes),
                                  filesettings:get(fcm_server_key,fcm_server_key_in_double_quotes)},
  case true of
    true when ServerIdList =:= fcm_sender_id@gcm_dot_googleapis_dot_com_in_double_quotes;ServerKeyList =:= fcm_server_key_in_double_quotes ->
      applog:error(?MODULE,"Fcm SenderId Or ServerKey Not Defined In settings.txt~n",[]);
    true ->
      R = spawn(fcm_process,fcm,[#{}]),
      R ! connect
  end.
%----- We Make Direct Entries To DB Cause This Process May Not Be Alive Always ------
add_fcm_process(Pid) ->
  case ets:member(fcm_process_id,Pid) of
    true ->
      applog:error(?MODULE,"Key Already Exists In FCM PROCESS ID~n",[]);
    false ->
      NextNumber = ets:update_counter(sequences,fcm_process_counter,{2,1},{fcm_process_counter,0}),
      ets:insert(fcm_process_id,{Pid,NextNumber}),
      ets:insert(fcm_process,{NextNumber,Pid})
  end.
remove_fcm_process(Pid) ->
  case ets:take(fcm_process_id,Pid) of
    [{Pid,Key}] ->
      ets:delete(fcm_process,Key);
    [] ->
      %------- Might Be The Case When Connection Draining ---------
      applog:error(?MODULE,"Key Does Not Exists In FCM PROCESS ID~n",[])
  end.
update_registration_id(OldFcmId,NewFcmId) ->
  %------- Remove From TimeOut Manager -------
  case ets:take(fcm_id_send_time,OldFcmId) of
    [] ->
      ok;
    [{OldFcmId,TimeOutKey}] ->
      %--- Delete ---
      ets:delete(timeout_fcm_id,TimeOutKey),
      %--- Insert ---
      ets:insert(fcm_id_send_time,{NewFcmId,TimeOutKey}),
      ets:insert(timeout_fcm_id,{TimeOutKey,NewFcmId})
  end,
  %------- Remove From OutGoing Messages --------
  case ets:take(fcm_id_outgoing_counters,OldFcmId) of
    [] ->
      ok;
    [{OldFcmId,Counters}] ->
      ets:insert(fcm_id_outgoing_counters,{NewFcmId,Counters})
  end.

set_device_unregistered(FcmId) ->
  %------- Remove From TimeOut Manager -------
  case ets:take(fcm_id_send_time,FcmId) of
    [] ->
      ok;
    [{FcmId,TimeOutKey}] ->
      ets:delete(timeout_fcm_id,TimeOutKey)
  end,
  %------- Remove From OutGoing Messages --------
  case ets:take(fcm_id_outgoing_counters,FcmId) of
    [] ->
      ok;
    [{FcmId,Counters}] ->
      [ets:delete(outgoing_message,Counter) || Counter <- Counters]
  end.

remove_unsent_messages(0) ->
  ok;
remove_unsent_messages(1) ->
  Rerun =
    case ets:first(fcm_sent_messages) of
      '$end_of_table' ->
        0;
      First ->
        case ets:lookup(fcm_sent_messages,First) of
          [] ->
            0;
          [{First,_FcmId,_DataMap,SentAt}] ->
            Now = erlang:system_time(seconds),
            WaitDuration = filesettings:get(fcm_sent_message_acking_wait_seconds,5),
            case Now - SentAt > WaitDuration of
              true ->
                ets:delete(fcm_sent_messages,First),
                1;
              false ->
               0
            end
        end
    end,
  remove_unsent_messages(Rerun).

%------ CASTS --------

%% gen_server.
init([]) ->
  %----- Add It To Gproc ----
  gproc:reg({p,l,processes}),
  process_flag(trap_exit, true),
  applog:info(?MODULE,"Started~n",[]),
  FcmConnectionLimit = filesettings:get(fcm_connection_limit,0),
  case length(gproc:select([{{{p,l,fcm_process},'$1','_'},[],['$1']}])) >= FcmConnectionLimit of
    false ->
      create_fcm_process();
    true ->
      ok
  end,
  %------- Load State Variables ------
	{ok, #state{fcm_connection_limit = FcmConnectionLimit}}.

handle_call(get_fcm_process,_From,State) ->
  FcmConnectionLimit = State#state.fcm_connection_limit,
  CurrentFcmFetchNumber = State#state.fcm_fetch_process_number,
  {NextFcmFetchNumber,FPid} =
    case ets:info(fcm_process,size) > 0 of
      true ->
        case CurrentFcmFetchNumber of
          0 ->
            case ets:first(fcm_process) of
              '$end_of_table' ->
                {0,no_one};
              First ->
                case ets:lookup(fcm_process,First) of
                  [] ->
                    {0,no_one};
                  [CResult] ->
                    CResult
                end
            end;
          CurrentFcmFetchNumber ->
            case ets:next(fcm_process,CurrentFcmFetchNumber) of
              '$end_of_table' ->
                case ets:first(fcm_process) of
                  '$end_of_table' ->
                    {0,no_one};
                  RFirst ->
                    case ets:lookup(fcm_process,RFirst) of
                      [] ->
                        {0,no_one};
                      [RCResult] ->
                        RCResult
                    end
                end;
              NextKey ->
                case ets:lookup(fcm_process,NextKey) of
                  [] ->
                    {CurrentFcmFetchNumber,no_one};
                  [NKResult] ->
                    NKResult
                end
            end
        end;
      false ->
        case length(gproc:select([{{{p,l,fcm_process},'$1','_'},[],['$1']}])) >= FcmConnectionLimit of
          false ->
            create_fcm_process();
          true ->
            ok
        end,
        {0,no_one}
    end,
  %------ Reserve Pool For Sending Message, If Process Is Available ---------
  FFPid =
    case FPid of
      no_one ->
        no_one;
      FPid ->
        case process_info(FPid) of
          undefined ->
            ets:delete(fcm_process,NextFcmFetchNumber),
            ets:delete(fcm_process_id,FPid),
            no_one;
          _ ->
            FPid ! reserve_pool,
            FPid
        end
    end,
  {reply,FFPid,State#state{fcm_fetch_process_number = NextFcmFetchNumber}};
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(send_stats,State) ->
  Pool = ets:info(fcm_process,size),
  Pending = ets:info(outgoing_message,size),
  gproc:send({p,l,statsocket},{fcm_manager,Pool,Pending}),
  {noreply,State};
handle_info({application_variable_update,Name,Value},State) ->
  NewState =
    case Name of
      fcm_connection_limit ->
        case gproc:select([{{{p,l,fcm_process},'$1','_'},[],['$1']}]) of
          [] ->
            create_fcm_process();
          _ ->
            ok
        end,
        State#state{fcm_connection_limit = Value};
      _ ->
        State
    end,
  {noreply,NewState};
handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
  gproc:send({p,l,fcm_process},disconnect).

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

