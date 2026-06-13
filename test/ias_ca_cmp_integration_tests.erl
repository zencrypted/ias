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
