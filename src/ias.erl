-module(ias).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1]).
stop(_)    -> ok.
init([])   -> {ok, { {one_for_one, 5, 10}, []} }.
start(_,_) -> kvs:join(),
              ok = ias_vpn_authority:ensure(),
              cowboy:start_clear(http,
                       [{port, application:get_env(n2o, port, 8041)}],
                       #{env => #{dispatch => n2o_cowboy:points()}}),
              supervisor:start_link({local, ?MODULE}, ?MODULE, []).
