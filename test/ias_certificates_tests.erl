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
    ?assertMatch({_, _}, binary:match(PresentHtml, <<"Certificates: 1">>)),
    ?assertMatch({_, _}, binary:match(EmptyHtml, <<"Certificates: 0">>)),
    ?assertEqual(nomatch, binary:match(EmptyHtml, <<">peer_live<">>)).

certificates_runtime_panel_marks_disconnected_vpn_unavailable_test() ->
    Html = render_panel({error, nodedown}),

    ?assertMatch({_, _},
                 binary:match(Html, <<"VPN certificate metadata unavailable.">>)).

render_panel(Summary) ->
    iolist_to_binary(nitro:render(
        ias_certificates:certificates_runtime_panel(Summary))).

summary(Peers) ->
    {ok, #{<<"counts">> => #{<<"configured">> => length(Peers),
                                <<"running">> => length(Peers),
                                <<"certificates">> => length(Peers)},
           <<"peers">> => Peers}}.

certificate_peer(PeerId) ->
    #{<<"id">> => PeerId,
      <<"running">> => true,
      <<"certificate">> =>
          #{<<"subject_cn">> => <<"client.example">>,
            <<"issuer_cn">> => <<"Example CA">>,
            <<"not_before">> => <<"260101000000Z">>,
            <<"not_after">> => <<"270101000000Z">>,
            <<"trusted">> => true,
            <<"key_match">> => true}}.
