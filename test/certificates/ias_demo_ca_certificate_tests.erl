-module(ias_demo_ca_certificate_tests).
-include_lib("eunit/include/eunit.hrl").

register_ca_certificate_success_test() ->
    ias_demo_state:clear(),
    {ok, Certificate} = ias_demo_ca_certificate:register(valid_fields()),

    ?assertEqual(certificate, maps:get(kind, Certificate)),
    ?assertEqual(ca_certificate, maps:get(source, Certificate)),
    ?assertEqual(ca_certificate, maps:get(material_type, Certificate)),
    ?assertEqual(ca_certificate, maps:get(certificate_role, Certificate)),
    ?assertEqual(trusted, maps:get(certificate_status, Certificate)),
    ?assertEqual(<<"Demo Root CA">>, maps:get(name, Certificate)),
    ?assertEqual(<<"CN=Demo Root CA">>, maps:get(subject, Certificate)).

ca_pem_is_stored_only_in_material_store_test() ->
    ias_demo_state:clear(),
    {ok, Certificate} = ias_demo_ca_certificate:register(valid_fields()),
    {ok, Material} = ias_certificate_material:get(maps:get(id, Certificate)),

    ?assertEqual(ca_certificate, maps:get(material_type, Material)),
    ?assertEqual(operator_load, maps:get(source, Material)),
    ?assertMatch({_, _}, binary:match(maps:get(body, Material), <<"BEGIN CERTIFICATE">>)),
    ?assertEqual(false, maps:is_key(body, Certificate)),
    ?assertEqual(false, maps:is_key(certificate_pem, Certificate)),
    ?assertEqual(false, maps:is_key(ca_certificate_pem, Certificate)).

malformed_and_private_key_pem_are_rejected_test() ->
    ias_demo_state:clear(),
    Malformed = (valid_fields())#{pem => <<"not a certificate">>},
    PrivateKey = (valid_fields())#{pem => <<"-----BEGIN PRIVATE KEY-----\nZm9yZ2Vk\n-----END PRIVATE KEY-----\n">>},

    ?assertEqual({error, invalid_certificate_pem},
                 ias_demo_ca_certificate:register(Malformed)),
    ?assertEqual({error, private_key_material_rejected},
                 ias_demo_ca_certificate:register(PrivateKey)),
    ?assertEqual([], ias_demo_store:certificates()).

multiple_pem_blocks_are_rejected_test() ->
    ias_demo_state:clear(),
    Pem = ca_pem(),
    Result = ias_demo_ca_certificate:register((valid_fields())#{pem => <<Pem/binary, Pem/binary>>}),

    ?assertEqual({error, exactly_one_certificate_required}, Result),
    ?assertEqual([], ias_demo_store:certificates()).

client_certificate_pem_is_rejected_as_ca_trust_anchor_test() ->
    ias_demo_state:clear(),
    Result = ias_demo_ca_certificate:register((valid_fields())#{pem => client_pem()}),

    ?assertEqual({error, <<"CA certificate must have basicConstraints CA=TRUE">>}, Result),
    ?assertEqual([], ias_demo_store:certificates()).

required_fields_are_validated_test() ->
    ias_demo_state:clear(),

    ?assertEqual({error, <<"Name is required">>},
                 ias_demo_ca_certificate:register((valid_fields())#{name => <<"  ">>})),
    ?assertEqual({error, <<"Subject is required">>},
                 ias_demo_ca_certificate:register((valid_fields())#{subject => <<"  ">>})),
    ?assertEqual({error, <<"Certificate PEM is required">>},
                 ias_demo_ca_certificate:register((valid_fields())#{pem => <<"">>})).

ca_metadata_roundtrips_without_pem_test() ->
    ias_demo_state:clear(),
    {ok, Certificate} = ias_demo_ca_certificate:register(valid_fields()),
    Id = maps:get(id, Certificate),
    Snapshot = ias_demo_state:export(),

    ?assertMatch({_, _}, binary:match(Snapshot, Id)),
    ?assertEqual(nomatch, binary:match(Snapshot, <<"BEGIN CERTIFICATE">>)),

    ok = ias_demo_state:clear(),
    Result = ias_demo_state:import(Snapshot),

    ?assertEqual(1, maps:get(imported_objects, Result)),
    ?assertMatch({ok, #{source := ca_certificate}}, ias_demo_store:get(Id)),
    ?assertEqual(not_found, ias_certificate_material:status(Id)).

registered_ca_can_be_linked_to_vpn_service_test() ->
    ias_demo_state:clear(),
    {ok, Certificate} = ias_demo_ca_certificate:register(valid_fields()),
    Service = ias_demo_store:add_service(#{id => <<"registered_ca_service">>}),

    ?assertMatch({ok, #{relation_type := uses_ca_certificate}},
                 ias_relationship_link:create(uses_ca_certificate,
                                              maps:get(id, Service),
                                              maps:get(id, Certificate))).

registered_ca_is_rejected_for_device_certificate_test() ->
    ias_demo_state:clear(),
    {ok, Certificate} = ias_demo_ca_certificate:register(valid_fields()),
    Device = ias_demo_store:add_device(#{id => <<"registered_ca_device">>}),
    {error, Reason} = ias_relationship_link:create(uses_certificate,
                                                   maps:get(id, Device),
                                                   maps:get(id, Certificate)),

    ?assertEqual(incompatible_certificate_role, maps:get(reason, Reason)),
    ?assertEqual(ca_certificate, maps:get(actual_role, Reason)).

client_certificate_is_still_rejected_as_ca_test() ->
    ias_demo_state:clear(),
    Service = ias_demo_store:add_service(#{id => <<"client_as_ca_service">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"client_as_ca_certificate">>,
                                                   source => certificate_issue_demo}),
    {error, Reason} = ias_relationship_link:create(uses_ca_certificate,
                                                   maps:get(id, Service),
                                                   maps:get(id, Certificate)),

    ?assertEqual(incompatible_certificate_role, maps:get(reason, Reason)),
    ?assertEqual(client_certificate, maps:get(actual_role, Reason)).

valid_fields() ->
    #{name => <<"Demo Root CA">>,
      subject => <<"CN=Demo Root CA">>,
      pem => ca_pem()}.

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
