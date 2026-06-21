-module(ias_provisioning_wizard_tests).
-include_lib("eunit/include/eunit.hrl").

draft_creation_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    ?assertMatch(<<"provisioning_wizard_", _/binary>>, maps:get(id, Draft)),
    ?assertEqual(device_bound, maps:get(scenario, Draft)),
    ?assertEqual(device, maps:get(current_step, Draft)),
    ?assertEqual(undefined, maps:get(device_id, Draft)),
    ?assertMatch({ok, Draft}, ias_provisioning_wizard_store:get(maps:get(id, Draft))).

unique_ids_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, First} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Second} = ias_provisioning_wizard_store:new(device_bound),
    ?assertNotEqual(maps:get(id, First), maps:get(id, Second)).

scenario_selection_starts_device_step_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    ?assertEqual(device_bound, maps:get(scenario, Draft)),
    ?assertEqual(device, maps:get(current_step, Draft)).

next_and_back_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_device_next">>),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Selected} = ias_provisioning_wizard_store:select_device(
        maps:get(id, Draft0), maps:get(id, Device)),
    {ok, Draft1} = ias_provisioning_wizard_store:next(maps:get(id, Selected)),
    ?assertEqual(security_profile, maps:get(current_step, Draft1)),
    {ok, Draft2} = ias_provisioning_wizard_store:back(maps:get(id, Draft1)),
    ?assertEqual(device, maps:get(current_step, Draft2)).


device_step_requires_selection_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    ?assertEqual({error, device_required},
                 ias_provisioning_wizard_store:next(maps:get(id, Draft))),
    {ok, StillDevice} = ias_provisioning_wizard_store:get(maps:get(id, Draft)),
    ?assertEqual(device, maps:get(current_step, StillDevice)).

existing_device_can_be_selected_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_existing_device">>),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Selected} = ias_provisioning_wizard_store:select_device(
        maps:get(id, Draft), maps:get(id, Device)),
    ?assertEqual(maps:get(id, Device), maps:get(device_id, Selected)),
    ?assertMatch({ok, _}, ias_provisioning_wizard_store:selected_device(Selected)).

created_device_can_be_selected_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Device} = ias_manual_device:create(#{name => <<"Wizard Laptop">>,
                                               type => <<"vpn-client">>,
                                               tunnel_device => <<"tun">>,
                                               transport => <<"udp">>,
                                               endpoint => <<"vpn.example.com">>}),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Selected} = ias_provisioning_wizard_store:select_device(
        maps:get(id, Draft), maps:get(id, Device)),
    ?assertEqual(maps:get(id, Device), maps:get(device_id, Selected)).

stale_selected_device_blocks_next_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_stale_device">>),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Selected} = ias_provisioning_wizard_store:select_device(
        maps:get(id, Draft), maps:get(id, Device)),
    ok = ias_demo_store:delete_runtime_object(device, maps:get(id, Device)),
    ?assertEqual({error, selected_device_missing},
                 ias_provisioning_wizard_store:next(maps:get(id, Selected))).

back_preserves_device_selection_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_preserved_device">>),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Selected} = ias_provisioning_wizard_store:select_device(
        maps:get(id, Draft), maps:get(id, Device)),
    {ok, ProfileStep} = ias_provisioning_wizard_store:next(maps:get(id, Selected)),
    {ok, DeviceStep} = ias_provisioning_wizard_store:back(maps:get(id, ProfileStep)),
    ?assertEqual(maps:get(id, Device), maps:get(device_id, DeviceStep)).

cancel_does_not_delete_created_device_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_cancel_device">>),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    {ok, _Selected} = ias_provisioning_wizard_store:select_device(
        maps:get(id, Draft), maps:get(id, Device)),
    ok = ias_provisioning_wizard_store:delete(maps:get(id, Draft)),
    ?assertMatch({ok, _}, ias_demo_store:get(maps:get(id, Device))).


device_next_is_disabled_until_selection_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    Html = render(ias_provisioning_wizard:content_for({draft, Draft})),
    ?assertMatch({_, _}, binary:match(Html, <<">Next</span>">>)).

device_step_renders_selection_and_creation_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    _Device = demo_device(<<"wizard_render_device">>),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    Html = render(ias_provisioning_wizard:content_for({draft, Draft})),
    ?assertMatch({_, _}, binary:match(Html, <<"Use Existing Device">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Create New Demo Device">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Create and Select Device">>)).

step_boundaries_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, SchemeDraft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => scheme}),
    {ok, StillScheme} = ias_provisioning_wizard_store:back(maps:get(id, SchemeDraft)),
    ?assertEqual(scheme, maps:get(current_step, StillScheme)),
    {ok, LastDraft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => provisioning}),
    {ok, StillLast} = ias_provisioning_wizard_store:next(maps:get(id, LastDraft)),
    ?assertEqual(provisioning, maps:get(current_step, StillLast)).

cancel_deletes_draft_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    Id = maps:get(id, Draft),
    ok = ias_provisioning_wizard_store:delete(Id),
    ?assertEqual(not_found, ias_provisioning_wizard_store:get(Id)).

refresh_get_restores_current_step_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_refresh_device">>),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Selected} = ias_provisioning_wizard_store:select_device(
        maps:get(id, Draft0), maps:get(id, Device)),
    {ok, Draft1} = ias_provisioning_wizard_store:next(maps:get(id, Selected)),
    {ok, Restored} = ias_provisioning_wizard_store:get(maps:get(id, Draft1)),
    ?assertEqual(security_profile, maps:get(current_step, Restored)).

invalid_wizard_id_test() ->
    ias_provisioning_wizard_store:clear(),
    ?assertEqual(not_found, ias_provisioning_wizard_store:get(<<"missing_wizard">>)),
    Html = render(ias_provisioning_wizard:content_for({error, <<"missing_wizard">>})),
    ?assertMatch({_, _}, binary:match(Html, <<"Wizard draft not found">>)).

drafts_are_exported_in_demo_state_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    Snapshot = ias_demo_state:export(),
    ?assertMatch({_, _}, binary:match(Snapshot, maps:get(id, Draft))),
    ?assertMatch({_, _}, binary:match(Snapshot, <<"wizard_drafts">>)),
    ?assertMatch({_, _}, binary:match(Snapshot, <<"provisioning_wizard_">>)).

portable_scheme_is_disabled_test() ->
    Html = render(ias_provisioning_wizard:content_for(start)),
    ?assertEqual(false, ias_provisioning_wizard_store:portable_enabled()),
    ?assertMatch({_, _}, binary:match(Html, <<"Portable VPN Profile">>)),
    ?assertMatch({_, _}, binary:match(Html, ias_provisioning_wizard_store:portable_reason())),
    ?assertMatch({_, _}, binary:match(Html, <<"Disabled">>)).

ovpn_import_scheme_links_existing_route_test() ->
    Html = render(ias_provisioning_wizard:content_for(start)),
    ?assertEqual(<<"/app/ovpn.htm">>, ias_provisioning_wizard_store:ovpn_import_url()),
    ?assertMatch({_, _}, binary:match(Html, <<"Import Existing OVPN">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"/app/ovpn.htm">>)).

security_profile_step_requires_selection_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_profile_required_device">>),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, SelectedDevice} = ias_provisioning_wizard_store:select_device(
        maps:get(id, Draft0), maps:get(id, Device)),
    {ok, ProfileStep} = ias_provisioning_wizard_store:next(maps:get(id, SelectedDevice)),
    ?assertEqual({error, security_profile_required},
                 ias_provisioning_wizard_store:next(maps:get(id, ProfileStep))).

security_profile_can_be_selected_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, ProfileStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => security_profile}),
    {ok, Selected} = ias_provisioning_wizard_store:select_security_profile(
        maps:get(id, ProfileStep), administrator),
    ?assertEqual(administrator, maps:get(security_profile_id, Selected)),
    ?assertMatch({ok, _}, ias_provisioning_wizard_store:selected_security_profile(Selected)),
    {ok, VpnStep} = ias_provisioning_wizard_store:next(maps:get(id, Selected)),
    ?assertEqual(vpn_service, maps:get(current_step, VpnStep)).

security_profile_warning_is_allowed_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, ProfileStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => security_profile}),
    {ok, Selected} = ias_provisioning_wizard_store:select_security_profile(
        maps:get(id, ProfileStep), default_user),
    {ok, Profile} = ias_provisioning_wizard_store:selected_security_profile(Selected),
    ?assertMatch({warning, _},
                 ias_provisioning_wizard_store:security_profile_compatibility(Profile)),
    ?assertMatch({ok, _}, ias_provisioning_wizard_store:next(maps:get(id, Selected))).

stale_security_profile_blocks_next_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Stale} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => security_profile,
                               security_profile_id => <<"missing_profile">>}),
    ?assertEqual({error, selected_security_profile_missing},
                 ias_provisioning_wizard_store:next(maps:get(id, Stale))).

security_profile_step_renders_effects_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, ProfileStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => security_profile}),
    {ok, Selected} = ias_provisioning_wizard_store:select_security_profile(
        maps:get(id, ProfileStep), administrator),
    Html = render(ias_provisioning_wizard:content_for({draft, Selected})),
    ?assertMatch({_, _}, binary:match(Html, <<"Selected Security Profile">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Device Lock">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Provisioning Mode">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"device_bound">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"device_owned">>)).

security_profile_next_is_disabled_until_selection_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, ProfileStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => security_profile}),
    Html = render(ias_provisioning_wizard:content_for({draft, ProfileStep})),
    ?assertMatch({_, _}, binary:match(Html, <<">Next</span>">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Choose Security Profile">>)).

incompatible_security_profile_is_blocked_test() ->
    ?assertEqual({blocked, incompatible_security_profile},
                 ias_provisioning_wizard_store:security_profile_compatibility(#{})).

bootstrap_page_is_packaged_test() ->
    Path = filename:join(["priv", "static", "provisioning-wizard.htm"]),
    ?assert(filelib:is_regular(Path)),
    {ok, Html} = file:read_file(Path),
    ?assertMatch({_, _}, binary:match(Html, <<"<title>Provisioning Wizard</title>">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"id=\"stand\"">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"N2O_start()">>)).

start_page_lists_existing_drafts_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    Html = render(ias_provisioning_wizard:content_for(start)),
    ?assertMatch({_, _}, binary:match(Html, <<"Existing Wizard Drafts">>)),
    ?assertMatch({_, _}, binary:match(Html, maps:get(id, Draft))),
    ?assertMatch({_, _}, binary:match(Html, <<"Resume">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Delete">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"?id=", (maps:get(id, Draft))/binary>>)).

start_page_handles_no_existing_drafts_test() ->
    ias_provisioning_wizard_store:clear(),
    Html = render(ias_provisioning_wizard:content_for(start)),
    ?assertMatch({_, _}, binary:match(Html, <<"No saved wizard drafts are available">>)).

demo_device(Id) ->
    ias_demo_store:put_runtime_object(#{id => Id,
                                        kind => device,
                                        source => manual_device,
                                        name => <<"Wizard Device">>,
                                        type => <<"vpn-client">>,
                                        tunnel_device => <<"tun">>,
                                        transport => <<"udp">>,
                                        endpoint => <<"vpn.example.com">>}).

render(Doc) ->
    iolist_to_binary(nitro:render(Doc)).

vpn_service_step_requires_selection_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, VpnStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => vpn_service}),
    ?assertEqual({error, vpn_service_required},
                 ias_provisioning_wizard_store:next(maps:get(id, VpnStep))).

vpn_service_can_be_selected_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    Service = demo_vpn_service(<<"wizard_selected_vpn_service">>),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, VpnStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => vpn_service}),
    {ok, Selected} = ias_provisioning_wizard_store:select_vpn_service(
        maps:get(id, VpnStep), maps:get(id, Service)),
    ?assertEqual(maps:get(id, Service), maps:get(vpn_service_id, Selected)),
    ?assertMatch({ok, _}, ias_provisioning_wizard_store:selected_vpn_service(Selected)),
    {ok, CaStep} = ias_provisioning_wizard_store:next(maps:get(id, Selected)),
    ?assertEqual(ca_certificate, maps:get(current_step, CaStep)).

stale_vpn_service_blocks_next_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Stale} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => vpn_service,
                               vpn_service_id => <<"missing_vpn_service">>}),
    ?assertEqual({error, selected_vpn_service_missing},
                 ias_provisioning_wizard_store:next(maps:get(id, Stale))).

manual_vpn_service_validation_test() ->
    ias_demo_store:clear(),
    ?assertEqual({error, <<"Service Name is required">>},
                 ias_manual_vpn_service:create(#{name => <<>>, endpoint => <<"vpn.example.com">>,
                                                 port => <<"1194">>, protocol => <<"udp">>})),
    ?assertEqual({error, <<"Endpoint is required">>},
                 ias_manual_vpn_service:create(#{name => <<"VPN">>, endpoint => <<>>,
                                                 port => <<"1194">>, protocol => <<"udp">>})),
    ?assertEqual({error, <<"Port must be an integer from 1 to 65535">>},
                 ias_manual_vpn_service:create(#{name => <<"VPN">>, endpoint => <<"vpn.example.com">>,
                                                 port => <<"70000">>, protocol => <<"udp">>})),
    ?assertEqual({error, <<"Protocol must be udp or tcp">>},
                 ias_manual_vpn_service:create(#{name => <<"VPN">>, endpoint => <<"vpn.example.com">>,
                                                 port => <<"1194">>, protocol => <<"sctp">>})).

manual_vpn_service_creation_uses_binary_input_test() ->
    ias_demo_store:clear(),
    {ok, Service} = ias_manual_vpn_service:create(
        #{name => <<"Wizard VPN">>, endpoint => <<"vpn.example.com">>,
          port => <<"443">>, protocol => <<"tcp">>}),
    ?assertEqual(vpn_service, maps:get(kind, Service)),
    ?assertEqual(manual_vpn_service, maps:get(source, Service)),
    ?assertEqual(<<"tcp">>, maps:get(protocol, Service)),
    ?assertEqual(<<"443">>, maps:get(remote_port, Service)),
    ?assertMatch({ok, _}, ias_demo_store:get(maps:get(id, Service))).

vpn_service_step_renders_selection_and_creation_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    _Service = demo_vpn_service(<<"wizard_render_vpn_service">>),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, VpnStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => vpn_service}),
    Html = render(ias_provisioning_wizard:content_for({draft, VpnStep})),
    ?assertMatch({_, _}, binary:match(Html, <<"Use Existing VPN Service">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Create New Demo VPN Service">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Create and Select VPN Service">>)),
    ?assertMatch({_, _}, binary:match(Html, <<">Next</span>">>)).

vpn_service_back_preserves_selection_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    Service = demo_vpn_service(<<"wizard_preserved_vpn_service">>),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, VpnStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => vpn_service}),
    {ok, Selected} = ias_provisioning_wizard_store:select_vpn_service(
        maps:get(id, VpnStep), maps:get(id, Service)),
    {ok, CaStep} = ias_provisioning_wizard_store:next(maps:get(id, Selected)),
    {ok, Back} = ias_provisioning_wizard_store:back(maps:get(id, CaStep)),
    ?assertEqual(maps:get(id, Service), maps:get(vpn_service_id, Back)).

cancel_does_not_delete_created_vpn_service_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Service} = ias_manual_vpn_service:create(
        #{name => <<"Persistent Wizard VPN">>, endpoint => <<"vpn.example.com">>,
          port => <<"1194">>, protocol => <<"udp">>}),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    {ok, _Selected} = ias_provisioning_wizard_store:select_vpn_service(
        maps:get(id, Draft), maps:get(id, Service)),
    ok = ias_provisioning_wizard_store:delete(maps:get(id, Draft)),
    ?assertMatch({ok, _}, ias_demo_store:get(maps:get(id, Service))).

demo_vpn_service(Id) ->
    ias_demo_store:put_runtime_object(#{id => Id,
                                        kind => vpn_service,
                                        source => manual_vpn_service,
                                        name => <<"Wizard VPN">>,
                                        service => openvpn,
                                        remote => <<"vpn.example.com:1194">>,
                                        remote_host => <<"vpn.example.com">>,
                                        remote_port => <<"1194">>,
                                        protocol => <<"udp">>,
                                        tls_auth => not_configured}).


ca_certificate_step_requires_selection_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => ca_certificate}),
    ?assertEqual({error, ca_certificate_required},
                 ias_provisioning_wizard_store:next(maps:get(id, Step))).

ca_certificate_with_material_can_be_selected_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Certificate} = ias_demo_ca_certificate:register(valid_ca_fields()),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => ca_certificate}),
    {ok, Selected} = ias_provisioning_wizard_store:select_ca_certificate(
        maps:get(id, Step), maps:get(id, Certificate)),
    ?assertEqual(maps:get(id, Certificate), maps:get(ca_certificate_id, Selected)),
    {ok, ClientStep} = ias_provisioning_wizard_store:next(maps:get(id, Selected)),
    ?assertEqual(client_certificate, maps:get(current_step, ClientStep)).

ca_certificate_without_material_blocks_next_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Certificate = #{id => <<"wizard_ca_without_material">>, kind => certificate,
                    source => ca_certificate, material_type => ca_certificate,
                    certificate_role => ca_certificate, name => <<"CA">>,
                    subject => <<"CN=CA">>},
    ias_demo_store:put_runtime_object(Certificate),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => ca_certificate}),
    {ok, Selected} = ias_provisioning_wizard_store:select_ca_certificate(
        maps:get(id, Step), maps:get(id, Certificate)),
    ?assertEqual({error, ca_certificate_material_required},
                 ias_provisioning_wizard_store:next(maps:get(id, Selected))).

client_certificate_is_rejected_as_ca_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Certificate = #{id => <<"wizard_client_certificate">>, kind => certificate,
                    source => certificate_issue_demo,
                    certificate_role => client_certificate},
    ias_demo_store:put_runtime_object(Certificate),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    ?assertEqual({error, invalid_ca_certificate},
                 ias_provisioning_wizard_store:select_ca_certificate(
                     maps:get(id, Draft), maps:get(id, Certificate))).

stale_ca_certificate_blocks_next_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Stale} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => ca_certificate,
                               ca_certificate_id => <<"missing_ca">>}),
    ?assertEqual({error, selected_ca_certificate_missing},
                 ias_provisioning_wizard_store:next(maps:get(id, Stale))).

ca_certificate_step_renders_selection_and_registration_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, _Certificate} = ias_demo_ca_certificate:register(valid_ca_fields()),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => ca_certificate}),
    Html = render(ias_provisioning_wizard:content_for({draft, Step})),
    ?assertMatch({_, _}, binary:match(Html, <<"Use Existing CA Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Register New Demo CA Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Register and Select CA Certificate">>)).

ca_certificate_next_is_disabled_without_material_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => ca_certificate}),
    Html = render(ias_provisioning_wizard:content_for({draft, Step})),
    ?assertMatch({_, _}, binary:match(Html, <<">Next</span>">>)).

valid_ca_fields() ->
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    #{name => <<"Wizard Demo CA">>, subject => <<"CN=Wizard Demo CA">>, pem => Pem}.
