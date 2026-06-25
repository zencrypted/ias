-module(ias_demo_store_rehydration_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ias_domain_object.hrl").

rehydration_contract_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         {inorder,
          [?_test(objects_and_relationships_are_rehydrated()),
           ?_test(vpn_authority_is_overlaid_during_rehydration()),
           ?_test(rehydration_is_idempotent()),
           ?_test(invalid_durable_state_preserves_current_projection())]}
     end}.

objects_and_relationships_are_rehydrated() ->
    ok = ias_demo_store:clear(),
    Service = service(<<"rehydrate-service">>),
    Certificate = certificate(<<"rehydrate-ca">>),
    Relationship = #{relationship_id => <<"rehydrate-service-ca">>,
                     relation_type => uses_ca_certificate,
                     source_kind => vpn_service,
                     source_id => maps:get(id, Service),
                     target_kind => certificate,
                     target_id => maps:get(id, Certificate)},
    {ok, _Graph} = ias_demo_store:commit_graph(
                     [Service, Certificate], [Relationship]),

    true = ets:delete_all_objects(ias_demo_store),
    Mismatch = ias_demo_store:projection_health(),
    ?assertEqual(mismatch, maps:get(status, Mismatch)),
    ?assertEqual(2, maps:get(durable_objects, Mismatch)),
    ?assertEqual(1, maps:get(durable_relationships, Mismatch)),
    ?assertEqual(0, maps:get(ets_projection_total, Mismatch)),

    {ok, Health} = ias_demo_store:rehydrate(),
    ?assertEqual(synchronized, maps:get(status, Health)),
    ?assertEqual(2, maps:get(ets_projection_objects, Health)),
    ?assertEqual(1, maps:get(ets_projection_relationships, Health)),
    ?assert(is_binary(maps:get(last_rehydrated_at, Health))),
    ?assertMatch({ok, #{id := <<"rehydrate-service">>}},
                 ias_demo_store:get(<<"rehydrate-service">>)),
    ?assertMatch({ok, #{id := <<"rehydrate-ca">>}},
                 ias_demo_store:get(<<"rehydrate-ca">>)),
    ?assertMatch({ok, #{id := <<"rehydrate-service-ca">>}},
                 ias_demo_store:get(<<"rehydrate-service-ca">>)).

vpn_authority_is_overlaid_during_rehydration() ->
    ok = ias_demo_store:clear(),
    DeviceId = <<"rehydrate-authority-device">>,
    Base = device(DeviceId),
    _ = ias_demo_store:put_runtime_object(Base),
    ok = ias_vpn_authority:sync_device(maps:merge(Base, active_binding())),

    true = ets:delete_all_objects(ias_demo_store),
    {ok, _Health} = ias_demo_store:rehydrate(),
    {ok, Restored} = ias_demo_store:get(DeviceId),
    ?assertEqual(<<"rehydrate-client-peer">>,
                 maps:get(runtime_peer_id, Restored)),
    ?assertEqual(<<"rehydrate-allocation">>,
                 maps:get(vpn_allocation_id, Restored)),
    ?assertEqual(established,
                 maps:get(vpn_dynamic_pair_state, Restored)).

rehydration_is_idempotent() ->
    ok = ias_demo_store:clear(),
    DeviceId = <<"rehydrate-idempotent-device">>,
    _ = ias_demo_store:put_runtime_object(device(DeviceId)),
    true = ets:delete_all_objects(ias_demo_store),

    {ok, FirstHealth} = ias_demo_store:rehydrate(),
    FirstProjection = ias_demo_store:runtime_objects(),
    {ok, SecondHealth} = ias_demo_store:rehydrate(),
    SecondProjection = ias_demo_store:runtime_objects(),

    ?assertEqual(FirstProjection, SecondProjection),
    ?assertEqual(1, length(SecondProjection)),
    ?assertEqual(synchronized, maps:get(status, FirstHealth)),
    ?assertEqual(synchronized, maps:get(status, SecondHealth)),
    ?assertEqual(undefined,
                 maps:get(last_rehydration_error, SecondHealth)).

invalid_durable_state_preserves_current_projection() ->
    ok = ias_demo_store:clear(),
    SentinelId = <<"rehydrate-current-sentinel">>,
    Sentinel = device(SentinelId),
    true = ets:insert(ias_demo_store,
                      {{device, SentinelId}, Sentinel}),
    InvalidId = <<"rehydrate-invalid-schema">>,
    ok = kvs:put(
           #ias_domain_object{key = {device, InvalidId},
                              schema_version = 99,
                              kind = device,
                              object_id = InvalidId,
                              payload = device(InvalidId),
                              revision = 1,
                              created_at = 1,
                              updated_at = 1}),

    Before = ias_demo_store:runtime_objects(),
    ?assertEqual({error, {unsupported_domain_schema_version, 99}},
                 ias_demo_store:rehydrate()),
    ?assertEqual(Before, ias_demo_store:runtime_objects()),
    ?assertMatch({ok, #{id := SentinelId}},
                 ias_demo_store:get(SentinelId)),
    Health = ias_demo_store:projection_health(),
    ?assertEqual(unavailable, maps:get(status, Health)),
    ?assertEqual({unsupported_domain_schema_version, 99},
                 maps:get(last_rehydration_error, Health)),

    ok = kvs:delete(ias_domain_object, {device, InvalidId}).

setup() ->
    ok = ias_demo_store:clear(),
    ok.

cleanup(_Context) ->
    _ = catch kvs:delete(ias_domain_object,
                         {device, <<"rehydrate-invalid-schema">>}),
    ok = ias_demo_store:clear().

device(Id) ->
    #{id => Id,
      kind => device,
      source => rehydration_test,
      owner => alice,
      name => <<"Rehydrated device">>,
      type => <<"vpn-client">>,
      endpoint => <<"127.0.0.1:1194">>,
      transport => udp,
      tunnel_device => tun,
      private_key_provider => <<"device_file">>,
      private_key_ref => <<"client.key">>,
      private_key_stored => false,
      certificate_body_stored => false,
      ca_body_stored => false}.

service(Id) ->
    #{id => Id,
      kind => vpn_service,
      source => rehydration_test,
      service => openvpn,
      remote => <<"127.0.0.1:1194">>,
      protocol => udp,
      private_key_stored => false,
      certificate_body_stored => false}.

certificate(Id) ->
    #{id => Id,
      kind => certificate,
      source => rehydration_test,
      subject => <<"CN=Rehydration Test CA">>,
      issuer => <<"CN=Rehydration Test CA">>,
      certificate_role => ca_certificate,
      certificate_status => trusted,
      private_key_stored => false,
      certificate_body_stored => false}.

active_binding() ->
    #{runtime_peer_id => <<"rehydrate-client-peer">>,
      vpn_peer => <<"rehydrate-client-peer">>,
      vpn_allocation_id => <<"rehydrate-allocation">>,
      vpn_allocator_instance_id => <<"rehydrate-allocator">>,
      vpn_client_peer_id => <<"rehydrate-client-peer">>,
      vpn_gateway_peer_id => <<"rehydrate-gateway-peer">>,
      vpn_allocation_slot => 1,
      vpn_allocation_generation => 1,
      vpn_allocation_state => reserved,
      vpn_allocation_persistence => durable,
      vpn_allocation_created_at => 1782397000,
      vpn_dynamic_pair_state => established,
      vpn_dynamic_pair_reconciled_at => 1782397001,
      vpn_runtime_certificate_fingerprint =>
          <<"0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF">>}.
