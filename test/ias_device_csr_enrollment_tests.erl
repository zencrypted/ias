-module(ias_device_csr_enrollment_tests).
-include_lib("eunit/include/eunit.hrl").

valid_external_csr_submission_test() ->
    ?assertMatch({ok, #{subject := <<"CN=device-csr-client">>,
                        csr_fingerprint := _,
                        public_key_fingerprint := _}},
                 ias_csr_validation:validate(client_csr_pem())).

invalid_csr_and_private_key_rejection_test() ->
    ?assertEqual({error, malformed_csr},
                 ias_csr_validation:validate(<<"not a csr">>)),
    ?assertEqual({error, private_key_supplied},
                 ias_csr_validation:validate(
                     <<"-----BEGIN PRIVATE KEY-----\nZm9yZ2Vk\n-----END PRIVATE KEY-----\n">>)).

csr_signature_verification_test() ->
    ?assertEqual({error, csr_signature_invalid},
                 ias_csr_validation:validate(tampered_csr_pem())).

cmp_request_uses_supplied_csr_test() ->
    Args = ias_cmp_enrollment:external_csr_cmp_args(
        <<"127.0.0.1:8829">>, <<"/tmp/device.csr">>, <<"/tmp/device.pem">>),
    ?assertMatch({_, _}, list_match(<<"-csr">>, Args)),
    ?assertMatch({_, _}, list_match(<<"/tmp/device.csr">>, Args)),
    ?assertEqual(nomatch, list_match(<<"-newkey">>, Args)),
    ?assertEqual(nomatch, list_match(<<"-keyout">>, Args)).

certificate_key_matches_csr_test() ->
    with_configured_ca(fun() ->
        ias_demo_state:clear(),
        {ok, Csr} = ias_csr_validation:validate(client_csr_pem()),
        {ok, Certificate} = ias_device_csr_enrollment:import_issued_certificate(
            <<"device_csr_device">>, Csr, cmp_result(client_cert_pem())),
        ?assertEqual(maps:get(public_key_fingerprint, Csr),
                     maps:get(public_key_fingerprint, Certificate)),
        ?assertEqual(maps:get(csr_fingerprint, Csr),
                     maps:get(csr_fingerprint, Certificate))
    end).

certificate_csr_mismatch_is_rejected_test() ->
    with_configured_ca(fun() ->
        ias_demo_state:clear(),
        {ok, Csr} = ias_csr_validation:validate(client_csr_pem()),
        ?assertEqual({error, certificate_csr_public_key_mismatch},
                     ias_device_csr_enrollment:import_issued_certificate(
                         <<"device_csr_device">>, Csr, cmp_result(other_client_cert_pem()))),
        ?assertEqual([], ias_demo_store:certificates())
    end).

ca_chain_validation_test() ->
    with_other_configured_ca(fun() ->
        ias_demo_state:clear(),
        {ok, Csr} = ias_csr_validation:validate(client_csr_pem()),
        {error, {invalid_certificate_chain, _Reason}} =
            ias_device_csr_enrollment:import_issued_certificate(
                <<"device_csr_device">>, Csr, cmp_result(client_cert_pem()))
    end).

device_enrollment_certificate_lineage_test() ->
    with_configured_ca(fun() ->
        ias_demo_state:clear(),
        {ok, Csr} = ias_csr_validation:validate(client_csr_pem()),
        {ok, Certificate} = ias_device_csr_enrollment:import_issued_certificate(
            <<"lineage_device">>, Csr, cmp_result(client_cert_pem())),
        ?assertEqual(<<"lineage_device">>, maps:get(device_id, Certificate)),
        ?assertEqual(maps:get(csr_fingerprint, Csr), maps:get(csr_fingerprint, Certificate)),
        ?assertEqual(cmp, maps:get(issued_via, Certificate)),
        ?assertMatch(<<"cmp_enrollment_", _/binary>>, maps:get(enrollment_id, Certificate))
    end).

wizard_auto_selection_and_return_test() ->
    with_configured_ca(fun() ->
        ias_demo_state:clear(),
        Draft = client_ready_draft(),
        {ok, Advanced, Certificate} = ias_device_csr_enrollment:complete_for_wizard(
            maps:get(id, Draft), client_csr_pem(), cmp_result(client_cert_pem())),
        ?assertEqual(maps:get(id, Certificate), maps:get(client_certificate_id, Advanced)),
        ?assertEqual(material_readiness, maps:get(current_step, Advanced)),
        ?assertEqual(true, maps:get(relationships_applied, Advanced))
    end).

csr_and_private_key_bodies_absent_from_demo_state_test() ->
    with_configured_ca(fun() ->
        ias_demo_state:clear(),
        {ok, Csr} = ias_csr_validation:validate(client_csr_pem()),
        {ok, _Certificate} = ias_device_csr_enrollment:import_issued_certificate(
            <<"snapshot_device">>, Csr, cmp_result(client_cert_pem())),
        Snapshot = ias_demo_state:export(),
        ?assertEqual(nomatch, binary:match(Snapshot, <<"BEGIN CERTIFICATE REQUEST">>)),
        ?assertEqual(nomatch, binary:match(Snapshot, <<"BEGIN PRIVATE KEY">>)),
        ?assertMatch({_, _}, binary:match(Snapshot, maps:get(csr_fingerprint, Csr)))
    end).

safe_device_csr_command_generation_test() ->
    Device = csr_command_device(<<"Laptop One">>, <<"client.key">>),
    {ok, Plan} = ias_device_csr_command:generate(Device),
    Command = maps:get(command, Plan),
    ?assertMatch({_, _}, binary:match(Command, <<"openssl req -new">>)),
    ?assertMatch({_, _}, binary:match(Command, <<"-key 'client.key'">>)),
    ?assertMatch({_, _}, binary:match(Command, <<"-out 'laptop-one-">>)),
    ?assertMatch({_, _}, binary:match(Command, <<"-subj '/CN=laptop-one-">>)),
    ?assertMatch(<<"laptop-one-", _/binary>>, maps:get(common_name, Plan)).

unique_device_csr_cn_and_filename_generation_test() ->
    Device = csr_command_device(<<"Laptop Two">>, <<"keys/client.key">>),
    {ok, Plan1} = ias_device_csr_command:generate(Device),
    {ok, Plan2} = ias_device_csr_command:generate(Device),
    ?assertNotEqual(maps:get(common_name, Plan1), maps:get(common_name, Plan2)),
    ?assertNotEqual(maps:get(csr_filename, Plan1), maps:get(csr_filename, Plan2)).

device_csr_command_sanitizes_shell_metadata_test() ->
    Device = csr_command_device(<<"bad; rm -rf /\nname">>, <<"client.key">>),
    {ok, Plan} = ias_device_csr_command:generate(Device),
    Command = maps:get(command, Plan),
    ?assertEqual(nomatch, binary:match(Command, <<"rm -rf">>)),
    ?assertEqual(nomatch, binary:match(Command, <<";">>)),
    ?assertMatch(<<"bad-rm-rf-name-", _/binary>>, maps:get(common_name, Plan)).

downloadable_csr_script_is_device_only_test() ->
    Device = csr_command_device(<<"Laptop Script">>, <<"keys/client.key">>),
    {ok, Plan} = ias_device_csr_command:generate(Device),
    Script = ias_device_csr_command:script(Plan),
    ?assertMatch({_, _}, binary:match(Script, <<"set -eu">>)),
    ?assertMatch({_, _}, binary:match(Script, <<"[ ! -f \"$KEY_REF\" ]">>)),
    ?assertMatch({_, _}, binary:match(Script, <<"[ -e \"$CSR_OUT\" ]">>)),
    ?assertMatch({_, _}, binary:match(Script, <<"Refusing to overwrite existing CSR">>)),
    ?assertEqual(nomatch, binary:match(Script, <<"BEGIN PRIVATE KEY">>)),
    ?assertEqual(nomatch, binary:match(Script, <<"PRIVATE KEY-----">>)).

duplicate_csr_is_rejected_before_cmp_invocation_test() ->
    with_configured_ca(fun() ->
        ias_demo_state:clear(),
        ias_csr_enrollment_state:clear(),
        Draft = client_ready_draft(),
        {ok, Csr} = ias_csr_validation:validate(client_csr_pem()),
        {ok, _} = ias_csr_enrollment_state:mark_submitted(
            maps:get(csr_fingerprint, Csr), #{device_id => maps:get(device_id, Draft)}),
        CmpFun = fun(_Request) -> erlang:error(cmp_should_not_be_called) end,
        ?assertMatch({error, {duplicate_csr, _}},
                     ias_device_csr_enrollment:enroll_for_wizard_with(
                         maps:get(id, Draft), client_csr_pem(), CmpFun))
    end).

separate_csr_fingerprints_are_accepted_test() ->
    ias_csr_enrollment_state:clear(),
    {ok, _} = ias_csr_enrollment_state:mark_submitted(<<"fp-one">>, #{}),
    ?assertEqual(ok, ias_csr_enrollment_state:submitted(<<"fp-two">>)).

failed_transient_enrollment_can_be_retried_test() ->
    ias_csr_enrollment_state:clear(),
    {ok, _} = ias_csr_enrollment_state:mark_failed(
        <<"retryable-fp">>, cmp_connection_failed, true),
    ?assertEqual(ok, ias_csr_enrollment_state:submitted(<<"retryable-fp">>)),
    {ok, _} = ias_csr_enrollment_state:mark_failed(
        <<"used-fp">>, cmp_unexpected_certificate_response, false),
    ?assertMatch({error, {duplicate_csr, _}},
                 ias_csr_enrollment_state:submitted(<<"used-fp">>)).

certresponse_not_found_is_friendly_cmp_error_test() ->
    Raw = <<"/home/operator/ca/openssl: certresponse not found: expected certReqId = -1">>,
    ?assertEqual(cmp_unexpected_certificate_response,
                 ias_device_csr_enrollment:normalize_cmp_error(Raw)).

successful_enrollment_marks_csr_issued_and_auto_selects_certificate_test() ->
    with_configured_ca(fun() ->
        ias_demo_state:clear(),
        ias_csr_enrollment_state:clear(),
        Draft = client_ready_draft(),
        CmpFun = fun(_Request) -> {ok, cmp_result(client_cert_pem())} end,
        {ok, Advanced, Certificate} = ias_device_csr_enrollment:enroll_for_wizard_with(
            maps:get(id, Draft), client_csr_pem(), CmpFun),
        {ok, Csr} = ias_csr_validation:validate(client_csr_pem()),
        {ok, State} = ias_csr_enrollment_state:get(maps:get(csr_fingerprint, Csr)),
        ?assertEqual(issued, maps:get(status, State)),
        ?assertEqual(maps:get(id, Certificate), maps:get(client_certificate_id, Advanced))
    end).

standalone_enrollment_import_still_works_test() ->
    ias_demo_state:clear(),
    EnrollmentId = ias_demo_store:add_enrollment_result(
        #{subject => <<"CN=standalone">>,
          issuer => <<"CN=Standalone CA">>,
          not_before => <<"260621000000Z">>,
          not_after => <<"360621000000Z">>,
          requested_cn => <<"standalone">>,
          enrollment_cn => <<"standalone-20260621">>,
          profile => <<"secp384r1">>,
          cmp_server => <<"127.0.0.1:8829">>}),
    {ok, _} = ias_certificate_material:stage_cmp(EnrollmentId, client_cert_pem()),
    ?assertMatch({ok, #{source := cmp_demo_enrollment}},
                 ias_cert_enrollment_import:import(EnrollmentId)).

client_ready_draft() ->
    Device = ias_demo_store:add_device(
        #{id => <<"device_csr_wizard_device">>,
          name => <<"Device CSR Wizard Device">>,
          type => <<"vpn-client">>,
          tunnel_device => <<"tun">>,
          transport => <<"udp">>,
          endpoint => <<"vpn.example.com">>,
          private_key_provider => <<"device_file">>,
          private_key_ref => <<"client.key">>}),
    Service = ias_demo_store:add_service(
        #{id => <<"device_csr_service">>,
          service => openvpn,
          remote_host => <<"vpn.example.com">>,
          remote_port => <<"1194">>,
          protocol => <<"udp">>}),
    Ca = configured_ca(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft1} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => client_certificate,
                                device_id => maps:get(id, Device),
                                security_profile_id => default_user,
                                vpn_service_id => maps:get(id, Service),
                                ca_certificate_id => maps:get(id, Ca)}),
    Draft1.

configured_ca() ->
    {ok, Ca} = ias_configured_ca_trust_anchor:load(),
    Ca.

cmp_result(CertPem) ->
    #{certificate_pem => CertPem,
      subject => <<"CN=device-csr-client">>,
      issuer => <<"CN=IASDeviceTestCA">>,
      not_before => <<"260621130813Z">>,
      not_after => <<"360618130813Z">>,
      requested_cn => <<"device-csr-client">>,
      enrollment_cn => <<"device-csr-client">>,
      profile => <<"secp384r1">>,
      cmp_server => <<"127.0.0.1:8829">>}.

with_configured_ca(Fun) ->
    with_ca_pem(ca_pem(), Fun).

with_other_configured_ca(Fun) ->
    with_ca_pem(other_ca_pem(), Fun).

with_ca_pem(Pem, Fun) ->
    PreviousFile = application:get_env(ias, ca_trust_anchor_file),
    PreviousBase = application:get_env(ias, ca_trust_anchor_base_dir),
    PreviousMode = application:get_env(ias, certificate_validation_mode),
    Dir = filename:join(["/tmp", "ias_device_csr_" ++
                         integer_to_list(erlang:unique_integer([positive]))]),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "ca.pem"),
    ok = file:write_file(Path, Pem),
    application:set_env(ias, ca_trust_anchor_file, Path),
    application:set_env(ias, ca_trust_anchor_base_dir, "."),
    application:set_env(ias, certificate_validation_mode, strict),
    try Fun()
    after
        restore_env(ca_trust_anchor_file, PreviousFile),
        restore_env(ca_trust_anchor_base_dir, PreviousBase),
        restore_env(certificate_validation_mode, PreviousMode),
        file:del_dir_r(Dir)
    end.

restore_env(Key, undefined) ->
    application:unset_env(ias, Key);
restore_env(Key, {ok, Value}) ->
    application:set_env(ias, Key, Value).

list_match(Value, List) ->
    case lists:member(Value, List) of
        true -> {0, byte_size(Value)};
        false -> nomatch
    end.

tampered_csr_pem() ->
    [{'CertificationRequest', Der, not_encrypted}] = public_key:pem_decode(client_csr_pem()),
    Tampered = binary:replace(Der, <<"device-csr-client">>, <<"eevice-csr-client">>),
    public_key:pem_encode([{'CertificationRequest', Tampered, not_encrypted}]).

client_csr_pem() ->
    <<"-----BEGIN CERTIFICATE REQUEST-----\n"
      "MIHXMH4CAQAwHDEaMBgGA1UEAwwRZGV2aWNlLWNzci1jbGllbnQwWTATBgcqhkjO\n"
      "PQIBBggqhkjOPQMBBwNCAAQT3KdjwHVNuPmLBYCRkhymCnVD5q7MLivbvVm0Vl4X\n"
      "mPecyECAkVtd2RBBphTV8319Z2/nm0K6Y00/rB89cL2soAAwCgYIKoZIzj0EAwID\n"
      "SQAwRgIhAOQR71n3U+04kFtvjJA3qJtYCbeFQ53H3nhHZNvLxvuWAiEAs2MAGPxh\n"
      "+Mgci8alLw2w3RM527q7uprKoXAfgeRdJYY=\n"
      "-----END CERTIFICATE REQUEST-----\n">>.

ca_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBqjCCAVCgAwIBAgIUFtvpb5Hv/vOO1skYjsT/XKLEt+8wCgYIKoZIzj0EAwIw\n"
      "GjEYMBYGA1UEAwwPSUFTRGV2aWNlVGVzdENBMB4XDTI2MDYyMTEzMDgxM1oXDTM2\n"
      "MDYxODEzMDgxM1owGjEYMBYGA1UEAwwPSUFTRGV2aWNlVGVzdENBMFkwEwYHKoZI\n"
      "zj0CAQYIKoZIzj0DAQcDQgAEPpujQkaTZ1+IaiVx/3PkPnBADCX6UdZdNCDTh6La\n"
      "nUavDCwnG2D+wJlzKsUEudetIv3HAzqjaEGltseXGeWy2qN0MHIwHQYDVR0OBBYE\n"
      "FM1UFWWh5RxA25vBIA04iOCaOJrlMB8GA1UdIwQYMBaAFM1UFWWh5RxA25vBIA04\n"
      "iOCaOJrlMA8GA1UdEwEB/wQFMAMBAf8wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8B\n"
      "Af8EBAMCAQYwCgYIKoZIzj0EAwIDSAAwRQIgCYZMp72a/Yq/7zIO4gRxqh2Wz0n6\n"
      "mRhBPTzakcEV/e0CIQCpzukW85yNZRkRQZp4giHXv490SlC678ll7KfpIVJggw==\n"
      "-----END CERTIFICATE-----\n">>.

client_cert_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBbTCCAROgAwIBAgIUYnJ8yI7Y/jVlIVdkAQIwtk5sBNkwCgYIKoZIzj0EAwIw\n"
      "GjEYMBYGA1UEAwwPSUFTRGV2aWNlVGVzdENBMB4XDTI2MDYyMTEzMDgxM1oXDTM2\n"
      "MDYxODEzMDgxM1owHDEaMBgGA1UEAwwRZGV2aWNlLWNzci1jbGllbnQwWTATBgcq\n"
      "hkjOPQIBBggqhkjOPQMBBwNCAAQT3KdjwHVNuPmLBYCRkhymCnVD5q7MLivbvVm0\n"
      "Vl4XmPecyECAkVtd2RBBphTV8319Z2/nm0K6Y00/rB89cL2sozUwMzAMBgNVHRMB\n"
      "Af8EAjAAMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDAjAKBggq\n"
      "hkjOPQQDAgNIADBFAiEAtBi5V82vWbaLftiPWxYBZPxw0sO37jqXJ8QF7qKSWzEC\n"
      "ICXq5f7iviBZcW0jXtOKB/8+66c4t2xcM2cPXphfVPS0\n"
      "-----END CERTIFICATE-----\n">>.

other_client_cert_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBaDCCAQ6gAwIBAgIUYnJ8yI7Y/jVlIVdkAQIwtk5sBNowCgYIKoZIzj0EAwIw\n"
      "GjEYMBYGA1UEAwwPSUFTRGV2aWNlVGVzdENBMB4XDTI2MDYyMTEzMDgxM1oXDTM2\n"
      "MDYxODEzMDgxM1owFzEVMBMGA1UEAwwMb3RoZXItY2xpZW50MFkwEwYHKoZIzj0C\n"
      "AQYIKoZIzj0DAQcDQgAExPj9BuCFudEG2Onr0HLIUxKbf0194mlVD1lk0BQpJThd\n"
      "j5YDgtbnmAV1ui1YJUzQH6aKzlVA2CsQ1IdAqBZgYaM1MDMwDAYDVR0TAQH/BAIw\n"
      "ADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwIwCgYIKoZIzj0E\n"
      "AwIDSAAwRQIhALLsw5f6y1Lu6c4aZPpNXem8q68Pn1xONdz4FuJ+dhm0AiAQsYhb\n"
      "3CBlWQIgHKjxBD0TDhpBSH2puLvlaUmxG8IgxA==\n"
      "-----END CERTIFICATE-----\n">>.

other_ca_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBpDCCAUqgAwIBAgIURWopEjxBWEnaN96gVY1c6eQ94BAwCgYIKoZIzj0EAwIw\n"
      "FzEVMBMGA1UEAwwMSUFTIE90aGVyIENBMB4XDTI2MDYyMTEyMTMwNFoXDTM2MDYx\n"
      "ODEyMTMwNFowFzEVMBMGA1UEAwwMSUFTIE90aGVyIENBMFkwEwYHKoZIzj0CAQYI\n"
      "KoZIzj0DAQcDQgAEhA1YGntgDsrg8mw+tDlKq4zR8au8OQp/XsnHYqjui77LYm9f\n"
      "VqFuHPlm/2ULsKt/fCs8eilHxnbLXbRb7BGW46N0MHIwHQYDVR0OBBYEFJcfJ21r\n"
      "TGXOFCwLwpLrzyKgvPaZMB8GA1UdIwQYMBaAFJcfJ21rTGXOFCwLwpLrzyKgvPaZ\n"
      "MA8GA1UdEwEB/wQFMAMBAf8wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC\n"
      "AQYwCgYIKoZIzj0EAwIDSAAwRQIgRT7I9+W19TBl086LDxktsIKM0EiScQ43UamZ\n"
      "AzHJ+PECIQCGJnudBPRT1ppYr6bzrKQnj1aiowupWBYVm/srkBqfug==\n"
      "-----END CERTIFICATE-----\n">>.

csr_command_device(Name, KeyRef) ->
    #{id => <<"csr_command_device">>,
      kind => device,
      name => Name,
      type => <<"vpn-client">>,
      private_key_provider => <<"device_file">>,
      private_key_ref => KeyRef}.
