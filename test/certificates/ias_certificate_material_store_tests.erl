-module(ias_certificate_material_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ias_certificate_material_record.hrl").
-include_lib("kvs/include/metainfo.hrl").

certificate_material_store_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun table_is_registered_in_kvs_schema/0,
      fun public_material_is_rehydrated_from_kvs/0,
      fun staged_cmp_material_is_durable_and_attached_atomically/0,
      fun expired_staged_cmp_material_is_pruned/0,
      fun unknown_read_purpose_is_denied/0,
      fun aes_gcm_provider_encrypts_the_durable_body/0,
      fun aes_gcm_provider_fails_closed_with_wrong_key/0,
      fun incompatible_schema_fails_closed/0]}.

table_is_registered_in_kvs_schema() ->
    Fields = record_info(fields, ias_certificate_material_record),
    ?assertMatch(#table{fields = Fields,
                        type = set,
                        copy_type = disc_copies},
                 kvs:table(ias_certificate_material_record)).

public_material_is_rehydrated_from_kvs() ->
    Certificate = certificate(<<"stage6d-rehydrate-certificate">>),
    _ = ias_demo_store:put_runtime_object(Certificate),
    {ok, Status} = ias_certificate_material:put(
                     maps:get(id, Certificate),
                     client_certificate,
                     client_pem(),
                     operator_load),
    ?assertEqual(public_integrity_sha256,
                 maps:get(protection_mode, Status)),
    true = ets:delete_all_objects(ias_certificate_material),
    ?assertEqual(not_found,
                 ias_certificate_material:get(maps:get(id, Certificate))),

    ?assertEqual({ok, 1}, ias_certificate_material:rehydrate()),
    ?assertMatch({ok, #{body := _Pem,
                        material_type := client_certificate,
                        source := operator_load}},
                 ias_certificate_material:get(maps:get(id, Certificate),
                                              operator_inspection)),
    ?assertEqual({ok, 1}, ias_certificate_material_store:count()).

staged_cmp_material_is_durable_and_attached_atomically() ->
    EnrollmentId = <<"stage6d-staged-enrollment">>,
    CertificateId = <<"stage6d-attached-certificate">>,
    {ok, _} = ias_certificate_material:stage_cmp(EnrollmentId, client_pem()),
    true = ets:delete_all_objects(ias_certificate_material),
    ?assertEqual({ok, 1}, ias_certificate_material:rehydrate()),
    _ = ias_demo_store:put_runtime_object(certificate(CertificateId)),

    {ok, Status} = ias_certificate_material:attach_staged(EnrollmentId,
                                                           CertificateId),
    ?assertEqual(cmp_response, maps:get(source, Status)),
    ?assertEqual(not_found,
                 ias_certificate_material_store:get_staged(EnrollmentId)),
    ?assertMatch({ok, #{certificate_id := CertificateId,
                        body := _}},
                 ias_certificate_material_store:get_certificate(CertificateId)),
    ?assertEqual({ok, 1}, ias_certificate_material_store:count()).

expired_staged_cmp_material_is_pruned() ->
    EnrollmentId = <<"stage6d-expired-enrollment">>,
    {ok, _} = ias_certificate_material:stage_cmp(EnrollmentId, client_pem()),
    Key = {staged_cmp, EnrollmentId},
    {ok, Record0} = kvs:get(ias_certificate_material_record, Key),
    Expired = Record0#ias_certificate_material_record{
                created_at = 1,
                updated_at = 1,
                expires_at = 2},
    ok = kvs:put(Expired),
    true = ets:delete_all_objects(ias_certificate_material),

    ?assertEqual({ok, 0}, ias_certificate_material:rehydrate()),
    ?assertEqual(not_found,
                 ias_certificate_material_store:get_staged(EnrollmentId)).

unknown_read_purpose_is_denied() ->
    ?assertEqual({error,
                  {certificate_material_access_denied, arbitrary_export}},
                 ias_certificate_material:get(<<"missing">>,
                                              arbitrary_export)).

aes_gcm_provider_encrypts_the_durable_body() ->
    ok = ias_certificate_material:clear(),
    ok = application:set_env(
           ias,
           certificate_material_protection_provider,
           ias_certificate_material_protection_aes_gcm),
    Key = <<0:256>>,
    ok = application:set_env(ias, certificate_material_encryption_key, Key),
    Certificate = certificate(<<"stage6d-encrypted-certificate">>),
    _ = ias_demo_store:put_runtime_object(Certificate),

    {ok, Status} = ias_certificate_material:put(
                     maps:get(id, Certificate),
                     client_certificate,
                     client_pem(),
                     operator_load),
    ?assertEqual(aes_256_gcm, maps:get(protection_mode, Status)),
    {ok, Record} = kvs:get(
                     ias_certificate_material_record,
                     {certificate, maps:get(id, Certificate)}),
    Envelope = Record#ias_certificate_material_record.body_envelope,
    ?assertEqual(aes_256_gcm, maps:get(algorithm, Envelope)),
    ?assertEqual(false, maps:is_key(body, Envelope)),
    ?assertEqual(nomatch,
                 binary:match(term_to_binary(Envelope),
                              <<"BEGIN CERTIFICATE">>)),
    true = ets:delete_all_objects(ias_certificate_material),
    ?assertEqual({ok, 1}, ias_certificate_material:rehydrate()),
    ?assertMatch({ok, #{body := _}},
                 ias_certificate_material:get(maps:get(id, Certificate),
                                              operator_inspection)).

aes_gcm_provider_fails_closed_with_wrong_key() ->
    ok = ias_certificate_material:clear(),
    ok = application:set_env(
           ias,
           certificate_material_protection_provider,
           ias_certificate_material_protection_aes_gcm),
    Key1 = <<1:256>>,
    Key2 = <<2:256>>,
    ok = application:set_env(ias, certificate_material_encryption_key, Key1),
    Certificate = certificate(<<"stage6d-wrong-key-certificate">>),
    _ = ias_demo_store:put_runtime_object(Certificate),
    {ok, _} = ias_certificate_material:put(
                maps:get(id, Certificate),
                client_certificate,
                client_pem(),
                operator_load),
    ok = application:set_env(ias, certificate_material_encryption_key, Key2),
    ?assertMatch({error, certificate_material_decryption_failed},
                 ias_certificate_material_store:validate_all()),
    ok = application:set_env(ias, certificate_material_encryption_key, Key1).

incompatible_schema_fails_closed() ->
    Certificate = certificate(<<"stage6d-invalid-schema">>),
    _ = ias_demo_store:put_runtime_object(Certificate),
    {ok, _} = ias_certificate_material:put(
                maps:get(id, Certificate),
                client_certificate,
                client_pem(),
                operator_load),
    Key = {certificate, maps:get(id, Certificate)},
    {ok, Record0} = kvs:get(ias_certificate_material_record, Key),
    Invalid = Record0#ias_certificate_material_record{schema_version = 999},
    ok = kvs:put(Invalid),

    ?assertEqual({error,
                  {unsupported_certificate_material_schema_version, 999}},
                 ias_certificate_material_store:validate_all()).

setup() ->
    PreviousProvider = application:get_env(
                         ias,
                         certificate_material_protection_provider),
    PreviousKey = application:get_env(ias,
                                      certificate_material_encryption_key),
    ok = application:set_env(
           ias,
           certificate_material_protection_provider,
           ias_certificate_material_protection_public),
    ok = ias_certificate_material_store:ensure(),
    ok = ias_certificate_material:clear(),
    ok = ias_demo_store:clear(),
    #{provider => PreviousProvider, key => PreviousKey}.

cleanup(State) ->
    _ = ias_certificate_material_store:reset(),
    _ = ias_demo_store:clear(),
    restore_env(certificate_material_protection_provider,
                maps:get(provider, State)),
    restore_env(certificate_material_encryption_key,
                maps:get(key, State)),
    ok.

restore_env(Key, {ok, Value}) -> application:set_env(ias, Key, Value);
restore_env(Key, undefined) -> application:unset_env(ias, Key).

certificate(Id) ->
    #{id => Id,
      kind => certificate,
      source => certificate_issue_demo,
      name => <<"Stage 6D certificate">>,
      subject => <<"CN=Stage 6D">>,
      issuer => <<"CN=IAS Test CA">>,
      certificate_role => client_certificate,
      certificate_status => trusted,
      private_key_stored => false,
      certificate_body_stored => false,
      ca_body_stored => false}.

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
