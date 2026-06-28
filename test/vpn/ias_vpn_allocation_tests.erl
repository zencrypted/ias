-module(ias_vpn_allocation_tests).
-include_lib("eunit/include/eunit.hrl").

allocation_metadata_is_reserved_and_persisted_test() ->
    Previous = save_env(),
    try
        prepare_env(),
        DeviceId = <<"allocation-device">>,
        _ = ias_demo_store:add_device(#{id => DeviceId,
                                        owner => alice,
                                        source => manual_device}),
        Allocation = allocation(DeviceId),
        application:set_env(ias, vpn_provisioning_rpc_fun,
                            rpc_fun(Allocation)),

        {ok, Safe} = ias_vpn_allocation:ensure(DeviceId),

        ?assertEqual(maps:get(allocation_id, Allocation),
                     maps:get(allocation_id, Safe)),
        ?assertEqual(maps:get(client_peer_id, Allocation),
                     maps:get(client_peer_id, Safe)),
        ?assertEqual(maps:get(gateway_peer_id, Allocation),
                     maps:get(gateway_peer_id, Safe)),
        ?assertEqual(false, maps:is_key(client, Safe)),
        ?assertEqual(false, maps:is_key(gateway, Safe)),
        ?assertEqual(false, maps:is_key(private_key_path, Safe)),

        {ok, StoredDevice} = ias_demo_store:get(DeviceId),
        ?assertEqual(maps:get(allocation_id, Allocation),
                     maps:get(vpn_allocation_id, StoredDevice)),
        ?assertEqual(maps:get(client_peer_id, Allocation),
                     maps:get(vpn_client_peer_id, StoredDevice)),
        ?assertEqual(maps:get(gateway_peer_id, Allocation),
                     maps:get(vpn_gateway_peer_id, StoredDevice)),
        ?assertEqual(reserved, maps:get(vpn_allocation_state, StoredDevice)),
        ?assertEqual(undefined,
                     maps:get(runtime_peer_id, StoredDevice, undefined)),

        {ok, LookedUp} = ias_vpn_allocation:lookup(DeviceId),
        ?assertEqual(Safe, LookedUp)
    after
        cleanup_env(Previous)
    end.

allocation_device_mismatch_is_rejected_test() ->
    Previous = save_env(),
    try
        prepare_env(),
        DeviceId = <<"allocation-mismatch-device">>,
        _ = ias_demo_store:add_device(#{id => DeviceId,
                                        source => manual_device}),
        Mismatched = allocation(<<"other-device">>),
        application:set_env(ias, vpn_provisioning_rpc_fun,
                            rpc_fun(Mismatched)),

        ?assertEqual({error, invalid_vpn_allocation},
                     ias_vpn_allocation:ensure(DeviceId)),
        {ok, StoredDevice} = ias_demo_store:get(DeviceId),
        ?assertEqual(undefined,
                     maps:get(vpn_allocation_id, StoredDevice, undefined))
    after
        cleanup_env(Previous)
    end.

csr_plan_reserves_allocation_without_runtime_cutover_test() ->
    Previous = save_env(),
    try
        prepare_env(),
        DeviceId = <<"wizard-allocation-device">>,
        Device = ias_demo_store:put_runtime_object(
                   #{id => DeviceId,
                     kind => device,
                     source => manual_device,
                     owner => alice,
                     name => <<"Wizard Allocation Device">>,
                     type => <<"vpn-client">>,
                     tunnel_device => <<"tun">>,
                     transport => <<"udp">>,
                     endpoint => <<"vpn.example.com">>,
                     private_key_provider => <<"device_file">>,
                     private_key_ref => <<"client.key">>}),
        Allocation = allocation(DeviceId),
        application:set_env(ias, vpn_provisioning_rpc_fun,
                            rpc_fun(Allocation)),
        {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
        {ok, Draft1} = ias_provisioning_wizard_store:update(
                         maps:get(id, Draft0),
                         #{current_step => client_certificate,
                           device_id => maps:get(id, Device)}),

        {ok, Prepared} = ias_provisioning_wizard_store:prepare_device_csr_plan(
                           maps:get(id, Draft1)),

        ?assertEqual(maps:get(allocation_id, Allocation),
                     maps:get(vpn_allocation_id, Prepared)),
        ?assertEqual(maps:get(client_peer_id, Allocation),
                     maps:get(vpn_client_peer_id, Prepared)),
        ?assertEqual(maps:get(gateway_peer_id, Allocation),
                     maps:get(vpn_gateway_peer_id, Prepared)),
        ?assertEqual(reserved, maps:get(vpn_allocation_state, Prepared)),
        ?assertMatch(<<"keys/wizard-allocation-device-", _/binary>>,
                     maps:get(pending_private_key_reference, Prepared)),

        {ok, StoredDevice} = ias_demo_store:get(DeviceId),
        ?assertEqual(maps:get(allocation_id, Allocation),
                     maps:get(vpn_allocation_id, StoredDevice)),
        ?assertEqual(undefined,
                     maps:get(runtime_peer_id, StoredDevice, undefined)),
        ?assertEqual(undefined,
                     maps:get(vpn_peer, StoredDevice, undefined)),

        {ok, Regenerated} =
            ias_provisioning_wizard_store:regenerate_device_csr_plan(
              maps:get(id, Prepared)),
        ?assertEqual(maps:get(vpn_allocation_id, Prepared),
                     maps:get(vpn_allocation_id, Regenerated)),
        ?assertEqual(maps:get(vpn_client_peer_id, Prepared),
                     maps:get(vpn_client_peer_id, Regenerated))
    after
        cleanup_env(Previous)
    end.

reservation_can_be_disabled_without_rpc_test() ->
    Previous = save_env(),
    try
        ias_demo_store:clear(),
        application:set_env(ias, vpn_dynamic_allocation_reservation, false),
        application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
        application:set_env(
          ias,
          vpn_provisioning_rpc_fun,
          fun(_Node, _Module, _Function, _Args, _Timeout) ->
                  error(unexpected_rpc_call)
          end),
        DeviceId = <<"allocation-disabled-device">>,
        _ = ias_demo_store:add_device(#{id => DeviceId,
                                        source => manual_device}),
        ?assertEqual(disabled, ias_vpn_allocation:ensure(DeviceId))
    after
        cleanup_env(Previous)
    end.

allocation(DeviceId) ->
    #{allocation_id => <<"dynamic-vpn-3-instance123456-9">>,
      allocator_instance_id => <<"instance123456">>,
      device_id => DeviceId,
      client_peer_id => <<"client_dyn_3_instance123456_9">>,
      gateway_peer_id => <<"gateway_dyn_3_instance123456_9">>,
      slot => 3,
      generation => 9,
      state => reserved,
      persistence => volatile,
      created_at => 1782288000,
      client => #{local_udp_port => 20002,
                  private_key_path => <<"must-not-cross-rpc-boundary">>},
      gateway => #{local_udp_port => 30002}}.

rpc_fun(Allocation) ->
    fun(_Node, vpn_peer_allocator, ensure, [_DeviceId], _Timeout) ->
            {ok, Allocation};
       (_Node, vpn_peer_allocator, lookup, [_DeviceId], _Timeout) ->
            {ok, Allocation};
       (_Node, _Module, _Function, _Args, _Timeout) ->
            {error, unsupported_call}
    end.

prepare_env() ->
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    application:set_env(ias, vpn_dynamic_allocation_reservation, true),
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(ias, vpn_provisioning_vpn_node,
                        'vpn-allocation-test@127.0.0.1'),
    application:set_env(ias, vpn_provisioning_rpc_timeout, 1234).

save_env() ->
    #{enabled => application:get_env(ias, vpn_dynamic_allocation_reservation),
      transport => application:get_env(ias, vpn_provisioning_transport),
      node => application:get_env(ias, vpn_provisioning_vpn_node),
      timeout => application:get_env(ias, vpn_provisioning_rpc_timeout),
      rpc_fun => application:get_env(ias, vpn_provisioning_rpc_fun)}.

cleanup_env(Previous) ->
    restore_env(vpn_dynamic_allocation_reservation,
                maps:get(enabled, Previous)),
    restore_env(vpn_provisioning_transport, maps:get(transport, Previous)),
    restore_env(vpn_provisioning_vpn_node, maps:get(node, Previous)),
    restore_env(vpn_provisioning_rpc_timeout, maps:get(timeout, Previous)),
    restore_env(vpn_provisioning_rpc_fun, maps:get(rpc_fun, Previous)),
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear().

restore_env(Key, {ok, Value}) -> application:set_env(ias, Key, Value);
restore_env(Key, undefined) -> application:unset_env(ias, Key).
