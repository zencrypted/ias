-module(ias_persistence_policy_tests).

-include_lib("eunit/include/eunit.hrl").

persistence_policy_classifies_durable_and_volatile_stores_test() ->
    Stores = ias_persistence_policy:stores(),
    ?assertMatch(#{mode := durable, backend := kvs},
                 store(ias_domain_store, Stores)),
    ?assertMatch(#{mode := durable, backend := kvs},
                 store(ias_provisioning_wizard_draft_store, Stores)),
    ?assertMatch(#{mode := durable_append_only, backend := kvs},
                 store(ias_vpn_provisioning_delivery_store, Stores)),
    ?assertMatch(#{mode := volatile, backend := ets},
                 store(ias_certificate_material, Stores)),
    ?assertMatch(#{mode := volatile, backend := ets},
                 store(ias_csr_enrollment_state, Stores)),
    ?assertMatch(#{mode := volatile, backend := process_memory},
                 store(ias_vpn_event_bridge, Stores)).

persistence_diagnostics_report_delivery_projection_test() ->
    ok = ias_vpn_provisioning_delivery_store:ensure(),
    ok = ias_vpn_provisioning_delivery:reset(),
    Diagnostics0 = ias_persistence_policy:diagnostics(),
    ?assertEqual(0, maps:get(durable_delivery_audit_entries, Diagnostics0)),
    ?assertEqual(0, maps:get(ets_delivery_audit_entries, Diagnostics0)),
    {ok, _} = ias_vpn_provisioning_delivery_store:append(
                #{device_id => <<"policy-diagnostic-device">>,
                  peer_id => <<"policy-diagnostic-device">>,
                  revision => 1,
                  operation => upsert,
                  source => ias,
                  delivery_status => applied,
                  vpn_result => applied,
                  delivered_at => <<"2026-06-27T20:00:00Z">>}),
    Diagnostics1 = ias_persistence_policy:diagnostics(),
    ?assertEqual(1, maps:get(durable_delivery_audit_entries, Diagnostics1)),
    ?assertEqual(0, maps:get(ets_delivery_audit_entries, Diagnostics1)),
    ?assertEqual({ok, 1}, ias_vpn_provisioning_delivery:rehydrate()),
    Diagnostics2 = ias_persistence_policy:diagnostics(),
    ?assertEqual(1, maps:get(ets_delivery_audit_entries, Diagnostics2)),
    ok = ias_vpn_provisioning_delivery:reset().

store(Name, Stores) ->
    [Store] = [Candidate || Candidate <- Stores,
                           maps:get(store, Candidate) =:= Name],
    Store.
