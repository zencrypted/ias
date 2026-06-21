-module(ias_certificate_material_tests).
-include_lib("eunit/include/eunit.hrl").

public_certificate_material_store_test() ->
    ias_demo_store:clear(),
    ias_certificate_material:clear(),
    Certificate = ias_demo_store:add_certificate(#{id => <<"material_client_certificate">>,
                                                   source => certificate_issue_demo}),
    Pem = client_pem(),

    {ok, Status} = ias_certificate_material:put(
        maps:get(id, Certificate), client_certificate, Pem, operator_load),
    {ok, Stored} = ias_certificate_material:get(maps:get(id, Certificate)),

    ?assertEqual(client_certificate, maps:get(material_type, Status)),
    ?assertEqual(operator_load, maps:get(source, Status)),
    ?assertEqual(false, maps:is_key(body, Status)),
    ?assertEqual(normalized_certificate_pem(Pem), maps:get(body, Stored)),
    ?assert(byte_size(maps:get(fingerprint_sha256, Status)) > 0).

private_key_material_is_rejected_test() ->
    ias_demo_store:clear(),
    ias_certificate_material:clear(),
    Certificate = ias_demo_store:add_certificate(#{id => <<"material_reject_certificate">>,
                                                   source => certificate_issue_demo}),
    Private = <<"-----BEGIN PRIVATE KEY-----\nZm9yZ2Vk\n-----END PRIVATE KEY-----\n">>,

    ?assertEqual({error, private_key_material_rejected},
                 ias_certificate_material:put(maps:get(id, Certificate),
                                              client_certificate, Private,
                                              operator_load)),
    ?assertEqual(not_found, ias_certificate_material:status(maps:get(id, Certificate))).

orphan_material_is_rejected_test() ->
    ias_demo_store:clear(),
    ias_certificate_material:clear(),
    ?assertEqual({error, certificate_not_found},
                 ias_certificate_material:put(<<"missing-certificate">>,
                                              client_certificate,
                                              client_pem(),
                                              operator_load)).

demo_state_does_not_export_public_pem_test() ->
    ias_demo_state:clear(),
    Certificate = ias_demo_store:add_certificate(#{id => <<"material_snapshot_certificate">>,
                                                   source => certificate_issue_demo}),
    Pem = client_pem(),
    {ok, _} = ias_certificate_material:put(maps:get(id, Certificate),
                                           client_certificate, Pem, operator_load),

    Snapshot = ias_demo_state:export(),

    ?assertEqual(nomatch, binary:match(Snapshot, <<"BEGIN CERTIFICATE">>)),
    ?assertMatch({ok, _}, ias_certificate_material:get(maps:get(id, Certificate))),
    ok = ias_demo_state:clear(),
    ?assertEqual(not_found, ias_certificate_material:get(maps:get(id, Certificate))).


cmp_material_is_attached_after_certificate_import_test() ->
    ias_demo_state:clear(),
    EnrollmentId = ias_demo_store:add_enrollment_result(#{subject => <<"CN=staged">>,
                                                          issuer => <<"CN=CA">>}),
    Pem = client_pem(),
    {ok, _} = ias_certificate_material:stage_cmp(EnrollmentId, Pem),

    {ok, Certificate} = ias_cert_enrollment_import:import(EnrollmentId),
    {ok, Status} = ias_certificate_material:status(maps:get(id, Certificate)),

    ?assertEqual(cmp_response, maps:get(source, Status)),
    ?assertEqual(client_certificate, maps:get(material_type, Status)).

provisioning_refresh_uses_public_material_store_test() ->
    ias_demo_state:clear(),
    Device = ias_demo_store:add_device(#{id => <<"material_device">>,
                                         source => manual_device,
                                         private_key_provider => <<"device_file">>,
                                         private_key_ref => <<"client.key">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"material_device_certificate">>,
                                                   source => certificate_issue_demo}),
    Ca = ias_demo_store:add_certificate(#{id => <<"material_ca_certificate">>,
                                          source => ca_certificate}),
    Transaction0 = #{kind => ovpn_provisioning,
                     mode => device_bound,
                     authorization => allow,
                     device_id => maps:get(id, Device),
                     certificate_id => maps:get(id, Certificate),
                     ca_certificate_id => maps:get(id, Ca),
                     material_components => #{tls_auth => not_configured}},
    ?assertEqual(blocked,
                 maps:get(assembly_status, ias_ovpn_provisioning:refresh(Transaction0))),

    {ok, _} = ias_certificate_material:put(maps:get(id, Certificate), client_certificate,
                                           client_pem(), cmp_response),
    {ok, _} = ias_certificate_material:put(maps:get(id, Ca), ca_certificate,
                                           ca_pem(), operator_load),
    Transaction = ias_ovpn_provisioning:refresh(Transaction0),

    ?assertEqual(available, maps:get(client_certificate, maps:get(material_components, Transaction))),
    ?assertEqual(available, maps:get(ca_certificate, maps:get(material_components, Transaction))),
    ?assertEqual(public_material_available, maps:get(material_status, Transaction)),
    ?assertEqual(ready_for_delivery, maps:get(status, Transaction)),
    ?assertEqual(public_bundle_ready, maps:get(assembly_status, Transaction)),
    ?assertEqual(public_bundle_ready, maps:get(artifact_status, Transaction)),
    ?assertEqual(ready_for_device_import, maps:get(delivery_status, Transaction)).

ca_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBojCCAUigAwIBAgIUAwOYI6HpKSa8g5wpOfhRv6uwqX4wCgYIKoZIzj0EAwIw\n"
      "FjEUMBIGA1UEAwwLSUFTIFRlc3QgQ0EwHhcNMjYwNjIxMTIxMzA0WhcNMzYwNjE4\n"
      "MTIxMzA0WjAWMRQwEgYDVQQDDAtJQVMgVGVzdCBDQTBZMBMGByqGSM49AgEGCCqG\n"
      "SM49AwEHA0IABJAU2K3M/RJxUbnRyRMn/q/pKUvxyeSNfEd3ObgqUTI6EuoV7zXi\n"
      "JwO7p523tuE4CYTi8cRXoASS+y/QyOJHCCWjdDByMB0GA1UdDgQWBBRBopAKdb8i\n"
      "UUq0Wq/3vCdgOotuHzAfBgNVHSMEGDAWgBRBopAKdb8iUUq0Wq/3vCdgOotuHzAP\n"
      "BgNVHRMBAf8EBTADAQH/MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEG\n"
      "MAoGCCqGSM49BAMCA0gAMEUCIQDhHUDdaai3Q1/XU503lYPjc7s5c9uKSapnHS8h\n"
      "/10rEAIgCOtblJiLMv40z/YBgZrBAli1wolz7X5FSYuG24LTCGk=\n"
      "-----END CERTIFICATE-----\n">>.

client_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBZDCCAQqgAwIBAgIUa1wxwBw2MaSaN2Zaqvu/4gWUgDMwCgYIKoZIzj0EAwIw\n"
      "FjEUMBIGA1UEAwwLSUFTIFRlc3QgQ0EwHhcNMjYwNjIxMTIxMzA0WhcNMzYwNjE4\n"
      "MTIxMzA0WjAaMRgwFgYDVQQDDA9JQVMgVGVzdCBDbGllbnQwWTATBgcqhkjOPQIB\n"
      "BggqhkjOPQMBBwNCAAT9brxfCaaU/6LLtCNKICvq1UwQDTH9hS9teBzUhEPuxGcA\n"
      "0wdjEO6F1kR64uUgAoUYOOlIqj31MWH5CcqBwuuxozIwMDAMBgNVHRMBAf8EAjAA\n"
      "MAsGA1UdDwQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAjAKBggqhkjOPQQDAgNI\n"
      "ADBFAiEA2ye4DSJJuQnZ43+peLW5YsQHGEdGx9r1zuCKHxNcY0kCICsBo8QieTgA\n"
      "Iq0sBJ/RxQ+E19tAL+EarYX6zvA00gz9\n"
      "-----END CERTIFICATE-----\n">>.

normalized_certificate_pem(Pem) ->
    Trimmed = ias_html:text(string:trim(binary_to_list(Pem), trailing, "\n\r\t ")),
    <<Trimmed/binary, "\n">>.
