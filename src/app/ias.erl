-module(ias).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1]).
stop(_)    -> ok.
init([])   ->
    EventBridge = #{id => ias_vpn_event_bridge,
                    start => {ias_vpn_event_bridge, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [ias_vpn_event_bridge]},
    {ok, {{one_for_one, 5, 10}, [EventBridge]}}.
start(_,_) ->
    case ias_bootstrap:prepare() of
        {ok, _ProjectionHealth} ->
            start_runtime();
        {error, _} = Error ->
            Error
    end.

start_runtime() ->
    case cowboy:start_clear(
           http,
           [{port, application:get_env(n2o, port, 8041)}],
           #{env => #{dispatch => n2o_cowboy:points()}}) of
        {ok, _Listener} ->
            case supervisor:start_link({local, ?MODULE}, ?MODULE, []) of
                {ok, _Pid} = Started ->
                    Started;
                {error, _} = Error ->
                    _ = cowboy:stop_listener(http),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.
