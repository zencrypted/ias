-module(ias_relationship_constraints_tests).
-include_lib("eunit/include/eunit.hrl").

duplicate_client_certificate_link_test() ->
    ias_demo_store:clear(),
    Device = device(<<"constraints_cert_device">>),
    Cert1 = client_certificate(<<"constraints_client_cert_1">>),
    Cert2 = client_certificate(<<"constraints_client_cert_2">>),

    {ok, First} = ias_relationship_link:create(uses_certificate, id(Device), id(Cert1)),
    {error, Reason} = ias_relationship_link:create(uses_certificate, id(Device), id(Cert2)),

    ?assertEqual(already_has_operational_relationship, maps:get(reason, Reason)),
    ?assertEqual(id(Cert1), maps:get(existing_target_id, Reason)),
    ?assertEqual([id(First)], relationship_ids(uses_certificate)).

duplicate_vpn_service_link_test() ->
    ias_demo_store:clear(),
    Device = device(<<"constraints_service_device">>),
    Service1 = service(<<"constraints_service_1">>),
    Service2 = service(<<"constraints_service_2">>),

    {ok, First} = ias_relationship_link:create(uses_service, id(Device), id(Service1)),
    {error, Reason} = ias_relationship_link:create(uses_service, id(Device), id(Service2)),

    ?assertEqual(already_has_operational_relationship, maps:get(reason, Reason)),
    ?assertEqual(id(Service1), maps:get(existing_target_id, Reason)),
    ?assertEqual([id(First)], relationship_ids(uses_service)).

duplicate_ca_certificate_link_test() ->
    ias_demo_store:clear(),
    Service = service(<<"constraints_ca_service">>),
    Ca1 = ca_certificate(<<"constraints_ca_cert_1">>),
    Ca2 = ca_certificate(<<"constraints_ca_cert_2">>),

    {ok, First} = ias_relationship_link:create(uses_ca_certificate, id(Service), id(Ca1)),
    {error, Reason} = ias_relationship_link:create(uses_ca_certificate, id(Service), id(Ca2)),

    ?assertEqual(already_has_operational_relationship, maps:get(reason, Reason)),
    ?assertEqual(id(Ca1), maps:get(existing_target_id, Reason)),
    ?assertEqual([id(First)], relationship_ids(uses_ca_certificate)).

exact_duplicate_relationship_remains_idempotent_test() ->
    ias_demo_store:clear(),
    Device = device(<<"constraints_exact_device">>),
    Certificate = client_certificate(<<"constraints_exact_certificate">>),

    {ok, First} = ias_relationship_link:create(uses_certificate, id(Device), id(Certificate)),
    {ok, Second} = ias_relationship_link:create(uses_certificate, id(Device), id(Certificate)),

    ?assertEqual(id(First), id(Second)),
    ?assertEqual([id(First)], relationship_ids(uses_certificate)).

explicit_role_mismatch_test() ->
    ias_demo_store:clear(),
    Device = device(<<"constraints_role_device">>),
    Service = service(<<"constraints_role_service">>),
    Ca = ca_certificate(<<"constraints_role_ca">>),
    Client = client_certificate(<<"constraints_role_client">>),

    {error, ClientReason} = ias_relationship_link:create(uses_certificate, id(Device), id(Ca)),
    {error, CaReason} = ias_relationship_link:create(uses_ca_certificate, id(Service), id(Client)),

    ?assertEqual(incompatible_certificate_role, maps:get(reason, ClientReason)),
    ?assertEqual(client_certificate, maps:get(expected_role, ClientReason)),
    ?assertEqual(ca_certificate, maps:get(actual_role, ClientReason)),
    ?assertEqual(incompatible_certificate_role, maps:get(reason, CaReason)),
    ?assertEqual(ca_certificate, maps:get(expected_role, CaReason)),
    ?assertEqual(client_certificate, maps:get(actual_role, CaReason)).

unknown_role_allowed_with_warning_test() ->
    ias_demo_store:clear(),
    Device = device(<<"constraints_unknown_device">>),
    Certificate = unknown_certificate(<<"constraints_unknown_certificate">>),

    {ok, Relationship} = ias_relationship_link:create(uses_certificate,
                                                      id(Device), id(Certificate)),

    ?assertMatch([#{warning := unclassified_certificate_role}],
                 maps:get(warnings, Relationship)).

ambiguous_imported_legacy_graph_test() ->
    ias_demo_store:clear(),
    Device = device(<<"constraints_legacy_device">>),
    Cert1 = client_certificate(<<"constraints_legacy_cert_1">>),
    Cert2 = client_certificate(<<"constraints_legacy_cert_2">>),
    legacy_relationship(uses_certificate, device, id(Device), certificate, id(Cert1)),
    legacy_relationship(uses_certificate, device, id(Device), certificate, id(Cert2)),

    Report = ias_graph_analysis:report(),
    [Warning] = maps:get(devices_with_multiple_certificates, Report),
    Readiness = device_readiness(id(Device), Report),

    ?assertEqual(id(Device), maps:get(device_id, Warning)),
    ?assertEqual([id(Cert1), id(Cert2)], lists:sort(maps:get(certificate_ids, Warning))),
    ?assert(lists:member(<<"Ambiguous Current Certificate">>,
                         maps:get(missing, Readiness))).

provisioning_blocked_on_ambiguity_test() ->
    ias_demo_store:clear(),
    #{device := Device, service := Service1} = ready_device(<<"constraints_blocked">>),
    Service2 = service(<<"constraints_blocked_service_2">>),
    legacy_relationship(uses_service, device, id(Device), vpn_service, id(Service2)),

    Preview = ias_ovpn_provisioning:preview(device_bound, device, id(Device)),

    ?assertEqual(deny, maps:get(authorization, Preview)),
    ?assertEqual(blocked, maps:get(status, Preview)),
    ?assertMatch({_, _}, binary:match(maps:get(authorization_reason, Preview),
                                      <<"ambiguous device VPN services">>)),
    ?assertMatch({_, _}, binary:match(maps:get(authorization_reason, Preview),
                                      id(Service1))),
    ?assertMatch({_, _}, binary:match(maps:get(authorization_reason, Preview),
                                      id(Service2))).

normal_unambiguous_flow_is_unchanged_test() ->
    ias_demo_store:clear(),
    #{device := Device, service := Service, certificate := Certificate, ca := Ca} =
        ready_device(<<"constraints_ready">>),

    Preview = ias_ovpn_provisioning:preview(device_bound, device, id(Device)),

    ?assertEqual(allow, maps:get(authorization, Preview)),
    ?assertEqual(awaiting_material, maps:get(status, Preview)),
    ?assertEqual(id(Device), maps:get(device_id, Preview)),
    ?assertEqual(id(Service), maps:get(vpn_service_id, Preview)),
    ?assertEqual(id(Certificate), maps:get(certificate_id, Preview)),
    ?assertEqual(id(Ca), maps:get(ca_certificate_id, Preview)).

device(Id) ->
    ias_demo_store:add_device(#{id => Id,
                                source => manual_device,
                                type => <<"vpn-client">>,
                                endpoint => <<"vpn.example.com:1194">>}).

service(Id) ->
    ias_demo_store:add_service(#{id => Id,
                                 source => manual_vpn_service,
                                 service => openvpn,
                                 remote => <<"vpn.example.com:1194">>,
                                 protocol => udp}).

client_certificate(Id) ->
    ias_demo_store:add_certificate(#{id => Id,
                                     source => certificate_issue_demo,
                                     profile_id => default_user,
                                     profile => default_user,
                                     private_key_stored => false,
                                     certificate_body_stored => false}).

ca_certificate(Id) ->
    ias_demo_store:add_certificate(#{id => Id,
                                     source => ca_certificate,
                                     subject => <<"CN=CA">>}).

unknown_certificate(Id) ->
    ias_demo_store:put_runtime_object(#{id => Id,
                                        kind => certificate,
                                        private_key_stored => false,
                                        certificate_body_stored => false}).

ready_device(Prefix) ->
    Device = device(<<Prefix/binary, "_device">>),
    Certificate = client_certificate(<<Prefix/binary, "_certificate">>),
    Service = service(<<Prefix/binary, "_service">>),
    Ca = ca_certificate(<<Prefix/binary, "_ca">>),
    {ok, _} = ias_relationship_link:create(uses_certificate, id(Device), id(Certificate)),
    {ok, _} = ias_relationship_link:create(uses_service, id(Device), id(Service)),
    {ok, _} = ias_relationship_link:create(uses_security_policy, id(Device), <<"standard">>),
    {ok, _} = ias_relationship_link:create(uses_security_policy, id(Certificate), <<"standard">>),
    {ok, _} = ias_relationship_link:create(uses_ca_certificate, id(Service), id(Ca)),
    {ok, _Verification} = ias_certificate_verification:verify(
        Certificate#{certificate_id => id(Certificate),
                     subject_cn => id(Certificate),
                     issuer_cn => <<"Zencrypted Dev CA">>,
                     profile => ias_demo_profile(),
                     profile_id => default_user,
                     claims => ias_policy:certificate_claims(ias_demo_profile()),
                     trusted => true,
                     key_match => true}),
    #{device => Device,
      certificate => Certificate,
      service => Service,
      ca => Ca}.

ias_demo_profile() ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile, undefined) =:= default_user],
    Profile.

legacy_relationship(RelationType, SourceKind, SourceId, TargetKind, TargetId) ->
    ias_demo_store:add_relationship(#{relation_type => RelationType,
                                      source_kind => SourceKind,
                                      source_id => SourceId,
                                      target_kind => TargetKind,
                                      target_id => TargetId}).

device_readiness(DeviceId, Report) ->
    [Readiness] = [Readiness
                   || Readiness <- maps:get(all, maps:get(device_operational_readiness, Report)),
                      maps:get(device_id, Readiness, undefined) =:= DeviceId],
    Readiness.

relationship_ids(RelationType) ->
    [maps:get(id, Relationship)
     || Relationship <- ias_demo_store:relationships(),
        maps:get(relation_type, Relationship, undefined) =:= RelationType].

id(Object) ->
    maps:get(id, Object).
