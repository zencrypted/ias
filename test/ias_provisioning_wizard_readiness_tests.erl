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
