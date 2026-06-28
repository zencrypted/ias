-module(ias_services_tests).
-include_lib("eunit/include/eunit.hrl").

services_page_exposes_live_runtime_update_target_test() ->
    Html = iolist_to_binary(nitro:render(ias_services:content())),

    ?assertMatch({_, _},
                 binary:match(Html, <<"id=\"services_runtime_summary\"">>)).

services_runtime_panel_reflects_fresh_vpn_snapshot_test() ->
    Running = summary(2, 2, 2),
    Stopped = summary(2, 0, 2),
    RunningHtml = render_panel(Running),
    StoppedHtml = render_panel(Stopped),

    ?assertMatch({_, _}, binary:match(RunningHtml, <<">running<">>)),
    ?assertMatch({_, _}, binary:match(RunningHtml, <<">2<">>)),
    ?assertMatch({_, _}, binary:match(StoppedHtml, <<">stopped<">>)),
    ?assertMatch({_, _}, binary:match(StoppedHtml, <<">0<">>)).

services_runtime_panel_marks_failed_snapshot_unavailable_test() ->
    Html = render_panel({error, nodedown}),

    ?assertMatch({_, _}, binary:match(Html, <<">unavailable<">>)).

render_panel(Summary) ->
    iolist_to_binary(nitro:render(ias_services:services_runtime_panel(Summary))).

summary(Configured, Running, Certificates) ->
    Peers = [#{<<"id">> => iolist_to_binary(["peer_", integer_to_list(Index)]),
               <<"running">> => Index =< Running}
             || Index <- lists:seq(1, Configured)],
    {ok, #{<<"counts">> => #{<<"configured">> => Configured,
                               <<"running">> => Running,
                               <<"certificates">> => Certificates},
           <<"peers">> => Peers}}.
