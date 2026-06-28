-module(ias_vpn_provisioning_delivery_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ias_vpn_provisioning_delivery_audit.hrl").
-include_lib("kvs/include/metainfo.hrl").

vpn_delivery_audit_persistence_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun table_is_registered_in_kvs_schema/0,
      fun audit_entries_are_append_only_and_rehydrated/0,
      fun repeated_rehydration_is_idempotent/0,
      fun provisioning_transaction_reference_is_preserved/0,
      fun secret_material_is_rejected/0,
      fun incompatible_schema_fails_closed/0]}.

setup() ->
    ok = ias_vpn_provisioning_delivery_store:ensure(),
    ok = ias_vpn_provisioning_delivery:reset(),
    ok.

cleanup(_) ->
    ok = ias_vpn_provisioning_delivery:reset().

table_is_registered_in_kvs_schema() ->
    #table{fields = Fields, copy_type = CopyType, type = Type} =
        kvs:table(ias_vpn_provisioning_delivery_audit),
    ?assertEqual(record_info(fields, ias_vpn_provisioning_delivery_audit),
                 Fields),
    ?assertEqual(disc_copies, CopyType),
    ?assertEqual(set, Type),
    ?assert(lists:member({table, ias_vpn_provisioning_delivery_audit},
                         kvs:dir())).

audit_entries_are_append_only_and_rehydrated() ->
    DeviceId = <<"delivery-audit-device">>,
    {ok, First} = ias_vpn_provisioning_delivery_store:append(
                    delivery(DeviceId, applied, 1)),
    {ok, Second} = ias_vpn_provisioning_delivery_store:append(
                     delivery(DeviceId, timeout, 1)),
    ?assertEqual(1, maps:get(attempt, First)),
    ?assertEqual(2, maps:get(attempt, Second)),
    ?assert(maps:get(delivery_id, First) =/=
            maps:get(delivery_id, Second)),
    ?assertEqual([], ias_vpn_provisioning_delivery:history(DeviceId)),
    ?assertEqual({ok, 2}, ias_vpn_provisioning_delivery:rehydrate()),
    [Latest, Earlier] = ias_vpn_provisioning_delivery:history(DeviceId),
    ?assertEqual(maps:get(delivery_id, Second), maps:get(delivery_id, Latest)),
    ?assertEqual(maps:get(delivery_id, First), maps:get(delivery_id, Earlier)).

repeated_rehydration_is_idempotent() ->
    DeviceId = <<"delivery-audit-idempotent">>,
    {ok, _} = ias_vpn_provisioning_delivery_store:append(
                delivery(DeviceId, disabled, 1)),
    ?assertEqual({ok, 1}, ias_vpn_provisioning_delivery:rehydrate()),
    ?assertEqual({ok, 1}, ias_vpn_provisioning_delivery:rehydrate()),
    ?assertEqual(1, ias_vpn_provisioning_delivery:projection_count()),
    ?assertEqual(1, length(ias_vpn_provisioning_delivery:history(DeviceId))).

provisioning_transaction_reference_is_preserved() ->
    ProvisioningId = <<"ovpn-provisioning-audit-reference">>,
    {ok, Stored} = ias_vpn_provisioning_delivery_store:append(
                     (delivery(<<"delivery-audit-reference">>, applied, 3))#{
                       provisioning_transaction_id => ProvisioningId}),
    ?assertEqual(ProvisioningId,
                 maps:get(provisioning_transaction_id, Stored)).

secret_material_is_rejected() ->
    Payload = (delivery(<<"delivery-audit-secret">>, applied, 1))#{
                vpn_result => {ok, #{private_key_pem => <<"SECRET">>}}},
    ?assertEqual(
       {error,
        {forbidden_vpn_delivery_audit_material,
         [vpn_result, 2, private_key_pem]}},
       ias_vpn_provisioning_delivery_store:append(Payload)),
    PemPayload = (delivery(<<"delivery-audit-pem">>, applied, 1))#{
                   vpn_result => <<"-----BEGIN CERTIFICATE-----\nSECRET">>},
    ?assertEqual(
       {error,
        {forbidden_vpn_delivery_audit_material,
         [vpn_result, pem_material]}},
       ias_vpn_provisioning_delivery_store:append(PemPayload)),
    ?assertEqual({ok, 0}, ias_vpn_provisioning_delivery_store:count()).

incompatible_schema_fails_closed() ->
    DeliveryId = <<"bad-delivery-audit-schema">>,
    Record = #ias_vpn_provisioning_delivery_audit{
                delivery_id = DeliveryId,
                schema_version = 999,
                device_id = <<"bad-schema-device">>,
                delivery_status = applied,
                operation = upsert,
                delivered_at = <<"2026-06-27T20:00:00Z">>,
                payload = delivery(<<"bad-schema-device">>, applied, 1)},
    ok = kvs:put(Record),
    ?assertEqual(
       {error, {unsupported_vpn_delivery_audit_schema_version, 999}},
       ias_vpn_provisioning_delivery_store:ensure()),
    ok = kvs:delete(ias_vpn_provisioning_delivery_audit, DeliveryId).

delivery(DeviceId, Status, Revision) ->
    #{device_id => DeviceId,
      peer_id => DeviceId,
      revision => Revision,
      operation => upsert,
      source => ias,
      delivery_status => Status,
      vpn_result => Status,
      delivered_at => <<"2026-06-27T20:00:00Z">>}.
