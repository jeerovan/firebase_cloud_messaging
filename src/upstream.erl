-module(upstream).
-behaviour(ranch_protocol).

-export([start_link/3]).
-export([init/3]).

start_link(Ref, Transport, Opts) ->
	Pid = spawn_link(?MODULE, init, [Ref, Transport, Opts]),
	{ok, Pid}.

init(Ref, Transport, _Opts = []) ->
	{ok, Socket} = ranch:handshake(Ref),
  Transport:setopts(Socket, [{active, true},binary,{packet,line},{buffer,4096}]),
  upstream_manager:add_upstream(self()),
	loop(Socket, Transport).

loop(Socket, Transport) ->
  receive
    stop ->
      Transport:close(Socket);
    {send_upstream,AllData} ->
      applog:verbose(?MODULE,"ToSocket:~p~n",[AllData]),
      JsonData = jsx:encode(AllData),
      Transport:send(Socket,<<JsonData/binary,"\n">>),
      loop(Socket,Transport);
    {tcp,Socket,Data} ->
      case jsx:is_json(Data) of
        true ->
          Json = jsx:decode(Data,[return_maps]),
          applog:verbose(?MODULE,"FromSocket:~p~n",[Json]),
          #{<<"fcm_id">> := FcmId,<<"data">> := JsonData} = Json,
          downstream:create(FcmId,JsonData);
        false ->
          applog:error(?MODULE,"Invalid Json:~p~n",[Data])
      end,
			loop(Socket, Transport);
    {tcp_error,_,Reason} ->
      applog:error(?MODULE,"Error:~p~n",[Reason]),
      upstream_manager:remove_upstream(self()),
      Transport:close(Socket);
    {tcp_closed,Socket} ->
      upstream_manager:remove_upstream(self()),
      Transport:close(Socket)
	end.
