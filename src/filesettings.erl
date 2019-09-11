-module(filesettings).

-export([get/2,set/2]).

%------ SETTINGS -------
get(Key,Default) ->
  case ets:info(filesetting) of
    undefined ->
      Default;
    _ ->
      case ets:lookup(filesetting,Key) of
        [] ->
          set(Key,Default),
          Default;
        [{Key,Value}] ->
          Value
      end
  end.
set(Key,Value) ->
  [Process ! {application_variable_update,Key,Value} || Process <- gproc:select([{{{p,l,processes},'$1','_'},[],['$1']}])],
  ets:insert(filesetting,{Key,Value}).

