-module(ias_devices_tests).
-include_lib("eunit/include/eunit.hrl").

devices_page_exposes_live_runtime_update_target_test() ->
    Html = iolist_to_binary(nitro:render(ias_devices:content())),

    ?assertMatch({_, _},
                 binary:match(Html, <<"id=\"devices_runtime_summary\"">>)).

devices_runtime_panel_reflects_peer_state_changes_test() ->
    PeerId = fixture_peer_id(),
    RunningHtml = render_panel(summary(PeerId, true)),
    StoppedHtml = render_panel(summary(PeerId, false)),

    ?assertMatch({_, _}, binary:match(RunningHtml, <<">running<">>)),
    ?assertMatch({_, _}, binary:match(StoppedHtml, <<">stopped<">>)).

devices_runtime_panel_marks_disconnected_vpn_unavailable_test() ->
    PeerId = fixture_peer_id(),
    Html = render_panel({error, nodedown}),

    case PeerId of
        undefined -> ok;
        _ -> ?assertMatch({_, _}, binary:match(Html, <<">unavailable<">>))
    end.

render_panel(Summary) ->
    iolist_to_binary(nitro:render(ias_devices:devices_runtime_panel(Summary))).

summary(undefined, _Running) ->
    {ok, #{<<"counts">> => #{}, <<"peers">> => []}};
summary(PeerId, Running) ->
    {ok, #{<<"counts">> => #{<<"configured">> => 1,
                               <<"running">> => case Running of true -> 1; false -> 0 end},
           <<"peers">> => [#{<<"id">> => PeerId,
                              <<"running">> => Running,
                              <<"ip">> => <<"10.0.0.2">>,
                              <<"remote_peer_id">> => <<"peer_remote">>}]}}.

fixture_peer_id() ->
    Devices = ias_demo_data:devices(),
    case [PeerId || Device <- Devices,
                    (PeerId = maps:get(vpn_peer, Device, undefined)) =/= undefined] of
        [PeerId | _] -> PeerId;
        [] -> undefined
    end.
