-module(ias_provisioning_wizard_transaction_tests).
-include_lib("eunit/include/eunit.hrl").

provisioning_transaction_is_created_and_recorded_test() ->
    Draft = setup_ready_wizard(),
    WizardId = maps:get(id, Draft),

    {ok, Completed, Transaction} =
        ias_provisioning_wizard_store:create_provisioning(WizardId),

    ?assertEqual(true, maps:get(completed, Completed)),
    ?assertEqual(provisioning, maps:get(current_step, Completed)),
    ?assertEqual(maps:get(id, Transaction), maps:get(provisioning_id, Completed)),
    ?assertMatch({ok, _}, ias_ovpn_provisioning:get(maps:get(id, Transaction))),
    ?assertEqual(allow, maps:get(authorization, Transaction)),
    ?assertEqual(public_material_available, maps:get(material_status, Transaction)),
    ?assertEqual(ready_for_delivery, maps:get(status, Transaction)),
    ?assertEqual(public_bundle_ready, maps:get(assembly_status, Transaction)),
    ?assertEqual(public_bundle_ready, maps:get(artifact_status, Transaction)),
    ?assertEqual(ready_for_device_import, maps:get(delivery_status, Transaction)).

provisioning_creation_is_idempotent_test() ->
    Draft = setup_ready_wizard(),
    WizardId = maps:get(id, Draft),
    {ok, _Completed1, Transaction1} =
        ias_provisioning_wizard_store:create_provisioning(WizardId),
    Count1 = provisioning_count(),

    {ok, Completed2, Transaction2} =
        ias_provisioning_wizard_store:create_provisioning(WizardId),

    ?assertEqual(maps:get(id, Transaction1), maps:get(id, Transaction2)),
    ?assertEqual(maps:get(id, Transaction1), maps:get(provisioning_id, Completed2)),
    ?assertEqual(Count1, provisioning_count()).

create_another_transaction_is_explicit_test() ->
    Draft = setup_ready_wizard(),
    WizardId = maps:get(id, Draft),
    {ok, _Completed1, Transaction1} =
        ias_provisioning_wizard_store:create_provisioning(WizardId),

    {ok, Completed2, Transaction2} =
        ias_provisioning_wizard_store:create_another_provisioning(WizardId),

    ?assertNotEqual(maps:get(id, Transaction1), maps:get(id, Transaction2)),
    ?assertEqual(maps:get(id, Transaction2), maps:get(provisioning_id, Completed2)),
    ?assertMatch({ok, _}, ias_ovpn_provisioning:get(maps:get(id, Transaction1))),
    ?assertMatch({ok, _}, ias_ovpn_provisioning:get(maps:get(id, Transaction2))),
    ?assertEqual(2, provisioning_count()).

stale_recorded_transaction_requires_explicit_replacement_test() ->
    Draft = setup_ready_wizard(),
    WizardId = maps:get(id, Draft),
    {ok, Completed, Transaction1} =
        ias_provisioning_wizard_store:create_provisioning(WizardId),
    ok = ias_demo_store:delete_runtime_object(ovpn_provisioning,
                                               maps:get(id, Transaction1)),

    ?assertEqual({error, provisioning_transaction_missing},
                 ias_provisioning_wizard_store:create_provisioning(WizardId)),
    {ok, ReplacementDraft, Transaction2} =
        ias_provisioning_wizard_store:create_another_provisioning(WizardId),
    ?assertNotEqual(maps:get(provisioning_id, Completed), maps:get(id, Transaction2)),
    ?assertEqual(maps:get(id, Transaction2), maps:get(provisioning_id, ReplacementDraft)).

selection_change_resets_completed_transaction_reference_test() ->
    Draft = setup_ready_wizard(),
    WizardId = maps:get(id, Draft),
    {ok, Completed, _Transaction} =
        ias_provisioning_wizard_store:create_provisioning(WizardId),
    NewService = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_transaction_new_service">>, kind => vpn_service,
          source => manual_vpn_service, name => <<"New OpenVPN">>, service => openvpn,
          remote => <<"new.example.com:1194">>, remote_host => <<"new.example.com">>,
          remote_port => <<"1194">>, protocol => <<"udp">>, tls_auth => not_configured}),

    {ok, Changed} = ias_provisioning_wizard_store:select_vpn_service(
        maps:get(id, Completed), maps:get(id, NewService)),

    ?assertEqual(false, maps:get(completed, Changed)),
    ?assertEqual(undefined, maps:get(provisioning_id, Changed)),
    ?assertEqual(false, maps:get(relationships_applied, Changed)).

blocked_readiness_does_not_create_transaction_test() ->
    Draft = setup_ready_wizard(),
    ClientCertificateId = maps:get(client_certificate_id, Draft),
    ok = ias_certificate_material:delete(ClientCertificateId),

    ?assertEqual({error, material_readiness_blocked},
                 ias_provisioning_wizard_store:create_provisioning(maps:get(id, Draft))),
    ?assertEqual(0, provisioning_count()).

provisioning_step_renders_create_and_completed_states_test() ->
    Draft = setup_ready_wizard(),
    HtmlBefore = render(ias_provisioning_wizard:content_for({draft, Draft})),
    ?assertMatch({_, _}, binary:match(HtmlBefore, <<"Final Provisioning Summary">>)),
    ?assertMatch({_, _}, binary:match(HtmlBefore, <<"Create Provisioning Transaction">>)),

    {ok, Completed, Transaction} =
        ias_provisioning_wizard_store:create_provisioning(maps:get(id, Draft)),
    HtmlAfter = render(ias_provisioning_wizard:content_for({draft, Completed})),
    ?assertMatch({_, _}, binary:match(HtmlAfter, <<"Provisioning Transaction Created">>)),
    ?assertMatch({_, _}, binary:match(HtmlAfter, maps:get(id, Transaction))),
    ?assertMatch({_, _}, binary:match(HtmlAfter, <<"Open Provisioning Transaction">>)),
    ?assertMatch({_, _}, binary:match(HtmlAfter, <<"Download Device-bound OVPN">>)),
    ?assertMatch({_, _}, binary:match(HtmlAfter, <<"Create Another Transaction">>)),
    ?assertMatch({_, _}, binary:match(HtmlAfter, <<">Completed</span>">>)).

dynamic_allocation_is_rendered_in_completed_wizard_test() ->
    Draft = setup_ready_wizard(),
    DeviceId = maps:get(device_id, Draft),
    {ok, Device} = ias_demo_store:get(DeviceId),
    DynamicDevice = Device#{runtime_peer_id => <<"client_dyn_wizard_ui">>,
                            vpn_peer => <<"client_dyn_wizard_ui">>,
                            vpn_allocation_id => <<"dynamic-vpn-wizard-ui">>,
                            vpn_allocator_instance_id => <<"allocator-wizard-ui">>,
                            vpn_client_peer_id => <<"client_dyn_wizard_ui">>,
                            vpn_gateway_peer_id => <<"gateway_dyn_wizard_ui">>,
                            vpn_allocation_slot => 4,
                            vpn_allocation_generation => 12,
                            vpn_allocation_state => reserved,
                            vpn_allocation_persistence => volatile,
                            vpn_dynamic_pair_state => established,
                            vpn_dynamic_pair_reconciled_at => 1782290100},
    _ = ias_demo_store:put_runtime_object(DynamicDevice),
    {ok, Completed, _Transaction} =
        ias_provisioning_wizard_store:create_provisioning(maps:get(id, Draft)),
    Html = render(ias_provisioning_wizard:content_for({draft, Completed})),
    ?assertMatch({_, _}, binary:match(Html, <<"Dynamic VPN Allocation">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"dynamic-vpn-wizard-ui">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"client_dyn_wizard_ui">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"gateway_dyn_wizard_ui">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"allocator-wizard-ui">>)),
    ?assertMatch({_, _}, binary:match(Html, <<">dynamic</td>">>)),
    with_vpn_runtime_peer_id(
      <<"client_dyn_wizard_ui">>, false, false, false,
      fun() ->
          DisabledHtml = render(
                           ias_provisioning_wizard:content_for(
                             {draft, Completed})),
          ?assertMatch({_, _},
                       binary:match(DisabledHtml,
                                    <<"Decommission VPN Access">>))
      end),
    with_vpn_runtime_peer_id(
      <<"client_dyn_wizard_ui">>, false, false, true,
      fun() ->
          RevokedHtml = render(
                          ias_provisioning_wizard:content_for(
                            {draft, Completed})),
          ?assertMatch({_, _},
                       binary:match(RevokedHtml,
                                    <<"Decommission VPN Access">>))
      end).

vpn_lifecycle_actions_follow_runtime_state_test() ->
    Draft = setup_ready_wizard(),
    {ok, Completed, _Transaction} =
        ias_provisioning_wizard_store:create_provisioning(maps:get(id, Draft)),
    with_vpn_runtime_peer(true, true, false, fun() ->
        EnabledHtml = render(ias_provisioning_wizard:content_for({draft, Completed})),
        ?assertMatch({_, _}, binary:match(EnabledHtml, <<"Disable VPN Access">>)),
        ?assertMatch({_, _}, binary:match(EnabledHtml, <<"Revoke VPN Access">>)),
        ?assertEqual(nomatch, binary:match(EnabledHtml, <<"Enable VPN Access">>)),
        ?assertEqual(nomatch, binary:match(EnabledHtml, <<"Decommission VPN Access">>)),
        ?assertMatch({_, _}, binary:match(EnabledHtml, <<">enabled</td>">>))
    end),
    with_vpn_runtime_peer(false, false, false, fun() ->
        DisabledHtml = render(ias_provisioning_wizard:content_for({draft, Completed})),
        ?assertMatch({_, _}, binary:match(DisabledHtml, <<"Enable VPN Access">>)),
        ?assertMatch({_, _}, binary:match(DisabledHtml, <<"Revoke VPN Access">>)),
        ?assertEqual(nomatch, binary:match(DisabledHtml, <<"Decommission VPN Access">>)),
        ?assertEqual(nomatch, binary:match(DisabledHtml, <<"Disable VPN Access">>)),
        ?assertMatch({_, _}, binary:match(DisabledHtml, <<">disabled</td>">>))
    end),
    with_vpn_runtime_peer(false, false, true, fun() ->
        RevokedHtml = render(ias_provisioning_wizard:content_for({draft, Completed})),
        ?assertEqual(nomatch, binary:match(RevokedHtml, <<"Enable VPN Access">>)),
        ?assertEqual(nomatch, binary:match(RevokedHtml, <<"Disable VPN Access">>)),
        ?assertEqual(nomatch, binary:match(RevokedHtml, <<"Revoke VPN Access">>)),
        ?assertEqual(nomatch, binary:match(RevokedHtml, <<"Decommission VPN Access">>)),
        ?assertMatch({_, _}, binary:match(RevokedHtml, <<"VPN Access Revoked">>)),
        ?assertMatch({_, _}, binary:match(RevokedHtml, <<">revoked</td>">>)),
        ?assertMatch({match, _},
                     re:run(RevokedHtml,
                            <<"Authorized</th><td[^>]*>no</td>">>,
                            [{capture, first, index}]))
    end).

completed_wizard_roundtrips_through_demo_state_test() ->
    Draft = setup_ready_wizard(),
    {ok, Completed, Transaction} =
        ias_provisioning_wizard_store:create_provisioning(maps:get(id, Draft)),
    Snapshot = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    _Import = ias_demo_state:import(Snapshot),
    {ok, Restored} = ias_provisioning_wizard_store:get(maps:get(id, Completed)),

    ?assertEqual(true, maps:get(completed, Restored)),
    ?assertEqual(maps:get(id, Transaction), maps:get(provisioning_id, Restored)),
    ?assertMatch({ok, _}, ias_ovpn_provisioning:get(maps:get(id, Transaction))).

setup_ready_wizard() ->
    ias_demo_state:clear(),
    Device = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_transaction_device">>, kind => device,
          source => manual_device, name => <<"Laptop">>, type => <<"vpn-client">>,
          runtime_peer_id => client_a, vpn_peer => client_a,
          private_key_provider => <<"device_file">>, private_key_ref => <<"client.key">>}),
    Service = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_transaction_service">>, kind => vpn_service,
          source => manual_vpn_service, name => <<"OpenVPN">>, service => openvpn,
          remote => <<"vpn.example.com:1194">>, remote_host => <<"vpn.example.com">>,
          remote_port => <<"1194">>, protocol => <<"udp">>, tls_auth => not_configured}),
    CaCertificate = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_transaction_ca">>, kind => certificate,
          source => ca_certificate, material_type => ca_certificate,
          certificate_role => ca_certificate, certificate_status => trusted,
          name => <<"Demo CA">>, subject => <<"CN=Demo CA">>}),
    ClientCertificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_transaction_client">>, source => certificate_issue_demo,
          certificate_role => client_certificate, certificate_status => trusted,
          profile_id => administrator, profile => administrator,
          subject_cn => <<"vpn-client">>, private_key_stored => false,
          certificate_body_stored => false}),
    {ok, _} = ias_relationship_link:create(uses_security_profile,
                                            maps:get(id, Device), administrator),
    {ok, _} = ias_relationship_link:create(uses_service,
                                            maps:get(id, Device), maps:get(id, Service)),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                            maps:get(id, Device), maps:get(id, ClientCertificate)),
    {ok, _} = ias_relationship_link:create(uses_ca_certificate,
                                            maps:get(id, Service), maps:get(id, CaCertificate)),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                            maps:get(id, Device), <<"high_security">>),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                            maps:get(id, ClientCertificate), <<"high_security">>),
    verify_client_certificate(ClientCertificate),
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    {ok, _} = ias_certificate_material:put(maps:get(id, CaCertificate), ca_certificate,
                                           Pem, operator_load),
    {ok, _} = ias_certificate_material:put(maps:get(id, ClientCertificate), client_certificate,
                                           Pem, operator_load),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0),
        #{current_step => provisioning,
          device_id => maps:get(id, Device),
          security_profile_id => administrator,
          vpn_service_id => maps:get(id, Service),
          ca_certificate_id => maps:get(id, CaCertificate),
          client_certificate_id => maps:get(id, ClientCertificate),
          relationships_applied => true}),
    ?assertEqual(true, ias_provisioning_wizard_store:material_readiness_ready(Draft)),
    Draft.

verify_client_certificate(Certificate) ->
    {ok, Profile} = ias_security_profile:profile(administrator),
    Claims = ias_policy:certificate_claims(Profile),
    {ok, _} = ias_certificate_verification:verify(
        Certificate#{certificate_id => maps:get(id, Certificate),
                     issuer_cn => <<"Zencrypted Demo CA">>,
                     profile => Profile,
                     profile_id => administrator,
                     claims => Claims,
                     trusted => true,
                     key_match => true}),
    ok.

provisioning_count() ->
    length([Object || Object <- ias_demo_store:runtime_objects(),
                      maps:get(kind, Object, undefined) =:= ovpn_provisioning]).


with_vpn_runtime_peer(Enabled, Authorized, Revoked, Fun) ->
    with_vpn_runtime_peer_id(client_a,
                             Enabled,
                             Authorized,
                             Revoked,
                             Fun).

with_vpn_runtime_peer_id(PeerId, Enabled, Authorized, Revoked, Fun) ->
    PreviousTransport = application:get_env(ias, vpn_provisioning_transport),
    PreviousRpcFun = application:get_env(ias, vpn_provisioning_rpc_fun),
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(
        ias,
        vpn_provisioning_rpc_fun,
        fun(_Node, vpn_peer_registry, get, [RequestedPeerId], _Timeout)
              when RequestedPeerId =:= PeerId ->
                {ok, #{id => PeerId,
                       enabled => Enabled,
                       authorized => Authorized,
                       revoked => Revoked,
                       revision => 7,
                       last_provisioning_operation => upsert}};
           (_Node, _Module, _Function, _Args, _Timeout) ->
                {badrpc, unsupported_test_call}
        end),
    try Fun()
    after
        restore_env(vpn_provisioning_transport, PreviousTransport),
        restore_env(vpn_provisioning_rpc_fun, PreviousRpcFun)
    end.

restore_env(Key, {ok, Value}) ->
    application:set_env(ias, Key, Value);
restore_env(Key, undefined) ->
    application:unset_env(ias, Key).

render(Doc) ->
    iolist_to_binary(nitro:render(Doc)).
