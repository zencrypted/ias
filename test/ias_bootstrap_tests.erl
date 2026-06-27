-module(ias_bootstrap_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ias_domain_object.hrl").

bootstrap_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun durable_projection_is_rehydrated_before_runtime_start/0,
      fun invalid_durable_state_fails_closed/0]}.

durable_projection_is_rehydrated_before_runtime_start() ->
    DeviceId = <<"bootstrap-rehydrated-device">>,
    _ = ias_demo_store:put_runtime_object(device(DeviceId)),
    {ok, _} = ias_csr_enrollment_state:mark_submitted(
                <<"bootstrap-csr">>,
                #{device_id => DeviceId,
                  public_key_fingerprint => <<"bootstrap-public-key">>}),
    true = ets:delete_all_objects(ias_demo_store),
    true = ets:delete_all_objects(ias_csr_enrollment_state),

    {ok, Health} = ias_bootstrap:prepare(),

    ?assertEqual(synchronized, maps:get(status, Health)),
    ?assertEqual(maps:get(durable_total, Health),
                 maps:get(ets_projection_total, Health)),
    ?assertMatch({ok, #{id := DeviceId, kind := device}},
                 ias_demo_store:get(DeviceId)),
    ?assertMatch({ok, #{status := submitted,
                        device_id := DeviceId}},
                 ias_csr_enrollment_state:get(<<"bootstrap-csr">>)).

invalid_durable_state_fails_closed() ->
    SentinelId = <<"bootstrap-current-projection">>,
    Sentinel = device(SentinelId),
    true = ets:insert(ias_demo_store,
                      {{device, SentinelId}, Sentinel}),
    InvalidId = <<"bootstrap-invalid-schema">>,
    Invalid = #ias_domain_object{
                 key = {device, InvalidId},
                 schema_version = 999,
                 kind = device,
                 object_id = InvalidId,
                 payload = device(InvalidId),
                 revision = 1,
                 created_at = 1,
                 updated_at = 1},
    ok = kvs:put(Invalid),

    ?assertMatch(
       {error,
        {ias_bootstrap_failed,
         domain_store,
         {unsupported_domain_schema_version, 999}}},
       ias_bootstrap:prepare()),
    ?assertMatch({ok, #{id := SentinelId}},
                 ias_demo_store:get(SentinelId)).

setup() ->
    ok = ias_domain_store:ensure(),
    ok = ias_vpn_authority:ensure(),
    ok = ias_vpn_reconciliation_incidents:ensure(),
    ok = ias_csr_enrollment_store:ensure(),
    ok = ias_csr_enrollment_state:clear(),
    ok = ias_demo_store:clear(),
    ok.

cleanup(_State) ->
    _ = kvs:delete(ias_domain_object,
                   {device, <<"bootstrap-invalid-schema">>}),
    ok = ias_csr_enrollment_state:clear(),
    ok = ias_demo_store:clear(),
    ok.

device(Id) ->
    #{id => Id,
      kind => device,
      source => bootstrap_test,
      owner => alice,
      name => <<"Bootstrap device">>,
      type => <<"vpn-client">>,
      endpoint => <<"127.0.0.1:1194">>,
      transport => udp,
      tunnel_device => tun,
      private_key_provider => <<"device_file">>,
      private_key_ref => <<"client.key">>,
      private_key_stored => false,
      certificate_body_stored => false,
      ca_body_stored => false}.
