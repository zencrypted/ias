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
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_runtime_refresh_now">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_runtime_event_status">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_runtime_connection_notice">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Refresh now">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Updates:">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"vpn_runtime_auto_refresh">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Auto-refresh every 5s">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"setInterval">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Runtime: unavailable | Last attempt:">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"·">>)).

vpn_page_renders_explicit_disconnected_runtime_notice_test() ->
    Notice = ias_vpn:runtime_connection_notice_panel(
               {error, nodedown},
               #{connected => false,
                 last_error => vpn_node_down}),
    Html = iolist_to_binary(nitro:render(Notice)),

    ?assertMatch({_, _}, binary:match(Html, <<"vpn_runtime_connection_notice">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"VPN runtime disconnected">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"last known snapshot">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"reconnecting in the background">>)).

vpn_reconciliation_notice_replaces_disconnect_after_initial_connect_test() ->
    Notice = ias_vpn:reconciliation_stale_notice(connected),
    Html = iolist_to_binary(nitro:render(Notice)),

    ?assertMatch({_, _}, binary:match(Html, <<"VPN event delivery is connected">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"fresh runtime snapshot was loaded">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"VPN disconnected">>)).

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
    ?assertEqual(1,
                 length(binary:matches(Html,
                                       <<"id=\"vpn_reconciliation_fragment\"">>))),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_refresh">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_replay_all">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_scan_incidents">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_stale_notice">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_read_only">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_incidents">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Safe replay unavailable">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Scan incidents unavailable">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"vpn_incident_actor_">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"vpn_incident_note_">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Force overwrite">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Adopt orphan">>)).

vpn_reconciliation_separates_read_only_state_from_incident_editors_test() ->
    DeviceId = <<"reconnect-ui-device">>,
    Token = <<11:256>>,
    Report = #{state => drift_detected,
               counts => #{synchronized => 0,
                           vpn_behind => 0,
                           missing_in_vpn => 0,
                           divergence => 0,
                           orphan => 1,
                           authority_only => 0},
               entries => [#{device_id => DeviceId,
                              status => orphan,
                              reason => vpn_device_without_ias_authority,
                              digest_match => undefined,
                              vpn => #{head => undefined, registry => []}}]},
    Incidents = [#{device_id => DeviceId,
                   kind => orphan,
                   reason => vpn_device_without_ias_authority,
                   token => Token,
                   status => open,
                   occurrences => 1,
                   last_seen => 1782340000}],

    Html = iolist_to_binary(
             nitro:render(ias_vpn:content({error, unavailable},
                                          {ok, Report},
                                          {ok, Incidents}))),

    ?assertEqual(1, length(binary:matches(Html, <<"id=\"vpn_reconciliation_read_only\"">>))),
    ?assertEqual(1, length(binary:matches(Html, <<"id=\"vpn_reconciliation_incidents\"">>))),
    ?assertMatch({_, _}, binary:match(Html, <<"Scan incidents">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Scan incidents unavailable">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_incident_actor_">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_incident_resolve_">>)).

vpn_orphan_incident_renders_confirmed_decommission_action_test() ->
    DeviceId = <<"decommission-ui-device">>,
    Token = <<12:256>>,
    Report = #{state => drift_detected,
               counts => #{synchronized => 0,
                           vpn_behind => 0,
                           missing_in_vpn => 0,
                           divergence => 0,
                           orphan => 1,
                           authority_only => 0},
               entries => [#{device_id => DeviceId,
                              status => orphan,
                              reason => vpn_device_without_ias_authority,
                              read_only => true,
                              recoverable => true,
                              recovery => #{recoverable => true,
                                            mode => metadata_only},
                              decommission => #{eligible => true},
                              vpn => #{heads => [], registry => []}}]},
    Incidents = [#{device_id => DeviceId,
                   kind => orphan,
                   reason => vpn_device_without_ias_authority,
                   token => Token,
                   status => open,
                   snapshot => #{recoverable => true,
                                 recovery => #{recoverable => true,
                                               mode => metadata_only},
                                 decommission => #{eligible => true}},
                   occurrences => 1,
                   last_seen => 1782340000}],
    Html = iolist_to_binary(
             nitro:render(ias_vpn:content({error, unavailable},
                                          {ok, Report},
                                          {ok, Incidents}))),
    ?assertMatch({_, _}, binary:match(Html, <<"Recover into IAS">>)),
    ?assertMatch({_, _},
                 binary:match(Html, <<"vpn_incident_recover_">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Decommission from VPN">>)),
    ?assertMatch({_, _},
                 binary:match(Html, <<"vpn_incident_decommission_">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Adopt orphan">>)).

vpn_reconciliation_links_only_existing_demo_devices_test() ->
    ExistingDeviceId = <<"linked-existing-device">>,
    MissingDeviceId = <<"plain-missing-authority-device">>,
    OrphanDeviceId = <<"plain-orphan-device">>,
    ias_demo_store:clear(),
    try
        _ = ias_demo_store:add_device(#{id => ExistingDeviceId,
                                        source => reconciliation_link_test}),
        Report = #{state => drift_detected,
                   counts => #{synchronized => 2,
                               vpn_behind => 0,
                               missing_in_vpn => 0,
                               divergence => 0,
                               orphan => 1,
                               authority_only => 0},
                   entries => [#{device_id => ExistingDeviceId,
                                  status => synchronized,
                                  reason => in_sync,
                                  digest_match => true,
                                  ias => #{revision => 1},
                                  vpn => #{head => #{revision => 1}, registry => []}},
                               #{device_id => MissingDeviceId,
                                  status => synchronized,
                                  reason => in_sync,
                                  digest_match => true,
                                  ias => #{revision => 1},
                                  vpn => #{head => #{revision => 1}, registry => []}},
                               #{device_id => OrphanDeviceId,
                                  status => orphan,
                                  reason => vpn_device_without_ias_authority,
                                  digest_match => undefined,
                                  vpn => #{head => undefined, registry => []}}]},

        Html = iolist_to_binary(
                 nitro:render(#panel{body =
                     ias_vpn:reconciliation_panel({ok, Report}, {ok, []})})),

        ?assertMatch({_, _},
                     binary:match(
                       Html,
                       <<"href=\"/app/demo.htm?id=linked-existing-device\"">>)),
        ?assertMatch({_, _}, binary:match(Html, ExistingDeviceId)),
        ?assertMatch({_, _}, binary:match(Html, MissingDeviceId)),
        ?assertMatch({_, _}, binary:match(Html, OrphanDeviceId)),
        ?assertEqual(
           nomatch,
           binary:match(
             Html,
             <<"href=\"/app/demo.htm?id=plain-missing-authority-device\"">>)),
        ?assertEqual(
           nomatch,
           binary:match(Html,
                        <<"href=\"/app/demo.htm?id=plain-orphan-device\"">>))
    after
        ias_demo_store:clear()
    end.

vpn_reconciliation_refresh_failure_notice_is_specific_test() ->
    Notice = ias_vpn:reconciliation_stale_notice(
               {reconciliation_refresh_failed, reconnected}),
    Html = iolist_to_binary(nitro:render(Notice)),

    ?assertMatch({_, _}, binary:match(Html, <<"runtime snapshot is fresh">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"could not refresh the reconciliation comparison">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"VPN disconnected">>)).

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
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_reconciliation_replay_">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_incident_actor_">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_incident_note_">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_incident_acknowledge_">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_incident_resolve_">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Saved by Acknowledge or Resolve">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_revision_behind">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"command_digest_mismatch">>)).
