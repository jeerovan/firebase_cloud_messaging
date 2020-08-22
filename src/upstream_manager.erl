-module(upstream_manager).
-behaviour(gen_server).
-export([
         add_upstream/1,
         remove_upstream/1]).

%--- Manager to handle upstream processes to balance load --

%% API.
-export([start_link/0]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
                  upstream_counter
               }).

%% API.
%------ CALLS -----
%------ DIRECT APIS -----
add_upstream(Pid) ->
  case ets:member(upstream_id,Pid) of
    true ->
      applog:error(?MODULE,"Key Already Exists In upstream_id~n",[]);
    false ->
      NextNumber = ets:update_counter(sequences,upstream_counter,{2,1},{upstream_counter,0}), 
      ets:insert(upstream_id,{Pid,NextNumber}),
      ets:insert(upstream,{NextNumber,Pid}),
      applog:info(?MODULE,"Added Upstream Handler~n",[])
  end.

remove_upstream(Pid) ->
  case ets:take(upstream_id,Pid) of
    [{Pid,Key}] ->
      ets:delete(upstream,Key),
      applog:info(?MODULE,"Removed Upstream Handler~n",[]);
    [] ->
      applog:error(?MODULE,"Key Not Found In upstream_id While Removing~n",[])
  end.

%------ CASTS -----

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link({local,?MODULE},?MODULE, [], []).

%% gen_server.

init([]) ->
  process_flag(trap_exit, true),
  gproc:reg({p,l,processes}),
  applog:info(?MODULE,"Started~n",[]),
  self() ! process_message,
	{ok, #state{upstream_counter = 0}}.

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

try_with_first() ->
  case ets:first(upstream) of
    '$end_of_table' ->
      {0,no_one};
    First ->
      case ets:lookup(upstream,First) of
        [] ->
          {0,no_one};
        [{First,FPID}] ->
          case process_info(FPID,status) of
            undefined ->
              ets:delete(upstream,First),
              ets:delete(upstream_id,FPID),
              {0,no_one};
            _ ->
              {First,FPID}
          end
      end
  end.

handle_info(process_message,State) ->
  CurrentProcessCounter = State#state.upstream_counter,
  {NewProcessCounter,FPID} =
    case ets:info(upstream,size) > 0 of
      true ->
        case CurrentProcessCounter of
          0 ->
            try_with_first();
          CurrentProcessCounter ->
            case ets:next(upstream,CurrentProcessCounter) of
              '$end_of_table' ->
                try_with_first();
              Next ->
                case ets:lookup(upstream,Next) of
                  [] ->
                    {CurrentProcessCounter,no_one};
                  [{Next,NPID}] ->
                    case process_info(NPID,status) of
                      undefined ->
                        ets:delete(upstream,Next),
                        ets:delete(upstream_id,NPID),
                        {CurrentProcessCounter,no_one};
                      _ ->
                        {Next,NPID}
                    end
                end
            end
        end;
      false ->
        {0,no_one}
    end,
  NextProcessCounter =
    case FPID of
      no_one ->
        timer:sleep(100),
        CurrentProcessCounter;
      _ ->
        case ets:first(incoming_message) of
          '$end_of_table' ->
            ets:delete(sequences,incoming_message_counter),
            timer:sleep(100),
            CurrentProcessCounter;
          First ->
            [{First,Data}] = ets:take(incoming_message,First),
            FPID ! {send_upstream,Data},
            NewProcessCounter
        end
    end,
  self() ! process_message,
  {noreply,State#state{upstream_counter = NextProcessCounter}};
handle_info(send_stats,State) ->
  Receivers = ets:info(upstream,size),
  PendingMessages = ets:info(incoming_message,size),
  gproc:send({p,l,statsocket},{upstream_manager,Receivers,PendingMessages}),
  {noreply,State};
handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
  [Pid ! stop || {Pid,_Key} <- ets:tab2list(upstream_id)].

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
