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
                service_alive_timeout,
                service_idle_timeout,
                service_closing_timeout
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
  ServiceIdleTimeout = filesettings:get(fcm_connection_service_idle_timeout_seconds,300),
  ServiceClosingTimeout = filesettings:get(fcm_connection_service_closing_timeout_seconds,500),
  ServiceAliveTimeout = filesettings:get(fcm_connection_alive_timeout_seconds,1800),
	{ok, running, #data{monitor_interval = MonitorInterval,
                      service_alive_timeout = ServiceAliveTimeout,
                      service_idle_timeout = ServiceIdleTimeout,
                      service_closing_timeout = ServiceClosingTimeout}}.

running(info,start,Data) ->
  MonitorInterval = Data#data.monitor_interval,
  {keep_state,Data,[{{timeout,monitor},MonitorInterval,running}]};

running(info,{fcm_state,From,CreatedAt,{FcmState,FcmStateAt}},Data) ->
  IdleTimeout = Data#data.service_idle_timeout,
  ClosingTimeout = Data#data.service_closing_timeout,
  AliveTimeout = Data#data.service_alive_timeout,
  Now = erlang:system_time(seconds),
  Expired = CreatedAt + AliveTimeout < Now,
  case true of
    true when Expired ->
      applog:debug(?MODULE,"~p:Reconnecting, Alive Timeout.~n",[From]),
      From ! reconnect;
    true when FcmState =:= active;FcmState =:= idle ->
      case Now - FcmStateAt > IdleTimeout of
        true ->
          applog:info(?MODULE,"~p:Reconnecting Idle.~n",[From]),
          From ! reconnect;
        false ->
          ok
      end;
    true when FcmState =:= closing ->
      case Now - FcmStateAt > ClosingTimeout of
        true ->
          applog:info(?MODULE,"~p:Reconnecting Closing.~n",[From]),
          From ! reconnect;
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
