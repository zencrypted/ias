-module(ias_vpn_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("nitro/include/nitro.hrl").

create_vpn_service_stores_runtime_service_test() ->
    ias_demo_store:clear(),

    {ok, Service} = ias_vpn:create_vpn_service(<<"Office VPN">>,
                                               <<"vpn.example.com">>,
                                               <<"443">>,
                                               tcp),

    ?assertEqual(vpn_service, maps:get(kind, Service)),
    ?assertEqual(manual_vpn_service, maps:get(source, Service)),
    ?assertEqual(<<"Office VPN">>, maps:get(name, Service)),
    ?assertEqual(<<"vpn.example.com:443">>, maps:get(remote, Service)),
    ?assertEqual(tcp, maps:get(protocol, Service)),
    ?assertMatch({ok, _}, ias_demo_store:get(maps:get(id, Service))).


create_vpn_service_links_policy_and_ca_certificate_test() ->
    ias_demo_store:clear(),
    CaCertificate = ias_demo_store:add_certificate(#{id => <<"vpn_service_ca_certificate">>,
                                                     source => ca_certificate,
                                                     subject => <<"CN=CA">>}),

    {ok, Service} = ias_vpn:create_vpn_service(<<"Office VPN">>,
                                               <<"vpn.example.com">>,
                                               <<"1194">>,
                                               udp,
                                               <<"standard">>,
                                               maps:get(id, CaCertificate)),

    ?assertEqual(<<"standard">>, maps:get(security_policy_id, Service)),
    ?assertEqual(maps:get(id, CaCertificate), maps:get(ca_certificate_id, Service)),
    ?assertMatch({linked, _}, ias_relationship_link:status(uses_security_policy,
                                                           maps:get(id, Service),
                                                           <<"standard">>)),
    ?assertMatch({linked, _}, ias_relationship_link:status(uses_ca_certificate,
                                                           maps:get(id, Service),
                                                           maps:get(id, CaCertificate))).

create_vpn_service_requires_remote_host_test() ->
    ias_demo_store:clear(),

    ?assertEqual({error, <<"remote host is required">>},
                 ias_vpn:create_vpn_service(<<"OpenVPN">>, <<>>, <<"1194">>, udp)).

vpn_page_renders_create_service_form_test() ->
    Html = iolist_to_binary(nitro:render(ias_vpn:content({error, unavailable}))),

    ?assertMatch({_, _}, binary:match(Html, <<"Create VPN Service">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Remote Host">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Security Policy">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"CA Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Managed VPN Services">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_runtime_summary">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_runtime_auto_refresh">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_runtime_auto_refresh_enabled">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_runtime_auto_refresh_state">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Refresh now">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Auto-refresh every 5s">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Auto-refresh: 2s">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Runtime: unavailable | Last attempt:">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"·">>)).

runtime_refresh_panels_preserve_update_targets_test() ->
    StatusHtml = iolist_to_binary(nitro:render(ias_vpn:runtime_status_panel({error, unavailable}))),
    SummaryHtml = iolist_to_binary(nitro:render(ias_vpn:runtime_summary_panel({error, unavailable}))),

    ?assertMatch({_, _}, binary:match(StatusHtml, <<"id=\"vpn_runtime_refresh_status\"">>)),
    ?assertMatch({_, _}, binary:match(SummaryHtml, <<"id=\"vpn_runtime_summary\"">>)).

vpn_page_honors_runtime_development_bypass_test() ->
    Summary = #{<<"counts">> => #{<<"configured">> => 1,
                                   <<"running">> => 1,
                                   <<"stopped">> => 0,
                                   <<"certificates">> => 1},
                <<"peers">> => [#{<<"id">> => <<"client_a">>,
                                    <<"running">> => true,
                                    <<"mode">> => <<"tun">>,
                                    <<"ip">> => <<"10.20.30.1">>,
                                    <<"remote_peer_id">> => <<"peer_b">>,
                                    <<"authorization_mode">> => <<"development_bypass">>,
                                    <<"authorized">> => true,
                                    <<"authorization_reason">> => <<"development_bypass">>,
                                    <<"certificate">> => #{<<"trusted">> => true,
                                                               <<"key_match">> => true,
                                                               <<"not_after">> => <<"270622203259Z">>}}]},

    Html = iolist_to_binary(nitro:render(ias_vpn:content({ok, Summary}))),

    ?assertMatch({_, _}, binary:match(Html, <<"client_a">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"development bypass">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"270622203259Z">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"vpn not permitted by profile">>)).

vpn_page_prefers_runtime_policy_metadata_test() ->
    Summary = #{<<"counts">> => #{},
                <<"peers">> => [#{<<"id">> => <<"wizard_peer">>,
                                    <<"running">> => true,
                                    <<"authorization_mode">> => <<"policy">>,
                                    <<"profile_id">> => <<"administrator">>,
                                    <<"authorized">> => false,
                                    <<"authorization_reason">> => <<"vpn not permitted by profile">>}]},

    Html = iolist_to_binary(nitro:render(ias_vpn:content({ok, Summary}))),

    ?assertMatch({_, _}, binary:match(Html, <<"wizard_peer">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"administrator">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn not permitted by profile">>)).

vpn_page_falls_back_to_ias_policy_for_legacy_runtime_peer_test() ->
    Summary = #{<<"counts">> => #{},
                <<"peers">> => [#{<<"id">> => <<"unmanaged_peer">>,
                                    <<"running">> => true,
                                    <<"authorization_mode">> => <<"policy">>,
                                    <<"authorized">> => true,
                                    <<"authorization_reason">> => <<"runtime allow must not override IAS">>}]},

    Html = iolist_to_binary(nitro:render(ias_vpn:content({ok, Summary}))),

    ?assertMatch({_, _}, binary:match(Html, <<"vpn not permitted by profile">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"runtime allow must not override IAS">>)).

vpn_page_renders_reconciliation_controls_test() ->
    Html = iolist_to_binary(nitro:render(ias_vpn:content({error, unavailable}))),

    ?assertMatch({_, _}, binary:match(Html, <<"VPN Reconciliation">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_refresh">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_replay_all">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_scan_incidents">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_actor">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_note">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Force overwrite">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Adopt orphan">>)).

vpn_reconciliation_panel_renders_safe_actions_and_incidents_test() ->
    DeviceId = <<"ui-device">>,
    Token = <<7:256>>,
    Report = #{state => drift_detected,
               counts => #{synchronized => 1,
                           vpn_behind => 1,
                           missing_in_vpn => 0,
                           divergence => 1,
                           orphan => 0,
                           authority_only => 0},
               entries => [#{device_id => DeviceId,
                              status => vpn_behind,
                              reason => vpn_revision_behind,
                              digest_match => true,
                              ias => #{revision => 2},
                              vpn => #{head => #{revision => 1}, registry => []}},
                           #{device_id => <<"blocked-device">>,
                              status => divergence,
                              reason => command_digest_mismatch,
                              digest_match => false,
                              ias => #{revision => 2},
                              vpn => #{head => #{revision => 2}, registry => []}}]},
    Incidents = [#{device_id => <<"blocked-device">>,
                   kind => divergence,
                   reason => command_digest_mismatch,
                   token => Token,
                   status => open,
                   occurrences => 1,
                   last_seen => 1782340000}],

    Html = iolist_to_binary(
             nitro:render(#panel{body = ias_vpn:reconciliation_panel({ok, Report},
                                                                      {ok, Incidents})})),

    ?assertMatch({_, _}, binary:match(Html, <<"Safe replay">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Blocked">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Acknowledge">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Resolve after verification">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_revision_behind">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"command_digest_mismatch">>)).
