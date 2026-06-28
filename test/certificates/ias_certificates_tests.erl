-module(ias_certificates_tests).
-include_lib("eunit/include/eunit.hrl").

certificates_page_exposes_live_runtime_update_target_test() ->
    Html = iolist_to_binary(nitro:render(ias_certificates:content())),

    ?assertMatch({_, _},
                 binary:match(Html, <<"id=\"certificates_runtime_summary\"">>)).

certificates_runtime_panel_reflects_inventory_changes_test() ->
    PresentHtml = render_panel(summary([certificate_peer(<<"peer_live">>)])),
    EmptyHtml = render_panel(summary([])),

    ?assertMatch({_, _}, binary:match(PresentHtml, <<">peer_live<">>)),
    ?assertMatch({_, _}, binary:match(PresentHtml, <<">client.example<">>)),
    assert_runtime_counts(PresentHtml, 1, 1),
    assert_runtime_counts(EmptyHtml, 0, 0),
    ?assertEqual(nomatch, binary:match(EmptyHtml, <<">peer_live<">>)).

certificates_runtime_panel_reflects_peer_runtime_state_test() ->
    RunningHtml = render_panel(summary([certificate_peer(<<"peer_live">>, true)])),
    StoppedHtml = render_panel(summary([certificate_peer(<<"peer_live">>, false)])),

    ?assertMatch({_, _}, binary:match(RunningHtml, <<">Runtime State<">>)),
    ?assertMatch({_, _}, binary:match(RunningHtml, <<">running</td>">>)),
    ?assertMatch({_, _}, binary:match(StoppedHtml, <<">stopped</td>">>)),
    assert_runtime_counts(RunningHtml, 1, 1),
    assert_runtime_counts(StoppedHtml, 1, 0),
    ?assertMatch({_, _}, binary:match(StoppedHtml, <<">peer_live<">>)).

certificates_runtime_panel_marks_disconnected_vpn_unavailable_test() ->
    Html = render_panel({error, nodedown}),

    ?assertMatch({_, _},
                 binary:match(Html, <<"VPN certificate metadata unavailable.">>)).

assert_runtime_counts(Html, Certificates, RunningPeers) ->
    CertificateText = iolist_to_binary(
        io_lib:format("Certificates: ~B", [Certificates])),
    RunningText = iolist_to_binary(
        io_lib:format("Running peers: ~B", [RunningPeers])),
    ?assertMatch({_, _}, binary:match(Html, CertificateText)),
    ?assertMatch({_, _}, binary:match(Html, RunningText)).

render_panel(Summary) ->
    iolist_to_binary(nitro:render(
        ias_certificates:certificates_runtime_panel(Summary))).

summary(Peers) ->
    {ok, #{<<"counts">> => #{<<"configured">> => length(Peers),
                                <<"running">> => length(Peers),
                                <<"certificates">> => length(Peers)},
           <<"peers">> => Peers}}.

certificate_peer(PeerId) ->
    certificate_peer(PeerId, true).

certificate_peer(PeerId, Running) ->
    #{<<"id">> => PeerId,
      <<"running">> => Running,
      <<"certificate">> =>
          #{<<"subject_cn">> => <<"client.example">>,
            <<"issuer_cn">> => <<"Example CA">>,
            <<"not_before">> => <<"260101000000Z">>,
            <<"not_after">> => <<"270101000000Z">>,
            <<"trusted">> => true,
            <<"key_match">> => true}}.
