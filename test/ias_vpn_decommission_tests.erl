-module(ias_vpn_decommission_tests).
-include_lib("eunit/include/eunit.hrl").

decommission_clears_binding_and_preserves_audit_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Context) ->
         fun() ->
             DeviceId = maps:get(device_id, Context),
             WizardId = maps:get(wizard_id, Context),
             {ok, Result} = ias_vpn_access_lifecycle:decommission(
                              DeviceId,
                              #{remove_identity => true}),
             ?assertEqual(decommission, maps:get(operation, Result)),
             ?assertEqual(allocation_id(), maps:get(allocation_id, Result)),
             ?assertEqual(client_peer_id(), maps:get(client_peer_id, Result)),
             ?assertEqual(gateway_peer_id(), maps:get(gateway_peer_id, Result)),
             ?assertEqual(released, maps:get(allocation_state, Result)),
             ?assertEqual(removed, maps:get(registry_state, Result)),
             ?assertEqual(removed, maps:get(identity_state, Result)),
             ?assertEqual(1, maps:get(wizard_drafts_cleared, Result)),
             receive
                 {decommission_rpc, 30000, #{remove_identity := true}} -> ok
             after 0 ->
                 ?assert(false)
             end,

             {ok, StoredDevice} = ias_demo_store:get(DeviceId),
             lists:foreach(
               fun(Key) -> ?assertEqual(false, maps:is_key(Key, StoredDevice)) end,
               active_binding_fields()),
             Audit = maps:get(vpn_last_decommission, StoredDevice),
             ?assertEqual(allocation_id(), maps:get(allocation_id, Audit)),
             ?assertEqual(removed, maps:get(identity_state, Audit)),
             [Audit] = maps:get(vpn_decommission_history, StoredDevice),

             Status = ias_vpn_access_lifecycle:status(DeviceId),
             ?assertEqual(undefined, maps:get(runtime_peer_id, Status)),
             ?assertEqual(not_bound, maps:get(runtime, Status)),
             ?assertEqual(undefined, maps:get(allocation, Status)),
             ?assertEqual(decommissioned, maps:get(binding_mode, Status)),
             ?assertEqual(Audit, maps:get(decommission, Status)),

             {ok, Draft} = ias_provisioning_wizard_store:get(WizardId),
             lists:foreach(
               fun(Key) -> ?assertEqual(undefined, maps:get(Key, Draft, undefined)) end,
               draft_allocation_fields()),

             Text = iolist_to_binary(io_lib:format("~p ~p", [Result, StoredDevice])),
             ?assertEqual(nomatch, binary:match(Text, <<"private_key">>)),
             ?assertEqual(nomatch, binary:match(Text, <<"must-not-leak">>)),

             Snapshot = ias_demo_state:export(),
             ok = ias_demo_state:clear(),
             _ = ias_demo_state:import(Snapshot),
             {ok, RestoredDevice} = ias_demo_store:get(DeviceId),
             ?assertEqual(Audit,
                          maps:get(vpn_last_decommission, RestoredDevice)),
             ?assertEqual([Audit],
                          maps:get(vpn_decommission_history, RestoredDevice)),
             ?assertEqual({error, dynamic_vpn_allocation_required},
                          ias_vpn_access_lifecycle:decommission(DeviceId))
         end
     end}.

invalid_decommission_summary_keeps_binding_test_() ->
    {setup,
     fun setup_invalid_summary/0,
     fun cleanup/1,
     fun(Context) ->
         fun() ->
             DeviceId = maps:get(device_id, Context),
             ?assertEqual({error, invalid_vpn_decommission_summary},
                          ias_vpn_access_lifecycle:decommission(DeviceId)),
             {ok, StoredDevice} = ias_demo_store:get(DeviceId),
             ?assertEqual(allocation_id(),
                          maps:get(vpn_allocation_id, StoredDevice)),
             ?assertEqual(client_peer_id(),
                          maps:get(runtime_peer_id, StoredDevice)),
             ?assertEqual(false,
                          maps:is_key(vpn_last_decommission, StoredDevice))
         end
     end}.

setup() ->
    setup_with_rpc(fun decommission_rpc/5).

setup_invalid_summary() ->
    setup_with_rpc(fun invalid_summary_rpc/5).

setup_with_rpc(RpcFun) ->
    PreviousTransport = application:get_env(ias, vpn_provisioning_transport),
    PreviousNode = application:get_env(ias, vpn_provisioning_vpn_node),
    PreviousRpcFun = application:get_env(ias, vpn_provisioning_rpc_fun),
    PreviousPairTimeout = application:get_env(ias, vpn_dynamic_pair_rpc_timeout),
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    ias_vpn_provisioning_state:reset(),
    ias_vpn_provisioning_delivery:reset(),
    DeviceId = <<"decommission-device">>,
    Device = ias_demo_store:put_runtime_object(
               maps:merge(
                 #{id => DeviceId,
                   kind => device,
                   owner => bob,
                   peer_id => DeviceId,
                   runtime_peer_id => client_peer_id(),
                   vpn_peer => client_peer_id(),
                   vpn_runtime_certificate_fingerprint => <<"SAFE-FINGERPRINT">>,
                   vpn_dynamic_pair_state => established,
                   vpn_dynamic_pair_reconciled_at => 1782301000,
                   source => manual_device},
                 allocation_fields())),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft} = ias_provisioning_wizard_store:update(
                    maps:get(id, Draft0),
                    maps:merge(#{device_id => DeviceId,
                                 user_id => bob},
                               draft_allocation_updates())),
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(ias, vpn_provisioning_vpn_node, 'vpn-test@127.0.0.1'),
    application:set_env(ias, vpn_dynamic_pair_rpc_timeout, 30000),
    application:set_env(ias, vpn_provisioning_rpc_fun, RpcFun),
    #{device_id => maps:get(id, Device),
      wizard_id => maps:get(id, Draft),
      previous_transport => PreviousTransport,
      previous_node => PreviousNode,
      previous_rpc_fun => PreviousRpcFun,
      previous_pair_timeout => PreviousPairTimeout}.

cleanup(Context) ->
    restore_env(vpn_provisioning_transport, maps:get(previous_transport, Context)),
    restore_env(vpn_provisioning_vpn_node, maps:get(previous_node, Context)),
    restore_env(vpn_provisioning_rpc_fun, maps:get(previous_rpc_fun, Context)),
    restore_env(vpn_dynamic_pair_rpc_timeout,
                maps:get(previous_pair_timeout, Context)),
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    ias_vpn_provisioning_state:reset(),
    ias_vpn_provisioning_delivery:reset().

decommission_rpc(_Node,
                 vpn_dynamic_pair,
                 decommission,
                 [<<"decommission-device">>, Options],
                 Timeout) ->
    self() ! {decommission_rpc, Timeout, Options},
    {ok, (decommission_summary())#{private_key_path => <<"must-not-leak">>,
                                 ovpn => <<"must-not-leak">>}};
decommission_rpc(_Node, _Module, _Function, _Args, _Timeout) ->
    {error, unsupported_call}.

invalid_summary_rpc(_Node,
                    vpn_dynamic_pair,
                    decommission,
                    [<<"decommission-device">>, _Options],
                    _Timeout) ->
    {ok, (decommission_summary())#{allocation_id => <<"other-allocation">>}};
invalid_summary_rpc(_Node, _Module, _Function, _Args, _Timeout) ->
    {error, unsupported_call}.

decommission_summary() ->
    #{device_id => <<"decommission-device">>,
      allocation_id => allocation_id(),
      allocator_instance_id => <<"allocator-decommission-test">>,
      slot => 8,
      generation => 14,
      client_peer_id => client_peer_id(),
      gateway_peer_id => gateway_peer_id(),
      state => decommissioned,
      allocation_state => released,
      registry_state => removed,
      persistence => volatile,
      identity_state => removed,
      decommissioned_at => 1782301100}.

allocation_fields() ->
    #{vpn_allocation_id => allocation_id(),
      vpn_allocator_instance_id => <<"allocator-decommission-test">>,
      vpn_client_peer_id => client_peer_id(),
      vpn_gateway_peer_id => gateway_peer_id(),
      vpn_allocation_slot => 8,
      vpn_allocation_generation => 14,
      vpn_allocation_state => reserved,
      vpn_allocation_persistence => volatile,
      vpn_allocation_created_at => 1782300000}.

draft_allocation_updates() ->
    allocation_fields().

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

draft_allocation_fields() ->
    [vpn_allocation_id,
     vpn_allocator_instance_id,
     vpn_client_peer_id,
     vpn_gateway_peer_id,
     vpn_allocation_slot,
     vpn_allocation_generation,
     vpn_allocation_state,
     vpn_allocation_persistence,
     vpn_allocation_created_at].

allocation_id() -> <<"dynamic-vpn-decommission-test">>.
client_peer_id() -> <<"client_dyn_decommission_test">>.
gateway_peer_id() -> <<"gateway_dyn_decommission_test">>.

restore_env(Key, {ok, Value}) ->
    application:set_env(ias, Key, Value);
restore_env(Key, undefined) ->
    application:unset_env(ias, Key).
