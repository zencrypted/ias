-module(ias_domain_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ias_domain_object.hrl").
-include_lib("kvs/include/metainfo.hrl").

store_contract_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         {inorder,
          [?_test(table_is_durable()),
           ?_test(idempotent_put_get_delete()),
           ?_test(kvs_api_is_the_storage_boundary()),
           ?_test(changed_projection_increments_revision()),
           ?_test(unsupported_kind_is_rejected()),
           ?_test(secret_bearing_payload_is_rejected()),
           ?_test(non_secret_private_key_metadata_is_allowed()),
           ?_test(certificate_matching_metadata_is_preserved()),
           ?_test(relationship_integrity_is_enforced()),
           ?_test(transaction_rolls_back())]}
     end}.

table_is_durable() ->
    ?assertEqual(ok, ias_domain_store:ensure()),
    #table{fields = Fields, copy_type = CopyType, type = Type} =
        kvs:table(ias_domain_object),
    ?assertEqual(record_info(fields, ias_domain_object), Fields),
    ?assertEqual(disc_copies, CopyType),
    ?assertEqual(set, Type),
    ?assert(lists:member({table, ias_domain_object}, kvs:dir())).

idempotent_put_get_delete() ->
    Device = device(<<"domain-device-idempotent">>),
    {ok, First, changed} = ias_domain_store:put(Device),
    ?assertEqual(1, maps:get(revision, First)),
    ?assertEqual(Device, maps:get(payload, First)),

    {ok, Second, unchanged} = ias_domain_store:put(Device),
    ?assertEqual(1, maps:get(revision, Second)),
    ?assertEqual(maps:get(updated_at, First), maps:get(updated_at, Second)),

    {ok, Stored} = ias_domain_store:get(device, maps:get(id, Device)),
    ?assertEqual(Device, maps:get(payload, Stored)),
    ok = ias_domain_store:delete(device, maps:get(id, Device)),
    ?assertEqual(not_found,
                 ias_domain_store:get(device, maps:get(id, Device))),
    ?assertEqual(ok,
                 ias_domain_store:delete(device, maps:get(id, Device))).


kvs_api_is_the_storage_boundary() ->
    Device = device(<<"domain-device-kvs-boundary">>),
    {ok, Stored, changed} = ias_domain_store:put(Device),
    Key = maps:get(key, Stored),
    {ok, #ias_domain_object{payload = Payload}} =
        kvs:get(ias_domain_object, Key),
    ?assertEqual(Device, Payload),
    ok = ias_domain_store:delete(device, maps:get(id, Device)),
    ?assertEqual({error, not_found},
                 kvs:get(ias_domain_object, Key)).

changed_projection_increments_revision() ->
    Device0 = device(<<"domain-device-revision">>),
    {ok, First, changed} = ias_domain_store:put(Device0),
    Device1 = Device0#{name => <<"Updated durable device">>,
                       transient_debug => should_not_persist},
    {ok, Second, changed} = ias_domain_store:put(Device1),
    Payload = maps:get(payload, Second),
    ?assertEqual(2, maps:get(revision, Second)),
    ?assertEqual(maps:get(created_at, First), maps:get(created_at, Second)),
    ?assertEqual(<<"Updated durable device">>, maps:get(name, Payload)),
    ?assertEqual(false, maps:is_key(transient_debug, Payload)).

unsupported_kind_is_rejected() ->
    ?assertEqual({error, {unsupported_domain_kind, unknown}},
                 ias_domain_store:put(#{id => <<"unsupported">>,
                                        kind => unknown})).

secret_bearing_payload_is_rejected() ->
    DeviceId = <<"domain-device-secret">>,
    Device = (device(DeviceId))#{
               metadata => #{private_key => <<"must-not-persist">>}},
    ?assertEqual({error,
                  {forbidden_domain_material, [metadata, private_key]}},
                 ias_domain_store:put(Device)),
    PemDevice = (device(DeviceId))#{
                  metadata =>
                      #{blob => <<"-----BEGIN PRIVATE KEY-----\nsecret">>}},
    ?assertEqual({error,
                  {forbidden_domain_material,
                   [metadata, blob, sensitive_value]}},
                 ias_domain_store:put(PemDevice)),
    ?assertEqual(not_found,
                 ias_domain_store:get(device, DeviceId)).

non_secret_private_key_metadata_is_allowed() ->
    Id = <<"domain-ovpn-private-key-metadata">>,
    Provisioning = #{id => Id,
                     kind => ovpn_provisioning,
                     source => domain_store_test,
                     material_requirements => #{private_key => device_owned},
                     material_sources => #{private_key => device},
                     material_components => #{private_key => available_on_device},
                     artifact_filename => <<"device.ovpn">>,
                     private_key_stored => false,
                     certificate_body_stored => false,
                     ca_body_stored => false},
    {ok, Stored, changed} = ias_domain_store:put(Provisioning),
    Payload = maps:get(payload, Stored),
    ?assertEqual(device,
                 maps:get(private_key, maps:get(material_sources, Payload))),
    ?assertEqual(<<"device.ovpn">>, maps:get(artifact_filename, Payload)),
    ?assertEqual(
       {error, {forbidden_domain_material, [material_sources, private_key]}},
       ias_domain_store:put(
         Provisioning#{material_sources => #{private_key => <<"secret">>}})).

certificate_matching_metadata_is_preserved() ->
    Id = <<"domain-certificate-matching-metadata">>,
    Certificate = (certificate(Id))#{requested_cn => <<"router-1">>,
                                         enrollment_cn => <<"router-1-20260625">>,
                                         cmp_server => <<"127.0.0.1:8829">>},
    {ok, Stored, changed} = ias_domain_store:put(Certificate),
    Payload = maps:get(payload, Stored),
    ?assertEqual(<<"router-1">>, maps:get(requested_cn, Payload)),
    ?assertEqual(<<"router-1-20260625">>, maps:get(enrollment_cn, Payload)),
    ?assertEqual(<<"127.0.0.1:8829">>, maps:get(cmp_server, Payload)).

relationship_integrity_is_enforced() ->
    Device = device(<<"domain-device-relationship">>),
    Certificate = certificate(<<"domain-certificate-relationship">>),
    Relationship = relationship(<<"domain-relationship">>,
                                maps:get(id, Device),
                                maps:get(id, Certificate)),
    ?assertEqual(
       {error, {missing_domain_reference, device, maps:get(id, Device)}},
       ias_domain_store:put(Relationship)),
    {ok, _DeviceRecord, changed} = ias_domain_store:put(Device),
    {ok, _CertificateRecord, changed} = ias_domain_store:put(Certificate),
    {ok, _RelationshipRecord, changed} = ias_domain_store:put(Relationship),
    ?assertMatch(
       {error, {domain_object_referenced, device, _, [_]}},
       ias_domain_store:delete(device, maps:get(id, Device))),
    ok = ias_domain_store:delete(relationship, maps:get(id, Relationship)),
    ok = ias_domain_store:delete(device, maps:get(id, Device)),
    ok = ias_domain_store:delete(certificate, maps:get(id, Certificate)).

transaction_rolls_back() ->
    Device = device(<<"domain-device-rollback">>),
    Result = ias_domain_store:transaction(
               fun() ->
                   {ok, _Record, changed} = ias_domain_store:put(Device),
                   erlang:error(forced_domain_transaction_failure)
               end),
    ?assertMatch({error, {domain_store_transaction_failed, _}}, Result),
    ?assertEqual(not_found,
                 ias_domain_store:get(device, maps:get(id, Device))).

unsupported_schema_fails_closed_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun() ->
         Id = <<"domain-device-schema">>,
         ?assertEqual({error, {unsupported_domain_schema_version, 99}},
                      ias_domain_store:put(
                        (device(Id))#{schema_version => 99})),
         ok = kvs:put(
                #ias_domain_object{key = {device, Id},
                                   schema_version = 99,
                                   kind = device,
                                   object_id = Id,
                                   payload = device(Id),
                                   revision = 1,
                                   created_at = 1,
                                   updated_at = 1}),
         ?assertEqual({error, {unsupported_domain_schema_version, 99}},
                      ias_domain_store:ensure())
     end}.

setup() ->
    ok = ias_domain_store:ensure(),
    ok = ias_domain_store:reset(),
    ok.

cleanup(_Context) ->
    ok = ias_domain_store:reset().

device(Id) ->
    #{id => Id,
      kind => device,
      source => domain_store_test,
      owner => alice,
      name => <<"Durable device">>,
      type => <<"vpn-client">>,
      endpoint => <<"127.0.0.1:1194">>,
      transport => udp,
      tunnel_device => tun,
      private_key_provider => <<"device_file">>,
      private_key_ref => <<"client.key">>,
      private_key_stored => false,
      certificate_body_stored => false,
      ca_body_stored => false}.

certificate(Id) ->
    #{id => Id,
      kind => certificate,
      source => domain_store_test,
      subject => <<"CN=Durable Device">>,
      issuer => <<"CN=Test CA">>,
      certificate_role => client_certificate,
      certificate_status => trusted,
      fingerprint_sha256 =>
          <<"0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF">>,
      private_key_stored => false,
      certificate_body_stored => false}.

relationship(Id, DeviceId, CertificateId) ->
    #{id => Id,
      relationship_id => Id,
      kind => relationship,
      relation_type => uses_certificate,
      source_kind => device,
      source_id => DeviceId,
      target_kind => certificate,
      target_id => CertificateId,
      score => 100,
      warnings => []}.
