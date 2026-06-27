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
    ?assertMatch(#{mode := durable, backend := kvs,
                   runtime_projection := ets},
                 store(ias_certificate_material_store, Stores)),
    ?assertMatch(#{mode := durable, backend := kvs,
                   runtime_projection := ets},
                 store(ias_csr_enrollment_store, Stores)),
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


persistence_diagnostics_report_csr_enrollment_projection_test() ->
    ok = ias_csr_enrollment_store:ensure(),
    ok = ias_csr_enrollment_state:clear(),
    Diagnostics0 = ias_persistence_policy:diagnostics(),
    ?assertEqual(0, maps:get(durable_csr_enrollment_states, Diagnostics0)),
    ?assertEqual(0, maps:get(ets_csr_enrollment_states, Diagnostics0)),
    {ok, _} = ias_csr_enrollment_state:mark_submitted(
                <<"policy-csr-state">>,
                #{device_id => <<"policy-csr-device">>}),
    Diagnostics1 = ias_persistence_policy:diagnostics(),
    ?assertEqual(1, maps:get(durable_csr_enrollment_states, Diagnostics1)),
    ?assertEqual(1, maps:get(ets_csr_enrollment_states, Diagnostics1)),
    true = ets:delete_all_objects(ias_csr_enrollment_state),
    Diagnostics2 = ias_persistence_policy:diagnostics(),
    ?assertEqual(1, maps:get(durable_csr_enrollment_states, Diagnostics2)),
    ?assertEqual(0, maps:get(ets_csr_enrollment_states, Diagnostics2)),
    ?assertEqual({ok, 1}, ias_csr_enrollment_state:rehydrate()),
    ok = ias_csr_enrollment_state:clear().


persistence_diagnostics_report_certificate_material_projection_test() ->
    ok = ias_certificate_material_store:ensure(),
    ok = ias_certificate_material:clear(),
    Certificate = ias_demo_store:add_certificate(
                    #{id => <<"policy-certificate-material">>,
                      source => certificate_issue_demo}),
    {ok, _} = ias_certificate_material:put(
                maps:get(id, Certificate),
                client_certificate,
                client_pem(),
                operator_load),
    Diagnostics1 = ias_persistence_policy:diagnostics(),
    ?assertEqual(1, maps:get(durable_certificate_materials, Diagnostics1)),
    ?assertEqual(1, maps:get(ets_certificate_materials, Diagnostics1)),
    ?assertEqual(public_integrity_sha256,
                 maps:get(certificate_material_protection, Diagnostics1)),
    true = ets:delete_all_objects(ias_certificate_material),
    Diagnostics2 = ias_persistence_policy:diagnostics(),
    ?assertEqual(1, maps:get(durable_certificate_materials, Diagnostics2)),
    ?assertEqual(0, maps:get(ets_certificate_materials, Diagnostics2)),
    ?assertEqual({ok, 1}, ias_certificate_material:rehydrate()),
    ok = ias_certificate_material:clear(),
    ok = ias_demo_store:clear().

client_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBZDCCAQqgAwIBAgIUa1wxwBw2MaSaN2Zaqvu/4gWUgDMwCgYIKoZIzj0EAwIw\n"
      "FjEUMBIGA1UEAwwLSUFTIFRlc3QgQ0EwHhcNMjYwNjIxMTIxMzA0WhcNMzYwNjE4\n"
      "MTIxMzA0WjAaMRgwFgYDVQQDDA9JQVMgVGVzdCBDbGllbnQwWTATBgcqhkjOPQIB\n"
      "BggqhkjOPQMBBwNCAAT9brxfCaaU/6LLtCNKICvq1UwQDTH9hS9teBzUhEPuxGcA\n"
      "0wdjEO6F1kR64uUgAoUYOOlIqj31MWH5CcqBwuuxozIwMDAMBgNVHRMBAf8EAjAA\n"
      "MAsGA1UdDwQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAjAKBggqhkjOPQQDAgNI\n"
      "ADBFAiEA2ye4DSJJuQnZ43+peLW5YsQHGEdGx9r1zuCKHxNcY0kCICsBo8QieTgA\n"
      "Iq0sBJ/RxQ+E19tAL+EarYX6zvA00gz9\n"
      "-----END CERTIFICATE-----\n">>.

store(Name, Stores) ->
    [Store] = [Candidate || Candidate <- Stores,
                           maps:get(store, Candidate) =:= Name],
    Store.
