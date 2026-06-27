-module(ias_vpn_authority_tests).
-include_lib("eunit/include/eunit.hrl").
-include("ias_vpn_authority.hrl").
-include_lib("kvs/include/metainfo.hrl").

durable_revision_and_binding_overlay_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device_id := DeviceId}) ->
         fun() ->
             Device0 = base_device(DeviceId),
             Device = ias_demo_store:put_runtime_object(
                        maps:merge(Device0, active_binding())),
             Command0 = command(DeviceId, upsert, true),
             {ok, Command1, changed} =
                 ias_vpn_provisioning_state:prepare(DeviceId, Command0),
             ?assertEqual(1, maps:get(revision, Command1)),

             %% Simulate loss of the volatile object store without touching KVS/Mnesia.
             true = ets:delete_all_objects(ias_demo_store),
             _ = ias_demo_store:add_device(Device0),

             {ok, Restored} = ias_demo_store:get(DeviceId),
             ?assertEqual(maps:get(vpn_allocation_id, Device),
                          maps:get(vpn_allocation_id, Restored)),
             ?assertEqual(maps:get(vpn_client_peer_id, Device),
                          maps:get(runtime_peer_id, Restored)),
             ?assertEqual(established,
                          maps:get(vpn_dynamic_pair_state, Restored)),

             {ok, Command1, unchanged} =
                 ias_vpn_provisioning_state:prepare(DeviceId, Command0),
             {ok, Command2, changed} =
                 ias_vpn_provisioning_state:prepare(
                   DeviceId,
                   command(DeviceId, disable, false)),
             ?assertEqual(2, maps:get(revision, Command2)),
             ?assertEqual(2,
                          ias_vpn_provisioning_state:current_revision(DeviceId)),

             {ok, Authority} = ias_vpn_authority:get(DeviceId),
             ?assertEqual(durable,
                          maps:get(persistence,
                                   ias_vpn_provisioning_state:status())),
             ?assertEqual(disabled, maps:get(lifecycle_state, Authority)),
             ?assertEqual(32,
                          byte_size(maps:get(command_digest, Authority))),
             ?assertEqual(Command2,
                          maps:get(canonical_command, Authority)),
             #table{copy_type = disc_copies,
                    type = set} = kvs:table(ias_vpn_device_state),
             ok = ias_vpn_provisioning_state:reset(),
             ?assertEqual(0,
                          ias_vpn_provisioning_state:current_revision(DeviceId)),
             {ok, BindingStillPresent} = ias_demo_store:get(DeviceId),
             ?assertEqual(maps:get(vpn_allocation_id, Device),
                          maps:get(vpn_allocation_id, BindingStillPresent))
         end
     end}.

durable_decommission_overlay_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device_id := DeviceId}) ->
         fun() ->
             Device = ias_demo_store:put_runtime_object(
                        maps:merge(base_device(DeviceId), active_binding())),
             Summary = decommission_summary(DeviceId),
             Cleared = maps:without(active_binding_fields(), Device),
             _ = ias_demo_store:put_runtime_object(
                   Cleared#{vpn_last_decommission => Summary,
                            vpn_decommission_history => [Summary],
                            vpn_decommissioned_at => 1782330000}),

             true = ets:delete_all_objects(ias_demo_store),
             _ = ias_demo_store:add_device(base_device(DeviceId)),

             {ok, Restored} = ias_demo_store:get(DeviceId),
             ?assertEqual(false,
                          maps:is_key(vpn_allocation_id, Restored)),
             ?assertEqual(Summary,
                          maps:get(vpn_last_decommission, Restored)),
             ?assertEqual([Summary],
                          maps:get(vpn_decommission_history, Restored)),
             {ok, Authority} = ias_vpn_authority:get(DeviceId),
             ?assertEqual(decommissioned,
                          maps:get(lifecycle_state, Authority)),
             ?assertEqual(#{}, maps:get(binding, Authority))
         end
     end}.

unsupported_authority_schema_fails_closed_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device_id := DeviceId}) ->
         fun() ->
             ok = ias_vpn_authority:reset(),
             ok = kvs:put(
                    #ias_vpn_device_state{device_id = DeviceId,
                                          schema_version = 99,
                                          updated_at = 1782330100}),
             ?assertEqual(
                {error, {unsupported_vpn_authority_schema_version, 99}},
                ias_vpn_authority:ensure())
         end
     end}.

unsafe_authority_material_is_rejected_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device_id := DeviceId}) ->
         fun() ->
             ?assertEqual(
                {error, invalid_vpn_device_authority_state},
                ias_vpn_authority:sync_device(
                  (base_device(DeviceId))#{
                    vpn_last_decommission =>
                        #{device_id => DeviceId,
                          private_key_path => <<"must-not-persist">>}})),
             ?assertEqual(
                {error, unsafe_vpn_provisioning_command},
                ias_vpn_authority:prepare(
                  DeviceId,
                  (command(DeviceId, upsert, true))#{
                    runtime_config => #{psk => <<"must-not-persist">>}}))
         end
     end}.

setup() ->
    ok = ias_demo_store:clear(),
    ok = ias_vpn_provisioning_state:reset(),
    DeviceId = <<"vpn-authority-device">>,
    _ = ias_demo_store:add_device(base_device(DeviceId)),
    #{device_id => DeviceId}.

cleanup(_Context) ->
    ok = ias_demo_store:clear(),
    ok = ias_vpn_provisioning_state:reset().

base_device(DeviceId) ->
    #{id => DeviceId,
      kind => device,
      owner => alice,
      source => manual_device}.

active_binding() ->
    #{runtime_peer_id => <<"client_dyn_authority_1">>,
      vpn_peer => <<"client_dyn_authority_1">>,
      vpn_allocation_id => <<"dynamic-vpn-authority-1">>,
      vpn_allocator_instance_id => <<"allocator-authority">>,
      vpn_client_peer_id => <<"client_dyn_authority_1">>,
      vpn_gateway_peer_id => <<"gateway_dyn_authority_1">>,
      vpn_allocation_slot => 1,
      vpn_allocation_generation => 3,
      vpn_allocation_state => reserved,
      vpn_allocation_persistence => durable,
      vpn_allocation_created_at => 1782329000,
      vpn_dynamic_pair_state => established,
      vpn_dynamic_pair_reconciled_at => 1782329100,
      vpn_runtime_certificate_fingerprint =>
          <<"0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF">>}.

active_binding_fields() ->
    [runtime_peer_id,
     vpn_peer,
     vpn_allocation_id,
     vpn_allocator_instance_id,
     vpn_client_peer_id,
     vpn_gateway_peer_id,
     vpn_allocation_slot,
     vpn_allocation_generation,
     vpn_allocation_state,
     vpn_allocation_persistence,
     vpn_allocation_created_at,
     vpn_dynamic_pair_state,
     vpn_dynamic_pair_reconciled_at,
     vpn_runtime_certificate_fingerprint].

command(DeviceId, Operation, Enabled) ->
    #{peer_id => <<"client_dyn_authority_1">>,
      operation => Operation,
      source => ias,
      desired_state => #{device_id => DeviceId,
                         enabled => Enabled,
                         authorized => Enabled,
                         authorization_mode => policy,
                         authorization_reason => authority_test,
                         profile_id => default_user}}.

decommission_summary(DeviceId) ->
    #{device_id => DeviceId,
      allocation_id => <<"dynamic-vpn-authority-1">>,
      allocator_instance_id => <<"allocator-authority">>,
      slot => 1,
      generation => 3,
      client_peer_id => <<"client_dyn_authority_1">>,
      gateway_peer_id => <<"gateway_dyn_authority_1">>,
      state => decommissioned,
      allocation_state => released,
      registry_state => removed,
      persistence => durable,
      identity_state => retained,
      decommissioned_at => 1782330000,
      ias_recorded_at => 1782330001}.
