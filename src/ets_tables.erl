-module(ets_tables).
-export([create/0]).

create() ->
  %------- Settings ----------
  ets:new(filesetting,[named_table,set,public,{read_concurrency,true},{write_concurrency,true}]),
  %------- For FCM MANAGER -------
  ets:new(fcm_process,[named_table,ordered_set,public,{read_concurrency,true},{write_concurrency,true}]),
  ets:new(fcm_process_id,[named_table,set,public,{read_concurrency,true},{write_concurrency,true}]),
  %------- Incoming Messages -------
  ets:new(incoming_message,[named_table,ordered_set,public,{read_concurrency,true},{write_concurrency,true}]),
  %------- Message Receiver Manager -------
  ets:new(upstream,[named_table,ordered_set,public,{read_concurrency,true},{write_concurrency,true}]),
  ets:new(upstream_id,[named_table,set,public,{read_concurrency,true},{write_concurrency,true}]),
  %------- Outgoing Messages (Pending) ------
  ets:new(outgoing_message,[named_table,ordered_set,public,{read_concurrency,true},{write_concurrency,true}]),
  ets:new(fcm_id_outgoing_counters,[named_table,set,public,{read_concurrency,true},{write_concurrency,true}]),
  %------- TimeOut Manager ---------
  ets:new(timeout_fcm_id,[named_table,ordered_set,public,{read_concurrency,true},{write_concurrency,true}]),
  ets:new(fcm_id_send_time,[named_table,set,public,{read_concurrency,true},{write_concurrency,true}]),
  %------- Message Sender Manager -------
  ets:new(downstream,[named_table,ordered_set,public,{read_concurrency,true},{write_concurrency,true}]),
  ets:new(downstream_id,[named_table,set,public,{read_concurrency,true},{write_concurrency,true}]),
  %------- Fcm Sent Messages To Be Retried If They Are Nacked ------
  ets:new(fcm_sent_messages,[named_table,ordered_set,public,{read_concurrency,true},{write_concurrency,true}]),
  %------- General Table To Keep General Counters -------
  ets:new(sequences,[named_table,set,public,{read_concurrency,true},{write_concurrency,true}]).
