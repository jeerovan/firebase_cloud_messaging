-module(fcm_acker).
-compile([export_all,nowarn_export_all]).


acker(Socket) ->
  receive
    {send_message,Message} ->
      ssl:send(Socket,Message),
      acker(Socket);
    stop ->
      ok
  end.
