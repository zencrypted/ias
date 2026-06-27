-module(ias_csr_enrollment_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ias_csr_enrollment_record.hrl").
-include_lib("kvs/include/metainfo.hrl").

csr_enrollment_persistence_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun table_is_registered_in_kvs_schema/0,
      fun lifecycle_states_are_written_and_rehydrated/0,
      fun repeated_rehydration_is_idempotent/0,
      fun duplicate_and_public_key_reuse_guards_survive_rehydration/0,
      fun secret_and_body_material_is_rejected/0,
      fun incompatible_schema_fails_closed/0]}.

setup() ->
    ok = ias_csr_enrollment_store:ensure(),
    ok = ias_csr_enrollment_state:clear(),
    ok.

cleanup(_) ->
    ok = ias_csr_enrollment_state:clear().

table_is_registered_in_kvs_schema() ->
    #table{fields = Fields, copy_type = CopyType, type = Type} =
        kvs:table(ias_csr_enrollment_record),
    ?assertEqual(record_info(fields, ias_csr_enrollment_record), Fields),
    ?assertEqual(disc_copies, CopyType),
    ?assertEqual(set, Type),
    ?assert(lists:member({table, ias_csr_enrollment_record}, kvs:dir())).

lifecycle_states_are_written_and_rehydrated() ->
    {ok, Submitted} = ias_csr_enrollment_state:mark_submitted(
                        <<"csr-submitted">>,
                        #{device_id => <<"device-submitted">>,
                          public_key_fingerprint => <<"pk-submitted">>}),
    {ok, Issued} = ias_csr_enrollment_state:mark_issued(
                     <<"csr-issued">>,
                     #{device_id => <<"device-issued">>,
                       public_key_fingerprint => <<"pk-issued">>,
                       certificate_id => <<"certificate-issued">>}),
    {ok, Failed} = ias_csr_enrollment_state:mark_failed(
                     <<"csr-failed">>, cmp_timeout, true),
    ?assertEqual(submitted, maps:get(status, Submitted)),
    ?assertEqual(issued, maps:get(status, Issued)),
    ?assertEqual(failed, maps:get(status, Failed)),
    ?assertEqual(true, maps:get(retryable, Failed)),

    true = ets:delete_all_objects(ias_csr_enrollment_state),
    ?assertEqual(not_found,
                 ias_csr_enrollment_state:get(<<"csr-issued">>)),
    ?assertEqual({ok, 3}, ias_csr_enrollment_state:rehydrate()),
    ?assertMatch({ok, #{status := submitted}},
                 ias_csr_enrollment_state:get(<<"csr-submitted">>)),
    ?assertMatch({ok, #{status := issued,
                        certificate_id := <<"certificate-issued">>}},
                 ias_csr_enrollment_state:get(<<"csr-issued">>)),
    ?assertMatch({ok, #{status := failed, retryable := true}},
                 ias_csr_enrollment_state:get(<<"csr-failed">>)).

repeated_rehydration_is_idempotent() ->
    {ok, Record} = ias_csr_enrollment_state:mark_submitted(
                     <<"csr-idempotent">>,
                     #{device_id => <<"device-idempotent">>}),
    ?assertEqual({ok, 1}, ias_csr_enrollment_state:rehydrate()),
    ?assertEqual({ok, 1}, ias_csr_enrollment_state:rehydrate()),
    ?assertEqual(1, ias_csr_enrollment_state:projection_count()),
    ?assertEqual([Record], ias_csr_enrollment_state:all()).

duplicate_and_public_key_reuse_guards_survive_rehydration() ->
    DeviceId = <<"device-guard">>,
    PublicKeyFingerprint = <<"public-key-guard">>,
    {ok, _} = ias_csr_enrollment_state:mark_issued(
                <<"csr-guard">>,
                #{device_id => DeviceId,
                  public_key_fingerprint => PublicKeyFingerprint}),
    {ok, _} = ias_csr_enrollment_state:mark_failed(
                <<"csr-retryable">>, cmp_connection_failed, true),
    {ok, _} = ias_csr_enrollment_state:mark_failed(
                <<"csr-non-retryable">>,
                cmp_unexpected_certificate_response,
                false),
    true = ets:delete_all_objects(ias_csr_enrollment_state),
    ?assertEqual({ok, 3}, ias_csr_enrollment_state:rehydrate()),
    ?assertMatch({error, {duplicate_csr, _}},
                 ias_csr_enrollment_state:submitted(<<"csr-guard">>)),
    ?assertMatch({error, {reused_public_key, _}},
                 ias_csr_enrollment_state:public_key_available(
                   DeviceId, PublicKeyFingerprint)),
    ?assertEqual(ok,
                 ias_csr_enrollment_state:submitted(<<"csr-retryable">>)),
    ?assertMatch({error, {duplicate_csr, _}},
                 ias_csr_enrollment_state:submitted(
                   <<"csr-non-retryable">>)).

secret_and_body_material_is_rejected() ->
    Base = #{csr_fingerprint => <<"csr-safe-reference">>,
             status => submitted,
             retryable => false,
             device_id => <<"device-safe-reference">>,
             private_key_reference => <<"keys/device.key">>},
    ?assertMatch({ok, _, changed}, ias_csr_enrollment_store:put(Base)),
    ?assertEqual(
       {error, {forbidden_csr_enrollment_material, [csr_pem]}},
       ias_csr_enrollment_store:put(
         Base#{csr_fingerprint => <<"csr-body-rejected">>,
               csr_pem => <<"CSR BODY">>})),
    ?assertEqual(
       {error, {forbidden_csr_enrollment_material, [csr_body]}},
       ias_csr_enrollment_state:mark_submitted(
         <<"csr-facade-body-rejected">>,
         #{csr_body => <<"RAW CSR BODY">>})),
    ?assertEqual(
       {error, {forbidden_csr_enrollment_material,
                [result_summary, pem_material]}},
       ias_csr_enrollment_store:put(
         Base#{csr_fingerprint => <<"csr-pem-rejected">>,
               result_summary => <<"-----BEGIN CERTIFICATE-----\nSECRET">>})),
    ?assertEqual(not_found,
                 ias_csr_enrollment_store:get(<<"csr-body-rejected">>)),
    ?assertEqual(not_found,
                 ias_csr_enrollment_store:get(<<"csr-pem-rejected">>)).

incompatible_schema_fails_closed() ->
    Fingerprint = <<"csr-bad-schema">>,
    Payload = #{csr_fingerprint => Fingerprint,
                status => submitted,
                retryable => false},
    Record = #ias_csr_enrollment_record{
                csr_fingerprint = Fingerprint,
                schema_version = 999,
                status = submitted,
                retryable = false,
                payload = Payload,
                created_at = 1,
                updated_at = 1},
    ok = kvs:put(Record),
    ?assertEqual(
       {error, {unsupported_csr_enrollment_schema_version, 999}},
       ias_csr_enrollment_store:ensure()),
    ok = kvs:delete(ias_csr_enrollment_record, Fingerprint).
