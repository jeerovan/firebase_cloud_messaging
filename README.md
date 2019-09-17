# Firebase Cloud Messaging With XMPP Servers

## What is it about?
Erlang Implementation Of Firebase Cloud Messaging Through XMPP Servers

## Links
- **Android App (Fatalk) ->** [https://play.google.com/store/apps/details?id=com.kaarss.fatalk](https://play.google.com/store/apps/details?id=com.kaarss.fatalk)
- **Android App Repo ->** [https://github.com/jeerovan/fatalk](https://github.com/jeerovan/fatalk)
- **App Backend Repo->** [https://github.com/jeerovan/firebase_xmpp](https://github.com/jeerovan/firebase_xmpp)

## Setting Up
- Install Erlang (Please Search Google)
- Clone Repo
- Execute Command `make` At Root Folder Location. This Will Download Required Dependencies And Compile Them.
- To Run In A Console, Execute `_rel/firebase_cloud_messaging_release/bin/firebase_cloud_messaging_release console`
- Execute Command `q().` To Quit For Now.
- You'll Have A Settings File Named : `settings.txt`. It Contains All The Settings You Can Configure To Establish Firebase XMPP Connections And Set Different Limits As Required.
- To Establish Firebase Connections, `fcm_sender_id` & `fcm_server_key` Are Required. These You Can Find In Your Firebase Project's Cloud Messaging Section
- If The `fcm_connection_limit` Is Set To 0 In `settings.txt` You May Initialize A New FCM Connection With Following Command: `fcm_manager:create_fcm_process().`
- Set Log Levels `verbose/info/debug/error` To Control Logs In `settings.txt`
- After Setting Up Parameters, Execute Console Command To Run And Create FCM Connections
- To Communicate with external application, establish a unix domain socket over TCP. The default uds location is /tmp/fcm.socket

## Features And Support
- Supports Only Android For Now (No Support For iOS)
- Sends Only `data` Notifications With Priority (high/normal) Having TTL 0 To Improve Latency
- Sends Bundle Of Messages To Optimize Bandwidth
- Does Not Support Delivery Receipt
- Automatic Retry Of `nack` Messages
- Configurable Paramters To Control Throughput And Message Rate Per Device
- Handles Connections With State `idle` Or `service unavailable`
- Communicate with external application over tcp socket

## Setting Parameters
- listen_on : either listen on unix_socket or http_port.
- unxi_socket : unix_socket location, defaults to "/tmp/fcm.socket"
- http_port : which port to listen on , defaults to 3000
- fcm_process_pool_upper_bound : Maxmium number of messages in the pool of fcm_process before it stops accepting further message.
- fcm_process_pool_lower_bound : Minumum number of messages in the pool of fcm_prcess before it starts accepting new messages again.
- default_timeout_idle_timeout_milli_seconds : Timeout process polls for new message to process. If there are none, it remains idel for these milli seconds.
- fcm_connection_service_idle_timeout_seconds : If fcm_process is idle for timeout_seconds, it will be disconnected.
- fcm_connection_service_unavailable_timeout_seconds : If fcm_process remains unavailable to process any message, it will disconnected after timeout_seconds.
- fcm_general_message_delay_per_device_nano_seconds : You may even set a delay after consecutive message to be sent to a particular device.
- fcm_connection_monitor_interval_seconds : After how long monitor process should check fcm_process state and handle accordingly.
- fcm_connection_limit : Maximum number of fcm_process to established when required.
- fcm_sent_message_acking_wait_seconds : wait time for a particular message to be acknowledged before it is discarded.

## Json Message Format Over TCP
The tcp socket sends out following messages to the other end:
- {type:upstream_data, fcm_id:FcmId, data:JsonDataFromTheDevice}
- {type:fcm_id_updated, fcm_id:FcmId, old_fcm_id:OldFcmId}
- {type:fcm_id_deregistered, fcm_id:FcmId}

And accepts message in following format:
- {fcm_id:FcmId, data:JsonDataToTheDevice}
