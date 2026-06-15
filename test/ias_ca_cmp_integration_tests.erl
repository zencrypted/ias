-module(ias_ca_cmp_integration_tests).
-include_lib("eunit/include/eunit.hrl").

enrollment_result_import_test() ->
    ias_demo_store:clear(),
    EnrollmentId = ias_demo_store:add_enrollment_result(enrollment_result()),

    {ok, Certificate} = ias_cert_enrollment_import:import(EnrollmentId),

    ?assertEqual(<<"CN=vpn-client-20260614-012345">>, maps:get(subject, Certificate)),
    ?assertEqual(<<"CN=CA">>, maps:get(issuer, Certificate)),
    ?assertEqual(<<"Jun 14 01:23:45 2026 GMT">>, maps:get(not_before, Certificate)),
    ?assertEqual(<<"Jun 14 01:23:45 2027 GMT">>, maps:get(not_after, Certificate)),
    ?assertEqual(<<"vpn-client">>, maps:get(requested_cn, Certificate)),
    ?assertEqual(<<"vpn-client-20260614-012345">>, maps:get(enrollment_cn, Certificate)).

enrollment_to_certificate_relationship_test() ->
    ias_demo_store:clear(),
    EnrollmentId = ias_demo_store:add_enrollment_result(enrollment_result()),

    {ok, Certificate} = ias_cert_enrollment_import:import(EnrollmentId),

    ?assert(lists:any(fun(Relationship) ->
        maps:get(relation_type, Relationship) =:= issues andalso
        maps:get(source_kind, Relationship) =:= cmp_enrollment_result andalso
        maps:get(source_id, Relationship) =:= EnrollmentId andalso
        maps:get(target_kind, Relationship) =:= certificate andalso
        maps:get(target_id, Relationship) =:= maps:get(id, Certificate)
    end, ias_demo_store:relationships())).

issued_certificate_origin_test() ->
    ias_demo_store:clear(),
    EnrollmentId = ias_demo_store:add_enrollment_result(enrollment_result()),

    {ok, Certificate} = ias_cert_enrollment_import:import(EnrollmentId),
    Relationships = ias_relationship_link:relationships_for(Certificate),

    ?assert(lists:any(fun(Relationship) ->
        maps:get(relation_type, Relationship) =:= issues andalso
        maps:get(source_id, Relationship) =:= EnrollmentId
    end, Relationships)).

enrollment_certificate_issues_demo_certificate_test() ->
    ias_demo_store:clear(),
    EnrollmentId = ias_demo_store:add_enrollment_result(enrollment_result()),
    {ok, EnrollmentCertificate} = ias_cert_enrollment_import:import(EnrollmentId),
    EnrollmentCertificateId = maps:get(id, EnrollmentCertificate),

    {ok, IssuedCertificate} =
        ias_certificate_issue_demo:issue_from_certificate(EnrollmentCertificateId,
                                                          alice,
                                                          <<"alice-vpn">>,
                                                          ias_demo_data:profiles()),

    ?assertEqual(EnrollmentCertificateId,
                 maps:get(source_certificate_id, IssuedCertificate)),
    ?assert(lists:any(fun(Relationship) ->
        maps:get(relation_type, Relationship) =:= issues andalso
        maps:get(source_kind, Relationship) =:= certificate andalso
        maps:get(source_id, Relationship) =:= EnrollmentCertificateId andalso
        maps:get(target_kind, Relationship) =:= certificate andalso
        maps:get(target_id, Relationship) =:= maps:get(id, IssuedCertificate)
    end, ias_demo_store:relationships())),
    ?assertEqual(2, length([Relationship || Relationship <- ias_demo_store:relationships(),
                                            maps:get(relation_type, Relationship) =:= issues])),
    ?assertEqual([], maps:get(unknown, ias_relationship_graph:categorized_relationships())),
    ?assertEqual([], maps:get(broken, ias_relationship_graph:categorized_relationships())),
    ?assertEqual([], maps:get(enrollment_certificates_without_issued_certificate,
                              ias_graph_analysis:report())).

normal_demo_issuance_does_not_create_lifecycle_link_test() ->
    ias_demo_store:clear(),

    {ok, IssuedCertificate} =
        ias_certificate_issue_demo:issue(alice, <<"alice-vpn">>,
                                         ias_demo_data:profiles()),

    ?assertEqual(undefined, maps:get(source_certificate_id, IssuedCertificate)),
    ?assertEqual([],
                 [Relationship || Relationship <- ias_demo_store:relationships(),
                                  maps:get(relation_type, Relationship) =:= issues,
                                  maps:get(target_id, Relationship) =:=
                                      maps:get(id, IssuedCertificate)]).

metadata_only_storage_test() ->
    ias_demo_store:clear(),
    EnrollmentId = ias_demo_store:add_enrollment_result(enrollment_result(#{
        certificate_pem => <<"-----BEGIN CERTIFICATE-----\nforged\n-----END CERTIFICATE-----">>,
        private_key_body => <<"-----BEGIN PRIVATE KEY-----\nforged\n-----END PRIVATE KEY-----">>,
        csr_body => <<"-----BEGIN CERTIFICATE REQUEST-----\nforged\n-----END CERTIFICATE REQUEST-----">>
    })),

    {ok, Enrollment} = ias_demo_store:get_enrollment_result(EnrollmentId),
    {ok, Certificate} = ias_cert_enrollment_import:import(EnrollmentId),
    Stored = term_to_binary([Enrollment, Certificate]),

    ?assertEqual(false, maps:get(private_key_stored, Certificate)),
    ?assertEqual(false, maps:get(certificate_body_stored, Certificate)),
    ?assertEqual(nomatch, binary:match(Stored, <<"BEGIN CERTIFICATE">>)),
    ?assertEqual(nomatch, binary:match(Stored, <<"BEGIN PRIVATE KEY">>)),
    ?assertEqual(nomatch, binary:match(Stored, <<"BEGIN CERTIFICATE REQUEST">>)).

trust_boundary_import_uses_enrollment_id_test() ->
    ias_demo_store:clear(),
    EnrollmentId = ias_demo_store:add_enrollment_result(enrollment_result(#{
        subject => <<"CN=server-side">>,
        issuer => <<"CN=Server CA">>
    })),

    {ok, Certificate} = ias_cert_enrollment_import:import(EnrollmentId),

    ?assertEqual(<<"CN=server-side">>, maps:get(subject, Certificate)),
    ?assertEqual(<<"CN=Server CA">>, maps:get(issuer, Certificate)),
    ?assertEqual(not_found, ias_cert_enrollment_import:import(<<"browser-forged-id">>)).

ovpn_demo_import_still_functions_test() ->
    ias_demo_store:clear(),
    {ok, OVPN} = file:read_file("test/fixtures/example.ovpn"),
    Preview = ias_ovpn_preview:analyze(OVPN),
    ImportId = ias_demo_store:add_import(ias_ovpn_import:import_map(Preview)),

    [Device] = ias_demo_store:devices(),
    [Certificate] = ias_demo_store:certificates(),
    [Service] = ias_demo_store:services(),

    ?assertEqual(ias_html:join([ImportId, <<"_device">>]), maps:get(id, Device)),
    ?assertEqual(ias_html:join([ImportId, <<"_certificate">>]), maps:get(id, Certificate)),
    ?assertEqual(ias_html:join([ImportId, <<"_vpn_service">>]), maps:get(id, Service)),
    ?assertEqual(ovpn_demo_import, maps:get(source, Certificate)),
    ?assertEqual(false, maps:get(private_key_stored, Certificate)).

enrollment_result() ->
    enrollment_result(#{}).

enrollment_result(Overrides) ->
    maps:merge(#{
        subject => <<"CN=vpn-client-20260614-012345">>,
        issuer => <<"CN=CA">>,
        not_before => <<"Jun 14 01:23:45 2026 GMT">>,
        not_after => <<"Jun 14 01:23:45 2027 GMT">>,
        requested_cn => <<"vpn-client">>,
        enrollment_cn => <<"vpn-client-20260614-012345">>,
        profile => <<"secp384r1">>,
        cmp_server => <<"127.0.0.1:8829">>
    }, Overrides).
