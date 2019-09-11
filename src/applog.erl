-module(applog).
-behaviour(gen_server).

%--- Just A Logging Server ------

%% API.
-export([start_link/0]).
-export([info/3,verbose/3,debug/3,error/3]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {log_info,
                log_verbose,
                log_debug,
                log_error
               }).

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	gen_server:start_link({local,?MODULE},?MODULE, [], []).

%-------- CALLS ----------

%-------- CASTS ----------
info(Module,Message,Args) ->
  Msg = string:uppercase(atom_to_list(Module)) ++ "->" ++ Message,
  gen_server:cast(?MODULE,{info,Msg,Args}).
verbose(Module,Message,Args) ->
  Msg = string:uppercase(atom_to_list(Module)) ++ "->" ++ Message,
  gen_server:cast(?MODULE,{verbose,Msg,Args}).
debug(Module,Message,Args) ->
  Msg = string:uppercase(atom_to_list(Module)) ++ "->" ++ Message,
  gen_server:cast(?MODULE,{debug,Msg,Args}).
error(Module,Message,Args) ->
  Msg = string:uppercase(atom_to_list(Module)) ++ ":->" ++ Message,
  gen_server:cast(?MODULE,{error,Msg,Args}).

%% gen_server.

init([]) ->
  %------- Add It To Gproc -------
  gproc:reg({p,l,processes}),
  Verbose = filesettings:get(log_verbose,true),
  Info = filesettings:get(log_info,true),
  Debug = filesettings:get(log_debug,true),
  Error = filesettings:get(log_error,true),
	{ok, #state{log_info = Info,
              log_verbose = Verbose,
              log_debug = Debug,
              log_error = Error}}.

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast({info,Message,Args},State) ->
  case State#state.log_info of
    true ->
      io:format(Message,Args);
    false ->
      ok
  end,
  {noreply,State};
handle_cast({verbose,Message,Args},State) ->
  case State#state.log_verbose of
    true ->
      io:format(Message,Args);
    false ->
      ok
  end,
  {noreply,State};
handle_cast({debug,Message,Args},State) ->
  case State#state.log_debug of
    true ->
      io:format(Message,Args);
    false ->
      ok
  end,
  {noreply,State};
handle_cast({error,Message,Args},State) ->
  case State#state.log_error of
    true ->
      io:format(Message,Args);
    false ->
      ok
  end,
  {noreply,State};
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({application_variable_update,Name,Value},State) ->
  NewState =
    case Name of
      log_info ->
        State#state{log_info = Value};
      log_verbose ->
        State#state{log_verbose = Value};
      log_debug ->
        State#state{log_debug = Value};
      log_error ->
        State#state{log_error = Value};
      _ ->
        State
    end,
  {noreply,NewState};
handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
