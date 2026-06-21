-module(ias_device_bound_ovpn_tests).
-include_lib("eunit/include/eunit.hrl").

successful_device_bound_assembly_test() ->
    Transaction = setup_ready_transaction(),
    {ok, Artifact} = ias_device_bound_ovpn:assemble(maps:get(id, Transaction)),
    Body = maps:get(body, Artifact),

    ?assertMatch({_, _}, binary:match(Body, <<"dev tun">>)),
    ?assertMatch({_, _}, binary:match(Body, <<"proto udp">>)),
    ?assertMatch({_, _}, binary:match(Body, <<"remote vpn.example.com 1194">>)),
    ?assertMatch({_, _}, binary:match(Body, <<"BEGIN CERTIFICATE">>)),
    ?assertMatch({_, _}, binary:match(Body, <<"END CERTIFICATE">>)),
    ?assertMatch({_, _}, binary:match(Body, <<"key client.key">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"<key>">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"BEGIN PRIVATE KEY">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"...">>)).

missing_key_reference_blocks_assembly_test() ->
    Transaction = setup_ready_transaction(#{private_key_ref => undefined}),

    ?assertEqual({error, <<"Device-owned private key reference is missing.">>},
                 ias_device_bound_ovpn:assemble(maps:get(id, Transaction))).

missing_pem_blocks_assembly_test() ->
    Transaction = setup_ready_transaction(),
    ias_certificate_material:clear(),

    ?assertEqual({error, <<"CA certificate PEM is unavailable; client certificate PEM is unavailable">>},
                 ias_device_bound_ovpn:assemble(maps:get(id, Transaction))).

authorization_deny_blocks_assembly_test() ->
    ias_demo_state:clear(),
    Transaction = ias_demo_store:put_runtime_object(
        #{id => <<"ovpn_denied_transaction">>,
          provisioning_id => <<"ovpn_denied_transaction">>,
          kind => ovpn_provisioning,
          mode => device_bound,
          authorization => deny,
          authorization_reason => <<"authorization denied">>}),

    ?assertEqual({error, <<"authorization denied">>},
                 ias_device_bound_ovpn:assemble(maps:get(id, Transaction))).

unsupported_provider_blocks_assembly_test() ->
    Transaction = setup_ready_transaction(#{private_key_provider => <<"vault">>}),

    ?assertEqual({error, <<"Device-owned private key provider is unsupported.">>},
                 ias_device_bound_ovpn:assemble(maps:get(id, Transaction))).

safe_filename_test() ->
    ?assertEqual(<<"device___name.ovpn">>,
                 ias_device_bound_ovpn:safe_filename(<<"device / name">>)).

download_response_test() ->
    Transaction = setup_ready_transaction(),
    {ok, Response} = ias_device_bound_ovpn:download_response(maps:get(id, Transaction)),

    ?assertEqual(<<"application/x-openvpn-profile">>,
                 maps:get(content_type, Response)),
    ?assertMatch({_, _}, binary:match(maps:get(content_disposition, Response),
                                      maps:get(filename, Response))),
    ?assertMatch({_, _}, binary:match(maps:get(body, Response), <<"key client.key">>)).

transaction_detail_shows_download_action_test() ->
    Transaction = setup_ready_transaction(),
    Html = render(ias_demo:ovpn_material_preview(Transaction)),

    ?assertMatch({_, _}, binary:match(Html, <<"Download Device-bound OVPN">>)).

wizard_completion_shows_download_action_test() ->
    {Draft, Transaction} = setup_completed_wizard(),
    Html = render(ias_provisioning_wizard:content_for({draft, Draft})),

    ?assertMatch({_, _}, binary:match(Html, maps:get(id, Transaction))),
    ?assertMatch({_, _}, binary:match(Html, <<"Download Device-bound OVPN">>)).

ovpn_body_is_not_exported_in_demo_state_test() ->
    Transaction = setup_ready_transaction(),
    {ok, Artifact} = ias_device_bound_ovpn:assemble(maps:get(id, Transaction)),
    Snapshot = ias_demo_state:export(),

    ?assertEqual(nomatch, binary:match(Snapshot, maps:get(body, Artifact))),
    ?assertEqual(nomatch, binary:match(Snapshot, <<"client\n">>)).

material_clear_blocks_download_again_test() ->
    Transaction = setup_ready_transaction(),
    {ok, _Artifact} = ias_device_bound_ovpn:assemble(maps:get(id, Transaction)),
    ias_certificate_material:clear(),

    ?assertEqual({error, <<"CA certificate PEM is unavailable; client certificate PEM is unavailable">>},
                 ias_device_bound_ovpn:assemble(maps:get(id, Transaction))).

ready_transaction_status_is_delivery_ready_test() ->
    Transaction = setup_ready_transaction(),

    ?assertEqual(ready_for_delivery, maps:get(status, Transaction)),
    ?assertEqual(public_material_available, maps:get(material_status, Transaction)),
    ?assertEqual(public_bundle_ready, maps:get(assembly_status, Transaction)),
    ?assertEqual(public_bundle_ready, maps:get(artifact_status, Transaction)),
    ?assertEqual(ready_for_device_import, maps:get(delivery_status, Transaction)).

setup_completed_wizard() ->
    Draft = setup_ready_wizard(),
    {ok, Completed, Transaction} =
        ias_provisioning_wizard_store:create_provisioning(maps:get(id, Draft)),
    {Completed, Transaction}.

setup_ready_transaction() ->
    setup_ready_transaction(#{}).

setup_ready_transaction(DeviceOverrides) ->
    Draft = setup_ready_wizard(DeviceOverrides),
    case maps:size(DeviceOverrides) of
        0 ->
            {ok, _Completed, Transaction} =
                ias_provisioning_wizard_store:create_provisioning(maps:get(id, Draft)),
            Transaction;
        _ ->
            Plan = ias_ovpn_provisioning:preview(
                device_bound, device, maps:get(device_id, Draft)),
            Transaction0 = Plan#{id => <<"device_bound_ovpn_negative_transaction">>,
                                  provisioning_id => <<"device_bound_ovpn_negative_transaction">>,
                                  kind => ovpn_provisioning,
                                  source => ovpn_provisioning_demo,
                                  created_at => <<"2026-06-21T00:00:00Z">>,
                                  expires_at => <<"2026-06-21T00:15:00Z">>},
            ias_demo_store:put_runtime_object(Transaction0)
    end.

setup_ready_wizard() ->
    setup_ready_wizard(#{}).

setup_ready_wizard(DeviceOverrides) ->
    ias_demo_state:clear(),
    DeviceBase = #{id => <<"device_bound_ovpn_device">>, kind => device,
                   source => manual_device, name => <<"Laptop">>,
                   type => <<"vpn-client">>, tunnel_device => <<"tun">>,
                   private_key_provider => <<"device_file">>,
                   private_key_ref => <<"client.key">>},
    Device = ias_demo_store:put_runtime_object(maps:merge(DeviceBase, DeviceOverrides)),
    Service = ias_demo_store:put_runtime_object(
        #{id => <<"device_bound_ovpn_service">>, kind => vpn_service,
          source => manual_vpn_service, name => <<"OpenVPN">>, service => openvpn,
          remote => <<"vpn.example.com:1194">>, remote_host => <<"vpn.example.com">>,
          remote_port => <<"1194">>, protocol => <<"udp">>, tls_auth => not_configured}),
    CaCertificate = ias_demo_store:put_runtime_object(
        #{id => <<"device_bound_ovpn_ca">>, kind => certificate,
          source => ca_certificate, material_type => ca_certificate,
          certificate_role => ca_certificate, certificate_status => trusted,
          name => <<"Demo CA">>, subject => <<"CN=Demo CA">>}),
    ClientCertificate = ias_demo_store:add_certificate(
        #{id => <<"device_bound_ovpn_client">>, source => certificate_issue_demo,
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
    {ok, _} = ias_certificate_material:put(maps:get(id, CaCertificate), ca_certificate,
                                           ca_pem(), operator_load),
    {ok, _} = ias_certificate_material:put(maps:get(id, ClientCertificate), client_certificate,
                                           client_pem(), operator_load),
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
    case maps:size(DeviceOverrides) of
        0 -> ?assertEqual(true, ias_provisioning_wizard_store:material_readiness_ready(Draft));
        _ -> ok
    end,
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

ca_pem() ->
    certificate_pem(<<"real-ca-public-pem">>).

client_pem() ->
    certificate_pem(<<"real-client-public-pem">>).

certificate_pem(Der) ->
    public_key:pem_encode([{'Certificate', Der, not_encrypted}]).

render(Doc) ->
    iolist_to_binary(nitro:render(Doc)).
