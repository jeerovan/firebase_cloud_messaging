-module(firebase_cloud_messaging_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	Procs = [
          #{id => applog,
             start => {applog,start_link,[]},
             restart => permanent,
             type => worker,
             shutdown => 5000
            },
            #{id => fcm_manager,
             start => {fcm_manager,start_link,[]},
             restart => permanent,
             type => worker,
             shutdown => 5000
            },
            #{id => upstream_manager,
             start => {upstream_manager,start_link,[]},
             restart => permanent,
             type => worker,
             shutdown => 5000
            },
            #{id => downstream,
             start => {downstream,start_link,[]},
             restart => permanent,
             type => worker,
             shutdown => 5000
            },
            #{id => timeout,
             start => {timeout,start_link,[]},
             restart => permanent,
             type => worker,
             shutdown => brutal_kill
            },
            #{id => fcm_monitor,
             start => {fcm_monitor,start_link,[]},
             restart => permanent,
             type => worker,
             shutdown => 5000
            }
          ],
	{ok, {{one_for_one, 1, 5}, Procs}}.
