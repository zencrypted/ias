-module(ias_provisioning_wizard_readiness_tests).
-include_lib("eunit/include/eunit.hrl").

material_readiness_blocks_without_public_material_test() ->
    Draft = setup_ready_graph(false),
    Readiness = ias_provisioning_wizard_store:material_readiness(Draft),
    Plan = maps:get(plan, Readiness),
    Components = maps:get(material_components, Plan),
    ?assertEqual(false, maps:get(ready, Readiness)),
    ?assertEqual(missing_body, maps:get(ca_certificate, Components)),
    ?assertEqual(missing_body, maps:get(client_certificate, Components)),
    ?assertEqual(blocked, maps:get(assembly_status, Plan)),
    ?assertEqual({error, material_readiness_blocked},
                 ias_provisioning_wizard_store:next(maps:get(id, Draft))).

material_readiness_allows_provisioning_when_public_material_is_available_test() ->
    Draft = setup_ready_graph(true),
    Readiness = ias_provisioning_wizard_store:material_readiness(Draft),
    Plan = maps:get(plan, Readiness),
    ?assertEqual(true, maps:get(ready, Readiness)),
    ?assertEqual(allow, maps:get(authorization, Plan)),
    ?assertEqual(public_material_available, maps:get(material_status, Plan)),
    ?assertEqual(ready_for_device_assembly, maps:get(assembly_status, Plan)),
    {ok, ProvisioningStep} = ias_provisioning_wizard_store:next(maps:get(id, Draft)),
    ?assertEqual(provisioning, maps:get(current_step, ProvisioningStep)).

material_readiness_step_renders_current_checks_test() ->
    Draft = setup_ready_graph(true),
    Html = iolist_to_binary(nitro:render(
        ias_provisioning_wizard:content_for({draft, Draft}))),
    ?assertMatch({_, _}, binary:match(Html, <<"Ready for Provisioning">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"VPN Endpoint">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"CA Certificate PEM">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Client Certificate PEM">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"available_on_device">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Readiness Decision">>)).

material_readiness_step_links_to_missing_certificate_material_test() ->
    Draft = setup_ready_graph(false),
    Html = iolist_to_binary(nitro:render(
        ias_provisioning_wizard:content_for({draft, Draft}))),
    ?assertMatch({_, _}, binary:match(Html, <<"Open CA Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Open Client Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<">Next</span>">>)).

material_observation_is_independent_from_authorization_test() ->
    Draft = setup_graph(true, false),
    Readiness = ias_provisioning_wizard_store:material_readiness(Draft),
    Plan = maps:get(plan, Readiness),
    PlanComponents = maps:get(material_components, Plan),
    ObservedComponents = maps:get(material_components, Readiness),
    ?assertEqual(deny, maps:get(authorization, Plan)),
    ?assertEqual(blocked, maps:get(ca_certificate, PlanComponents)),
    ?assertEqual(blocked, maps:get(client_certificate, PlanComponents)),
    ?assertEqual(available, maps:get(ca_certificate, ObservedComponents)),
    ?assertEqual(available, maps:get(client_certificate, ObservedComponents)),
    ?assertEqual(available_on_device, maps:get(private_key, ObservedComponents)),
    ?assertEqual(public_material_available, maps:get(material_status, Readiness)),
    ?assertEqual(blocked, maps:get(assembly_status, Plan)),
    ?assertEqual(false, maps:get(ready, Readiness)).

material_readiness_renders_available_material_during_authorization_denial_test() ->
    Draft = setup_graph(true, false),
    Html = iolist_to_binary(nitro:render(
        ias_provisioning_wizard:content_for({draft, Draft}))),
    ?assertMatch({_, _}, binary:match(Html, <<"Public CA certificate material is available.">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Public client certificate material is available.">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"available_on_device">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Provisioning Authorization">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Open CA Certificate">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Open Client Certificate">>)).

wizard_inline_verification_completes_authorization_prerequisites_test() ->
    Draft0 = setup_graph(true, false),
    {ok, Draft} = ias_provisioning_wizard_store:apply_relationships(
        maps:get(id, Draft0)),

    ?assertEqual(not_verified,
                 ias_provisioning_wizard_authorization:verification_status(Draft)),
    {ok, Verification} =
        ias_provisioning_wizard_authorization:verify_client_certificate(Draft),
    ?assertEqual(verified, maps:get(verification_status, Verification)),
    ?assertEqual(verified,
                 ias_provisioning_wizard_authorization:verification_status(Draft)),

    Readiness = ias_provisioning_wizard_store:material_readiness(Draft),
    ?assertEqual(true, maps:get(ready, Readiness)),
    ?assertEqual(allow, maps:get(authorization, maps:get(plan, Readiness))).

material_readiness_renders_inline_verification_action_test() ->
    Draft0 = setup_graph(true, false),
    {ok, Draft} = ias_provisioning_wizard_store:apply_relationships(
        maps:get(id, Draft0)),
    Html = iolist_to_binary(nitro:render(
        ias_provisioning_wizard:content_for({draft, Draft}))),

    ?assertMatch({_, _}, binary:match(Html, <<"Verify Client Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Client Certificate Verification">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Security Policy">>)).


readiness_remediation_repairs_relationships_and_verifies_test() ->
    Draft = setup_graph(true, false),
    WizardId = maps:get(id, Draft),

    ?assertEqual(false, ias_provisioning_wizard_store:relationships_ready(Draft)),
    ?assertEqual(not_verified,
                 ias_provisioning_wizard_authorization:verification_status(Draft)),

    {ok, Updated} = ias_provisioning_wizard_store:remediate_readiness(WizardId),

    ?assertEqual(true, ias_provisioning_wizard_store:relationships_ready(Updated)),
    ?assertEqual(true, maps:get(relationships_applied, Updated)),
    ?assertEqual(verified,
                 ias_provisioning_wizard_authorization:verification_status(Updated)),
    ?assertEqual(true,
                 maps:get(ready,
                          ias_provisioning_wizard_store:material_readiness(Updated))).

material_readiness_actions_are_contextual_test() ->
    Draft = setup_graph(true, false),
    Html0 = iolist_to_binary(nitro:render(
        ias_provisioning_wizard:content_for({draft, Draft}))),

    ?assertMatch({_, _}, binary:match(Html0, <<"Repair Relationships">>)),
    ?assertMatch({_, _}, binary:match(Html0, <<"Open Device">>)),
    ?assertMatch({_, _}, binary:match(Html0, <<"Open Client Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html0, <<"Verify Client Certificate">>)),
    ?assertEqual(nomatch, binary:match(Html0, <<"Open VPN Service">>)),
    ?assertEqual(nomatch, binary:match(Html0, <<"Open CA Certificate">>)),

    {ok, Updated} = ias_provisioning_wizard_store:remediate_readiness(
        maps:get(id, Draft)),
    Html1 = iolist_to_binary(nitro:render(
        ias_provisioning_wizard:content_for({draft, Updated}))),

    ?assertEqual(nomatch, binary:match(Html1, <<"Repair Relationships">>)),
    ?assertEqual(nomatch, binary:match(Html1, <<"Open Device">>)),
    ?assertEqual(nomatch, binary:match(Html1, <<"Open Client Certificate">>)),
    ?assertEqual(nomatch, binary:match(Html1, <<"Verify Client Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html1, <<"Refresh Readiness">>)).

progress_marks_broken_relationship_step_blocked_test() ->
    Draft = setup_ready_graph(true),
    [Relationship | _] = [R || R <- ias_demo_store:relationships(),
                               maps:get(relation_type, R, undefined) =:= uses_security_policy,
                               maps:get(source_kind, R, undefined) =:= device],
    ok = ias_demo_store:delete_relationship(maps:get(id, Relationship)),

    Html = iolist_to_binary(nitro:render(
        ias_provisioning_wizard:content_for({draft, Draft}))),

    ?assertMatch({_, _}, binary:match(Html, <<"7 Relationships">>)),
    ?assertMatch({_, _}, binary:match(Html, <<">blocked</span>">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"background:#fef2f2">>)).

setup_ready_graph(StoreMaterial) ->
    setup_graph(StoreMaterial, true).

setup_graph(StoreMaterial, AuthorizationReady) ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_readiness_device">>, kind => device,
          source => manual_device, name => <<"Laptop">>, type => <<"vpn-client">>}),
    Service = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_readiness_service">>, kind => vpn_service,
          source => manual_vpn_service, name => <<"OpenVPN">>, service => openvpn,
          remote => <<"vpn.example.com:1194">>, remote_host => <<"vpn.example.com">>,
          remote_port => <<"1194">>, protocol => <<"udp">>, tls_auth => not_configured}),
    CaCertificate = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_readiness_ca">>, kind => certificate,
          source => ca_certificate, material_type => ca_certificate,
          certificate_role => ca_certificate, certificate_status => trusted,
          name => <<"Demo CA">>, subject => <<"CN=Demo CA">>}),
    ClientCertificate = ias_demo_store:add_certificate(
        #{id => <<"wizard_readiness_client">>, source => certificate_issue_demo,
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
    maybe_authorize(AuthorizationReady, Device, ClientCertificate),
    maybe_store_material(StoreMaterial, CaCertificate, ClientCertificate),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0),
        #{current_step => material_readiness,
          device_id => maps:get(id, Device),
          security_profile_id => administrator,
          vpn_service_id => maps:get(id, Service),
          ca_certificate_id => maps:get(id, CaCertificate),
          client_certificate_id => maps:get(id, ClientCertificate),
          relationships_applied => true}),
    Draft.

maybe_authorize(true, Device, ClientCertificate) ->
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                            maps:get(id, Device), <<"high_security">>),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                            maps:get(id, ClientCertificate), <<"high_security">>),
    verify_client_certificate(ClientCertificate);
maybe_authorize(false, _Device, _ClientCertificate) ->
    ok.

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

maybe_store_material(false, _CaCertificate, _ClientCertificate) ->
    ok;
maybe_store_material(true, CaCertificate, ClientCertificate) ->
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    {ok, _} = ias_certificate_material:put(maps:get(id, CaCertificate), ca_certificate,
                                           Pem, operator_load),
    {ok, _} = ias_certificate_material:put(maps:get(id, ClientCertificate), client_certificate,
                                           Pem, operator_load),
    ok.
