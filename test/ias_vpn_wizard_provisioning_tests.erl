-module(ias_vpn_wizard_provisioning_tests).
-include_lib("eunit/include/eunit.hrl").

user_runtime_slots_are_selected_test() ->
    PreviousSlots = application:get_env(ias, vpn_provisioning_runtime_peer_slots),
    PreviousDefault = application:get_env(ias, vpn_provisioning_runtime_peer_id),
    try
        application:set_env(ias, vpn_provisioning_runtime_peer_slots,
                            #{alice => client_a, bob => client_b}),
        application:set_env(ias, vpn_provisioning_runtime_peer_id, client_a),
        Device = #{id => device_1, kind => device},
        ?assertEqual(client_a,
                     ias_vpn_wizard_provisioning:runtime_peer_id(
                       Device, #{user_id => alice})),
        ?assertEqual(client_b,
                     ias_vpn_wizard_provisioning:runtime_peer_id(
                       Device, #{user_id => bob}))
    after
        restore_env(vpn_provisioning_runtime_peer_slots, PreviousSlots),
        restore_env(vpn_provisioning_runtime_peer_id, PreviousDefault)
    end.

existing_device_slot_is_stable_test() ->
    PreviousSlots = application:get_env(ias, vpn_provisioning_runtime_peer_slots),
    try
        application:set_env(ias, vpn_provisioning_runtime_peer_slots,
                            #{alice => client_a, bob => client_b}),
        Device = #{id => device_1, kind => device, runtime_peer_id => client_a},
        ?assertEqual(client_a,
                     ias_vpn_wizard_provisioning:runtime_peer_id(
                       Device, #{user_id => bob}))
    after
        restore_env(vpn_provisioning_runtime_peer_slots, PreviousSlots)
    end.

legacy_default_slot_is_preserved_test() ->
    PreviousSlots = application:get_env(ias, vpn_provisioning_runtime_peer_slots),
    PreviousDefault = application:get_env(ias, vpn_provisioning_runtime_peer_id),
    try
        application:unset_env(ias, vpn_provisioning_runtime_peer_slots),
        application:set_env(ias, vpn_provisioning_runtime_peer_id, client_a),
        Device = #{id => device_1, kind => device},
        ?assertEqual(client_a,
                     ias_vpn_wizard_provisioning:runtime_peer_id(
                       Device, #{user_id => unknown_user}))
    after
        restore_env(vpn_provisioning_runtime_peer_slots, PreviousSlots),
        restore_env(vpn_provisioning_runtime_peer_id, PreviousDefault)
    end.

dynamic_allocation_precedes_static_runtime_slots_test() ->
    PreviousEnabled = application:get_env(ias, vpn_dynamic_pair_delivery),
    PreviousSlots = application:get_env(ias, vpn_provisioning_runtime_peer_slots),
    try
        application:set_env(ias, vpn_dynamic_pair_delivery, true),
        application:set_env(ias, vpn_provisioning_runtime_peer_slots,
                            #{alice => client_a, bob => client_b}),
        DynamicPeerId = <<"client_dyn_1_instance_1">>,
        Device = #{id => device_1,
                   kind => device,
                   runtime_peer_id => client_a,
                   vpn_client_peer_id => DynamicPeerId},
        ?assertEqual(DynamicPeerId,
                     ias_vpn_wizard_provisioning:runtime_peer_id(
                       Device, #{user_id => alice}))
    after
        restore_env(vpn_dynamic_pair_delivery, PreviousEnabled),
        restore_env(vpn_provisioning_runtime_peer_slots, PreviousSlots)
    end.

restore_env(Key, {ok, Value}) -> application:set_env(ias, Key, Value);
restore_env(Key, undefined) -> application:unset_env(ias, Key).
