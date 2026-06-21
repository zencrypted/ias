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

selecting_valid_existing_device_advances_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_auto_device">>),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Advanced} = ias_provisioning_wizard_store:select_existing_device(
        maps:get(id, Draft), maps:get(id, Device)),
    ?assertEqual(maps:get(id, Device), maps:get(device_id, Advanced)),
    ?assertEqual(security_profile, maps:get(current_step, Advanced)).

newly_created_device_selection_does_not_auto_advance_test() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Device} = ias_manual_device:create(#{name => <<"Wizard Created Laptop">>,
                                               type => <<"vpn-client">>,
                                               tunnel_device => <<"tun">>,
                                               transport => <<"udp">>,
                                               endpoint => <<"vpn.example.com">>}),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Selected} = ias_provisioning_wizard_store:select_device(
        maps:get(id, Draft), maps:get(id, Device)),
    ?assertEqual(maps:get(id, Device), maps:get(device_id, Selected)),
    ?assertEqual(device, maps:get(current_step, Selected)).

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
    ?assertEqual(<<"Security Profile & Policy">>,
                 ias_provisioning_wizard_store:step_title(security_profile)),
    ?assertMatch({_, _}, binary:match(Html, <<"Derived Policy">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"High Security">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Device, Client Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Automatic after Client Certificate">>)),
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

vpn_create_and_select_advances_to_ca_step_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, VpnStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => vpn_service}),
    {ok, Service} = ias_manual_vpn_service:create(
        #{name => <<"Auto VPN">>, endpoint => <<"vpn.example.com">>,
          port => <<"1194">>, protocol => <<"udp">>}),
    {ok, Advanced} = ias_provisioning_wizard_store:select_existing_vpn_service(
        maps:get(id, VpnStep), maps:get(id, Service)),
    ?assertEqual(maps:get(id, Service), maps:get(vpn_service_id, Advanced)),
    ?assertEqual(ca_certificate, maps:get(current_step, Advanced)).

failed_vpn_create_validation_does_not_advance_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, VpnStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => vpn_service}),
    ?assertMatch({error, _},
                 ias_manual_vpn_service:create(
                     #{name => <<>>, endpoint => <<"vpn.example.com">>,
                       port => <<"1194">>, protocol => <<"udp">>})),
    {ok, Current} = ias_provisioning_wizard_store:get(maps:get(id, VpnStep)),
    ?assertEqual(vpn_service, maps:get(current_step, Current)),
    ?assertEqual(undefined, maps:get(vpn_service_id, Current)).

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

selecting_valid_existing_ca_certificate_advances_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Certificate} = ias_demo_ca_certificate:register(valid_ca_fields()),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => ca_certificate}),
    {ok, Advanced} = ias_provisioning_wizard_store:select_existing_ca_certificate(
        maps:get(id, Step), maps:get(id, Certificate)),
    ?assertEqual(maps:get(id, Certificate), maps:get(ca_certificate_id, Advanced)),
    ?assertEqual(client_certificate, maps:get(current_step, Advanced)).

ca_register_and_select_advances_to_client_certificate_step_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, CaStep} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => ca_certificate}),
    {ok, Certificate} = ias_demo_ca_certificate:register(valid_ca_fields()),
    {ok, Advanced} = ias_provisioning_wizard_store:select_existing_ca_certificate(
        maps:get(id, CaStep), maps:get(id, Certificate)),
    ?assertEqual(maps:get(id, Certificate), maps:get(ca_certificate_id, Advanced)),
    ?assertEqual(client_certificate, maps:get(current_step, Advanced)).

ca_certificate_missing_pem_does_not_auto_advance_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Certificate = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_auto_ca_missing_pem">>, kind => certificate,
          source => ca_certificate, material_type => ca_certificate,
          certificate_role => ca_certificate}),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => ca_certificate}),
    {ok, Selected} = ias_provisioning_wizard_store:select_existing_ca_certificate(
        maps:get(id, Step), maps:get(id, Certificate)),
    ?assertEqual(maps:get(id, Certificate), maps:get(ca_certificate_id, Selected)),
    ?assertEqual(ca_certificate, maps:get(current_step, Selected)).

ca_certificate_next_is_disabled_without_material_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => ca_certificate}),
    Html = render(ias_provisioning_wizard:content_for({draft, Step})),
    ?assertMatch({_, _}, binary:match(Html, <<">Next</span>">>)).


client_certificate_step_requires_selection_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate}),
    ?assertEqual({error, client_certificate_required},
                 ias_provisioning_wizard_store:next(maps:get(id, Step))).

client_certificate_with_material_can_be_selected_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_client_device">>, kind => device, source => manual_device}),
    Certificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_client_with_material">>, source => certificate_issue_demo,
          certificate_role => client_certificate, subject_cn => <<"wizard-client">>}),
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    {ok, _} = ias_certificate_material:put(maps:get(id, Certificate), client_certificate,
                                           Pem, operator_load),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate,
                               device_id => maps:get(id, Device)}),
    {ok, Selected} = ias_provisioning_wizard_store:select_client_certificate(
        maps:get(id, Step), maps:get(id, Certificate)),
    ?assertEqual(maps:get(id, Certificate), maps:get(client_certificate_id, Selected)),
    {ok, RelationshipsStep} = ias_provisioning_wizard_store:next(maps:get(id, Selected)),
    ?assertEqual(relationships, maps:get(current_step, RelationshipsStep)).

client_certificate_without_material_blocks_next_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Certificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_client_without_material">>, source => certificate_issue_demo,
          certificate_role => client_certificate}),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate}),
    {ok, Selected} = ias_provisioning_wizard_store:select_client_certificate(
        maps:get(id, Step), maps:get(id, Certificate)),
    ?assertEqual({error, client_certificate_material_required},
                 ias_provisioning_wizard_store:next(maps:get(id, Selected))).

ca_certificate_is_rejected_as_client_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Certificate} = ias_demo_ca_certificate:register(valid_ca_fields()),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    ?assertEqual({error, invalid_client_certificate},
                 ias_provisioning_wizard_store:select_client_certificate(
                     maps:get(id, Draft), maps:get(id, Certificate))).

client_certificate_linked_to_other_device_is_rejected_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Device1 = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_client_device_1">>, kind => device, source => manual_device}),
    Device2 = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_client_device_2">>, kind => device, source => manual_device}),
    Certificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_bound_client">>, source => certificate_issue_demo,
          certificate_role => client_certificate}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, Device1), maps:get(id, Certificate)),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{device_id => maps:get(id, Device2)}),
    ?assertEqual({error, client_certificate_linked_to_other_device},
                 ias_provisioning_wizard_store:select_client_certificate(
                     maps:get(id, Draft), maps:get(id, Certificate))).

stale_client_certificate_blocks_next_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Stale} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate,
                               client_certificate_id => <<"missing_client">>}),
    ?assertEqual({error, selected_client_certificate_missing},
                 ias_provisioning_wizard_store:next(maps:get(id, Stale))).

wizard_demo_client_certificate_issue_stores_material_test() ->
    ias_demo_state:clear(),
    User = ias_demo_store:put_runtime_object(
        #{id => alice, kind => user, name => <<"Alice">>, profile_id => administrator}),
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    {ok, Certificate} = ias_wizard_client_certificate:issue(
        #{user_id => maps:get(id, User), subject_cn => <<"alice-vpn">>, pem => Pem}),
    ?assertEqual(certificate_issue_demo, maps:get(source, Certificate)),
    ?assertMatch({ok, #{material_type := client_certificate}},
                 ias_certificate_material:status(maps:get(id, Certificate))).

client_certificate_step_renders_selection_and_issue_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    _User = ias_demo_store:put_runtime_object(
        #{id => alice, kind => user, name => <<"Alice">>, profile_id => administrator}),
    _Certificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_render_client">>, source => certificate_issue_demo,
          certificate_role => client_certificate, subject_cn => <<"wizard-client">>}),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate}),
    Html = render(ias_provisioning_wizard:content_for({draft, Step})),
    ?assertMatch({_, _}, binary:match(Html, <<"Use Existing Client Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Issue New Demo Client Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Issue and Select Client Certificate">>)).

client_certificate_step_links_to_ca_enrollment_with_wizard_context_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_enroll_context_device">>),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft1} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate,
                                device_id => maps:get(id, Device)}),

    Html = render(ias_provisioning_wizard:content_for({draft, Draft1})),

    ?assertMatch({_, _}, binary:match(Html, <<"Request Certificate from CA">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"/app/certificate-enrollment.htm?">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"return_to=provisioning_wizard">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"wizard_id=", (maps:get(id, Draft1))/binary>>)),
    ?assertMatch({_, _}, binary:match(Html, <<"device_id=wizard_enroll_context_device">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"suggested_cn=Wizard%20Device">>)).

certificate_enrollment_page_renders_wizard_return_context_test() ->
    Context = #{wizard_id => <<"wizard_return_context">>,
                return_to => <<"provisioning_wizard">>,
                device_id => <<"wizard_return_device">>,
                suggested_cn => <<"wizard-client">>},

    Html = render(ias_enroll:content_for(Context)),

    ?assertMatch({_, _}, binary:match(Html, <<"Return to Provisioning Wizard">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"wizard_return_device">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"wizard-client">>)),
    ?assertMatch({_, _}, binary:match(
        Html, <<"/app/provisioning-wizard.htm?id=wizard_return_context">>)).

imported_cmp_certificate_can_be_selected_by_wizard_context_test() ->
    Draft = client_issue_ready_draft(),
    Pem = public_key:pem_encode([{'Certificate', <<4,3,2,1>>, not_encrypted}]),
    EnrollmentId = ias_demo_store:add_enrollment_result(
        #{subject => <<"CN=wizard-imported-client">>,
          issuer => <<"CN=Wizard CA">>,
          not_before => <<"Jun 21 00:00:00 2026 GMT">>,
          not_after => <<"Jun 21 00:00:00 2027 GMT">>,
          requested_cn => <<"wizard-imported-client">>,
          enrollment_cn => <<"wizard-imported-client-20260621">>,
          profile => <<"secp384r1">>,
          cmp_server => <<"127.0.0.1:8829">>}),
    {ok, _} = ias_certificate_material:stage_cmp(EnrollmentId, Pem),
    {ok, Certificate} = ias_cert_enrollment_import:import(EnrollmentId),

    {ok, Advanced} = ias_provisioning_wizard_store:select_existing_client_certificate(
        maps:get(id, Draft), maps:get(id, Certificate)),

    ?assertEqual(maps:get(id, Certificate), maps:get(client_certificate_id, Advanced)),
    ?assertEqual(material_readiness, maps:get(current_step, Advanced)),
    ?assertEqual(true, maps:get(relationships_applied, Advanced)),
    ?assertEqual(true, ias_provisioning_wizard_store:relationships_ready(Advanced)).

client_certificate_missing_body_renders_disabled_selection_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    _Certificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_missing_pem_client">>, source => certificate_issue_demo,
          certificate_role => client_certificate, subject_cn => <<"missing-pem-client">>}),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate}),

    Html = render(ias_provisioning_wizard:content_for({draft, Step})),

    ?assertMatch({_, _}, binary:match(Html, <<"Demo Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"PEM Missing">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"PEM Required">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Select — PEM required">>)).

client_certificate_generic_missing_pem_omits_demo_badge_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    _Certificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_generic_missing_pem_client">>, source => manual_certificate,
          certificate_role => client_certificate, subject_cn => <<"generic-client">>}),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate}),

    Html = render(ias_provisioning_wizard:content_for({draft, Step})),

    ?assertEqual(nomatch, binary:match(Html, <<"Demo Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"PEM Missing">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"PEM Required">>)).

client_certificate_cmp_material_renders_recommended_badges_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Certificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_cmp_client">>, source => cmp_demo_enrollment,
          certificate_role => client_certificate, subject_cn => <<"cmp-client">>}),
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    {ok, _} = ias_certificate_material:put(maps:get(id, Certificate),
                                           client_certificate, Pem, cmp_response),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate}),

    Html = render(ias_provisioning_wizard:content_for({draft, Step})),

    ?assertMatch({_, _}, binary:match(Html, <<"Recommended">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Issued by CA">>)).

selecting_valid_existing_cmp_client_certificate_auto_commits_relationships_test() ->
    Draft = auto_client_certificate_draft(),
    ClientId = maps:get(client_certificate_id, Draft),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft), #{current_step => client_certificate,
                               client_certificate_id => undefined,
                               relationships_applied => false}),
    {ok, Advanced} = ias_provisioning_wizard_store:select_existing_client_certificate(
        maps:get(id, Step), ClientId),

    ?assertEqual(ClientId, maps:get(client_certificate_id, Advanced)),
    ?assertEqual(material_readiness, maps:get(current_step, Advanced)),
    ?assertEqual(true, maps:get(relationships_applied, Advanced)),
    ?assertEqual(true, ias_provisioning_wizard_store:relationships_ready(Advanced)).

client_issue_and_select_advances_through_relationship_preflight_test() ->
    Draft = client_issue_ready_draft(),
    User = ias_demo_store:put_runtime_object(
        #{id => alice, kind => user, name => <<"Alice">>, profile_id => administrator}),
    Pem = public_key:pem_encode([{'Certificate', <<9,8,7,6>>, not_encrypted}]),
    {ok, Certificate} = ias_wizard_client_certificate:issue(
        #{user_id => maps:get(id, User), subject_cn => <<"issued-auto-client">>,
          pem => Pem}),
    {ok, Advanced} = ias_provisioning_wizard_store:select_existing_client_certificate(
        maps:get(id, Draft), maps:get(id, Certificate)),

    ?assertEqual(maps:get(id, Certificate), maps:get(client_certificate_id, Advanced)),
    ?assertEqual(material_readiness, maps:get(current_step, Advanced)),
    ?assertEqual(true, maps:get(relationships_applied, Advanced)),
    ?assertEqual(true, ias_provisioning_wizard_store:relationships_ready(Advanced)).

client_certificate_missing_pem_selection_does_not_advance_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Certificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_auto_missing_pem_client">>,
          source => certificate_issue_demo,
          certificate_role => client_certificate,
          subject_cn => <<"missing-pem-client">>}),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate}),
    {ok, Selected} = ias_provisioning_wizard_store:select_existing_client_certificate(
        maps:get(id, Step), maps:get(id, Certificate)),

    ?assertEqual(maps:get(id, Certificate), maps:get(client_certificate_id, Selected)),
    ?assertEqual(client_certificate, maps:get(current_step, Selected)).

client_certificate_step_displays_pem_helper_text_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Step} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate}),

    Html = render(ias_provisioning_wizard:content_for({draft, Step})),

    ?assertMatch({_, _}, binary:match(
        Html,
        <<"Only certificates with public PEM material can be used for OVPN provisioning.">>)),
    ?assertMatch({_, _}, binary:match(
        Html,
        <<"CMP-issued certificates are recommended">>)).

valid_ca_fields() ->
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    #{name => <<"Wizard Demo CA">>, subject => <<"CN=Wizard Demo CA">>, pem => Pem}.

auto_client_certificate_draft() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_auto_client_device">>),
    Service = demo_vpn_service(<<"wizard_auto_client_service">>),
    {ok, CaCertificate} = ias_demo_ca_certificate:register(valid_ca_fields()),
    ClientCertificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_auto_cmp_client">>, source => cmp_demo_enrollment,
          certificate_role => client_certificate, certificate_status => trusted,
          profile_id => administrator, profile => administrator,
          subject_cn => <<"auto-cmp-client">>, private_key_stored => false,
          certificate_body_stored => false}),
    Pem = public_key:pem_encode([{'Certificate', <<5,6,7,8>>, not_encrypted}]),
    {ok, _} = ias_certificate_material:put(maps:get(id, ClientCertificate),
                                           client_certificate, Pem, cmp_response),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0),
        #{current_step => client_certificate,
          device_id => maps:get(id, Device),
          security_profile_id => administrator,
          vpn_service_id => maps:get(id, Service),
          ca_certificate_id => maps:get(id, CaCertificate),
          client_certificate_id => maps:get(id, ClientCertificate),
          relationships_applied => false}),
    Draft.

client_issue_ready_draft() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = demo_device(<<"wizard_issue_auto_device">>),
    Service = demo_vpn_service(<<"wizard_issue_auto_service">>),
    {ok, CaCertificate} = ias_demo_ca_certificate:register(valid_ca_fields()),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0),
        #{current_step => client_certificate,
          device_id => maps:get(id, Device),
          security_profile_id => administrator,
          vpn_service_id => maps:get(id, Service),
          ca_certificate_id => maps:get(id, CaCertificate),
          client_certificate_id => undefined,
          relationships_applied => false}),
    Draft.
