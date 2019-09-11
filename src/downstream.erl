-module(downstream).
-behaviour(gen_server).

%---- Enqueue Messages To Be Sent To Mobile ----

%% API.
-export([start_link/0]).
-export([create/2,
         delete/2]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
}).

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link({local,?MODULE},?MODULE, [], []).

create(FcmId,Json) ->
  gen_server:cast(?MODULE,{create,FcmId,Json}).
delete(FcmId,SMIDs) ->
  gen_server:cast(?MODULE,{delete,FcmId,SMIDs}).

%% gen_server.

init([]) ->
  process_flag(trap_exit, true),
  applog:info(?MODULE,"Started~n",[]),
	{ok, #state{}}.

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast({create,FcmId,Json},State) ->
  Counter = ets:update_counter(sequences,
                               outgoing_message_counter,{2,1},
                               {outgoing_message_counter,0}),
  ets:insert(outgoing_message,{Counter,Json}),
  case ets:lookup(fcm_id_outgoing_counters,FcmId) of
    [] ->
      ets:insert(fcm_id_outgoing_counters,{FcmId,[Counter]});
    [{FcmId,Counters}] ->
      NewCounters = [Counter|Counters],
      ets:insert(fcm_id_outgoing_counters,{FcmId,NewCounters})
  end,
  timeout:append_fcm_id(FcmId),
	{noreply, State};
handle_cast({delete,FcmId,MIDs},State) ->
  [ets:delete(outgoing_message,MID) || MID <- MIDs],
  case ets:lookup(fcm_id_outgoing_counters,FcmId) of
    [] ->
      ok;
    [{FcmId,Counters}] ->
      ets:insert(fcm_id_outgoing_counters,{FcmId,Counters -- MIDs})
  end,
	{noreply, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
  %--------- Irrelevant to This Module, Save File Settings -----
  Records = ets:tab2list(filesetting),
  Format = fun(Term) -> io_lib:format("~w.~n", [Term]) end,
  Text = lists:map(Format, Records),
  file:write_file("../../settings.txt", Text).

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
