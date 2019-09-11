-module(firebase_cloud_messaging_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

start(_Type, _Args) ->
  %--- Create ETS Tables ----
  ets_tables:create(),
  %--- Restore Settings ----
  Records =
    case file:consult("../../settings.txt") of
      {error,_} ->
        [];
      {ok,Lines} ->
        Lines
    end,
  [ets:insert(filesetting,Record) || Record <- Records],
  %----- Check Settings ----
  SenderIdDummyDefault = fcm_sender_id@gcm_dot_googleapis_dot_com_in_double_quotes,
  SenderKeyDummyDefault = fcm_server_key_in_double_quotes,
  case filesettings:get(fcm_sender_id,SenderIdDummyDefault) of
    SenderIdDummyDefault ->
      io:format("Please Define Fcm Sender Id in settings.txt~n",[]);
    _ ->
      ok
  end,
  case filesettings:get(fcm_server_key,SenderKeyDummyDefault) of
    SenderKeyDummyDefault ->
      io:format("Please Define Fcm Sender Key in settings.txt~n",[]);
    _ ->
      ok
  end, 
  UnixSocket = filesettings:get(unix_socket,"/tmp/fcm.socket"),
  _ = spawn(os,cmd,["rm " ++ UnixSocket]),
  {ok, _} = ranch:start_listener(firebase_cloud_messaging,
		ranch_tcp, #{socket_opts => [{ip,{local,UnixSocket}},{port, 0}]},
		upstream, []),
	firebase_cloud_messaging_sup:start_link().

stop(_State) ->
	ok.
