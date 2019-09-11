-module(upstream).
-behaviour(ranch_protocol).

-export([start_link/3]).
-export([init/3]).

start_link(Ref, Transport, Opts) ->
	Pid = spawn_link(?MODULE, init, [Ref, Transport, Opts]),
	{ok, Pid}.

init(Ref, Transport, _Opts = []) ->
	{ok, Socket} = ranch:handshake(Ref),
  Transport:setopts(Socket, [{active, once}]),
  upstream_manager:add_upstream(self()),
	loop(Socket, Transport).

loop(Socket, Transport) ->
  receive
    stop ->
      Transport:close(Socket);
    {send_upstream,AllData} ->
      Transport:send(Socket,jsx:encode(AllData)),
      loop(Socket,Transport);
    {tcp,Socket,Data} ->
      applog:info(?MODULE,"~p~n",[Data]),
      Json = jsx:decode(Data,[return_maps]),
      #{<<"fcm_id">> := FcmId,<<"data">> := JsonData} = Json,
      downstream:create(FcmId,JsonData),
      Transport:setopts(Socket, [{active, once}]),
			loop(Socket, Transport);
    {tcp_error,_,Reason} ->
      applog:error(?MODULE,"Error:~p~n",[Reason]),
      upstream_manager:remove_upstream(self()),
      Transport:close(Socket);
    {tcp_closed,Socket} ->
      upstream_manager:remove_upstream(self()),
      Transport:close(Socket)
	end.
