-module(ias_device_key_ref_tests).
-include_lib("eunit/include/eunit.hrl").

update_existing_device_key_reference_test() ->
    ias_demo_store:clear(),
    Device = device_without_ref(<<"key_ref_update_device">>),

    {ok, Updated} = ias_device_key_ref:update(maps:get(id, Device), #{
        private_key_provider => <<"device_file">>,
        private_key_ref => <<"keys/client.key">>
    }),

    ?assertEqual(<<"device_file">>, maps:get(private_key_provider, Updated)),
    ?assertEqual(<<"keys/client.key">>, maps:get(private_key_ref, Updated)),
    ?assertMatch({ok, #{private_key_ref := <<"keys/client.key">>}},
                 ias_device_key_ref:status(maps:get(id, Device))).

invalid_provider_is_rejected_test() ->
    ?assertMatch({error, _},
                 ias_device_key_ref:validate(<<"vault">>, <<"client.key">>)).

user_input_stays_binary_test() ->
    ias_demo_store:clear(),
    Device = device_without_ref(<<"key_ref_binary_device">>),
    {ok, Updated} = ias_device_key_ref:update(maps:get(id, Device), #{
        private_key_provider => " device_file ",
        private_key_ref => " keys/client.key "
    }),
    ?assert(is_binary(maps:get(private_key_provider, Updated))),
    ?assert(is_binary(maps:get(private_key_ref, Updated))).

demo_state_roundtrip_preserves_device_key_reference_test() ->
    ias_demo_state:clear(),
    Device = ias_demo_store:add_device(#{
        id => <<"key_ref_roundtrip_device">>,
        source => manual_device,
        private_key_provider => <<"device_file">>,
        private_key_ref => <<"keys/client.key">>
    }),
    Snapshot = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    _ = ias_demo_state:import(Snapshot),
    {ok, Restored} = ias_demo_store:get(maps:get(id, Device)),

    ?assertEqual(<<"device_file">>, maps:get(private_key_provider, Restored)),
    ?assertEqual(<<"keys/client.key">>, maps:get(private_key_ref, Restored)).

private_key_body_is_not_exported_test() ->
    ias_demo_state:clear(),
    _Device = ias_demo_store_fixture:put_runtime_object(#{
        id => <<"key_ref_secret_device">>,
        kind => device,
        source => manual_device,
        private_key_provider => <<"device_file">>,
        private_key_ref => <<"client.key">>,
        private_key_body => <<"PRIVATE-KEY-BODY">>,
        key_pem => <<"KEY-PEM">>
    }),

    Snapshot = ias_demo_state:export(),

    ?assertEqual(nomatch, binary:match(Snapshot, <<"PRIVATE-KEY-BODY">>)),
    ?assertEqual(nomatch, binary:match(Snapshot, <<"KEY-PEM">>)),
    ?assertMatch({_, _}, binary:match(Snapshot, <<"client.key">>)).

readiness_blocks_without_key_reference_test() ->
    Draft = setup_readiness_device(false),
    Readiness = ias_provisioning_wizard_store:material_readiness(Draft),
    Components = maps:get(material_components, maps:get(plan, Readiness)),

    ?assertEqual(false, maps:get(ready, Readiness)),
    ?assertEqual(missing_private_key_ref, maps:get(private_key, Components)),
    ?assertMatch({_, _}, binary:match(maps:get(assembly_reason, maps:get(plan, Readiness)),
                                      <<"Device-owned private key reference is missing">>)).

readiness_allows_valid_key_reference_test() ->
    Draft = setup_readiness_device(true),
    Readiness = ias_provisioning_wizard_store:material_readiness(Draft),
    Components = maps:get(material_components, maps:get(plan, Readiness)),

    ?assertEqual(available_on_device, maps:get(private_key, Components)),
    ?assertEqual(<<"client.key">>, maps:get(private_key_ref, maps:get(plan, Readiness))),
    ?assertEqual(true, maps:get(ready, Readiness)).

transaction_contains_reference_without_key_body_test() ->
    Draft = setup_readiness_device(true),
    {ok, _Draft, Transaction} =
        ias_provisioning_wizard_store:create_provisioning(maps:get(id, Draft)),

    ?assertEqual(<<"device_file">>, maps:get(private_key_provider, Transaction)),
    ?assertEqual(<<"client.key">>, maps:get(private_key_ref, Transaction)),
    ?assertEqual(false, maps:is_key(private_key_body, Transaction)),
    ?assertEqual(false, maps:is_key(private_key_pem, Transaction)),
    ?assertEqual(false, maps:is_key(key_pem, Transaction)).

wizard_contextual_action_disappears_after_fix_test() ->
    Draft0 = setup_readiness_device(false),
    Html0 = render(ias_provisioning_wizard:content_for({draft, Draft0})),
    ?assertMatch({_, _}, binary:match(Html0, <<"Configure Device Key Reference">>)),

    {ok, Device} = ias_demo_store:get(maps:get(device_id, Draft0)),
    {ok, _Updated} = ias_device_key_ref:update(maps:get(id, Device), #{
        private_key_provider => <<"device_file">>,
        private_key_ref => <<"client.key">>
    }),
    Html1 = render(ias_provisioning_wizard:content_for({draft, Draft0})),
    ?assertEqual(nomatch, binary:match(Html1, <<"Configure Device Key Reference">>)).

device_without_ref(Id) ->
    ias_demo_store:put_runtime_object(#{
        id => Id,
        kind => device,
        source => manual_device,
        name => <<"Device">>,
        type => <<"vpn-client">>,
        tunnel_device => <<"tun">>,
        transport => <<"udp">>
    }).

setup_readiness_device(WithKeyRef) ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Device0 = #{
        id => <<"key_ref_readiness_device">>,
        kind => device,
        source => manual_device,
        name => <<"Laptop">>,
        type => <<"vpn-client">>,
        tunnel_device => <<"tun">>,
        transport => <<"udp">>
    },
    Device = ias_demo_store:put_runtime_object(case WithKeyRef of
        true -> Device0#{private_key_provider => <<"device_file">>,
                         private_key_ref => <<"client.key">>};
        false -> Device0
    end),
    Service = ias_demo_store:put_runtime_object(#{
        id => <<"key_ref_readiness_service">>,
        kind => vpn_service,
        source => manual_vpn_service,
        name => <<"OpenVPN">>,
        service => openvpn,
        remote => <<"vpn.example.com:1194">>,
        remote_host => <<"vpn.example.com">>,
        remote_port => <<"1194">>,
        protocol => <<"udp">>,
        tls_auth => not_configured
    }),
    CaCertificate = ias_demo_store:put_runtime_object(#{
        id => <<"key_ref_readiness_ca">>,
        kind => certificate,
        source => ca_certificate,
        material_type => ca_certificate,
        certificate_role => ca_certificate,
        certificate_status => trusted,
        name => <<"Demo CA">>,
        subject => <<"CN=Demo CA">>
    }),
    ClientCertificate = ias_demo_store:add_certificate(#{
        id => <<"key_ref_readiness_client">>,
        source => certificate_issue_demo,
        certificate_role => client_certificate,
        certificate_status => trusted,
        profile_id => administrator,
        profile => administrator,
        subject_cn => <<"vpn-client">>,
        private_key_stored => false,
        certificate_body_stored => false
    }),
    {ok, _} = ias_relationship_link:create(uses_security_profile, maps:get(id, Device), administrator),
    {ok, _} = ias_relationship_link:create(uses_service, maps:get(id, Device), maps:get(id, Service)),
    {ok, _} = ias_relationship_link:create(uses_certificate, maps:get(id, Device), maps:get(id, ClientCertificate)),
    {ok, _} = ias_relationship_link:create(uses_ca_certificate, maps:get(id, Service), maps:get(id, CaCertificate)),
    {ok, _} = ias_relationship_link:create(uses_security_policy, maps:get(id, Device), <<"high_security">>),
    {ok, _} = ias_relationship_link:create(uses_security_policy, maps:get(id, ClientCertificate), <<"high_security">>),
    verify_client_certificate(ClientCertificate),
    store_material(CaCertificate, ClientCertificate),
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

store_material(CaCertificate, ClientCertificate) ->
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    {ok, _} = ias_certificate_material:put(maps:get(id, CaCertificate), ca_certificate,
                                           Pem, operator_load),
    {ok, _} = ias_certificate_material:put(maps:get(id, ClientCertificate), client_certificate,
                                           Pem, operator_load),
    ok.

render(Doc) ->
    iolist_to_binary(nitro:render(Doc)).
