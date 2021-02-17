-module(timeout).
-behaviour(gen_statem).

%--- Get Any Available Fcm Process From Fcm Manager And
%--- Send Messages To Mobile At A Definite Time ---

%% API.
-export([start_link/0]).
-export([append_fcm_id/1]).
-export([update_fcm_id_send_time/2]).
%% gen_statem.
-export([callback_mode/0]).
-export([init/1]).
-export([running/3]).
-export([idle/3]).
-export([state_name/3]).
-export([handle_event/4]).
-export([terminate/3]).
-export([code_change/4]).

-record(state, {
                default_timeout_idle_timeout
                }).

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_statem:start_link({local,?MODULE},?MODULE, [], []).

%------ DIRECT API -----
append_fcm_id(FcmId) -> %---- When Message Is Created, From Message Receivers -------
  case ets:lookup(fcm_id_send_time,FcmId) of
    [] ->
      ets:insert(timeout_fcm_id,{erlang:system_time(),FcmId});
    [{FcmId,Timeout}] ->
      ets:insert(timeout_fcm_id,{Timeout,FcmId})
  end.

update_fcm_id_send_time(FcmId,RateExceeded) -> %--- When Message Is Sent Actually -----
  Now = erlang:system_time(),
  DelayNs =
    case RateExceeded of
      true ->
        filesettings:get(delay_after_fcm_rate_exceeded_for_device_nano_seconds,15000000000);
      false ->
        filesettings:get(fcm_general_message_delay_per_device_nano_seconds,100000000)
    end,
  Delay = Now + DelayNs,
  case ets:lookup(fcm_id_send_time,FcmId) of
    [] ->
      ok;
    [{FcmId,TimeoutKey}] ->
      ets:delete(timeout_fcm_id,TimeoutKey)
  end,
  ets:insert(fcm_id_send_time,{FcmId,Delay}),
  ets:insert(timeout_fcm_id,{Delay,FcmId}).

%% gen_statem.

callback_mode() ->
	state_functions.

init([]) ->
  process_flag(trap_exit, true),
  self() ! check,
  applog:info(?MODULE,"Started~n",[]),
  DefaultIdleTimeout = filesettings:get(default_timeout_idle_timeout_milli_seconds,100),
	{ok, running, #state{default_timeout_idle_timeout = DefaultIdleTimeout}}.

running(info,check,State) ->
  DefaultIdleTimeout = State#state.default_timeout_idle_timeout,
  case ets:first(timeout_fcm_id) of
    '$end_of_table' ->
      fcm_manager:remove_unsent_messages(1),
      {next_state,idle,State,[{state_timeout,DefaultIdleTimeout,idle}]};
    First ->
      Now = erlang:system_time(),
      case First > Now of
        true ->
          Timeout = round((First - Now)/1000000),
          {next_state,idle,State,[{state_timeout,Timeout,idle}]};
        false ->
          [{First,FcmId}] = ets:lookup(timeout_fcm_id,First),
          case ets:lookup(fcm_id_outgoing_counters,FcmId) of
            [] ->
              ets:delete(timeout_fcm_id,First);
            [{_FcmId,[]}] ->
              ets:delete(timeout_fcm_id,First);
            [{FcmId,Counters}] ->
              case get_fcm_message_map(lists:reverse(Counters),[],[]) of
                {[],[]} ->
                  ets:delete(timeout_fcm_id,First);
                {DCIDs,[]} ->
                  ets:delete(timeout_fcm_id,First),
                  downstream:delete(FcmId,DCIDs);
                {CIDs,[FcmMap]} ->
                  case fcm_manager:get_fcm_process() of
                    no_one ->
                      ok;
                    FPID ->
                      ets:delete(timeout_fcm_id,First),
                      downstream:delete(FcmId,CIDs),
                      FPID ! {send_message,FcmId,FcmMap}
                  end
              end
          end,
          self() ! check,
          keep_state_and_data
      end
  end.

idle(state_timeout,idle,State) ->
  self() ! check,
  {next_state,running,State}.
  
state_name(_EventType, _EventData, StateData) ->
	{next_state, state_name, StateData}.

handle_event(_EventType, _EventData, StateName, StateData) ->
	{next_state, StateName, StateData}.

terminate(_Reason, _StateName, _StateData) ->
   %--------- Irrelevant to This Module, Save File Settings -----
  Records = ets:tab2list(filesetting),
  Format = fun(Term) -> io_lib:format("~p.~n", [Term]) end,
  Text = lists:map(Format, Records),
  file:write_file("../../settings.txt", Text).

code_change(_OldVsn, StateName, StateData, _Extra) ->
	{ok, StateName, StateData}.

get_fcm_message_map([Counter|Counters],CIDs,ReturnMap) ->
  {NewCounters,NewCIDs,NewReturnMap} =
    case ets:lookup(outgoing_message,Counter) of
      [] ->
        {Counters,[Counter|CIDs],ReturnMap};
      [{Counter,DataMap}] ->
        {[],[Counter|CIDs],[DataMap]}
    end,
  get_fcm_message_map(NewCounters,NewCIDs,NewReturnMap);
get_fcm_message_map([],CIDs,ReturnMap) ->
  {CIDs,ReturnMap}.
