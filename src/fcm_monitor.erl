-module(fcm_monitor).
-behaviour(gen_statem).

%% API.
-export([start_link/0]).
%% gen_statem.
-export([callback_mode/0]).
-export([init/1]).
-export([running/3]).
-export([state_name/3]).
-export([handle_event/4]).
-export([terminate/3]).
-export([code_change/4]).

-record(data, {
                monitor_interval,
                service_idle_timeout,
                service_unavailable_timeout
                }).

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_statem:start_link({local,?MODULE},?MODULE, [], []).

%% gen_statem.

callback_mode() ->
	state_functions.

init([]) ->
  process_flag(trap_exit, true),
  applog:info(?MODULE,"Started~n",[]),
  self() ! start,
  MonitorInterval = filesettings:get(fcm_connection_monitor_interval_seconds,200) * 1000,
  ServiceIdleTimeout = filesettings:get(fcm_connection_service_idle_timeout_seconds,350),
  ServiceUnavailableTimeout = filesettings:get(fcm_connection_service_unavailable_timeout_seconds,500),
	{ok, running, #data{monitor_interval = MonitorInterval,
                      service_idle_timeout = ServiceIdleTimeout,
                      service_unavailable_timeout = ServiceUnavailableTimeout}}.

running(info,start,Data) ->
  MonitorInterval = Data#data.monitor_interval,
  {keep_state,Data,[{{timeout,monitor},MonitorInterval,running}]};

running(info,{fcm_state,From,{FcmState,FcmStateAt}},Data) ->
  IdleTimeout = Data#data.service_idle_timeout,
  UnavailableTimeout = Data#data.service_unavailable_timeout,
  Now = erlang:system_time(seconds),
  case true of
    true when FcmState =:= active;FcmState =:= idle ->
      case Now - FcmStateAt > IdleTimeout of
        true ->
          applog:info(?MODULE,"Disconnecting IDLE Fcm.~n",[]),
          From ! disconnect;
        false ->
          ok
      end;
    true when FcmState =:= unavailable ->
      case Now - FcmStateAt > UnavailableTimeout of
        true ->
          applog:info(?MODULE,"Making Connection Available.~n",[]),
          From ! connection_available;
        false ->
          ok
      end;
    true ->
      ok
  end,
  {keep_state,Data};

running({timeout,monitor},running,Data) ->
  gproc:send({p,l,fcm_process},{send_connection_state,self()}),
  MonitorInterval = Data#data.monitor_interval,
  {keep_state,Data,[{{timeout,monitor},MonitorInterval,running}]}.

state_name(_EventType, _EventData, StateData) ->
	{next_state, state_name, StateData}.

handle_event(_EventType, _EventData, StateName, StateData) ->
	{next_state, StateName, StateData}.

terminate(_Reason, _StateName, _StateData) ->
	ok.

code_change(_OldVsn, StateName, StateData, _Extra) ->
	{ok, StateName, StateData}.
