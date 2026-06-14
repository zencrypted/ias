-module(ias_relationship_preview_tests).
-include_lib("eunit/include/eunit.hrl").

device_relationship_preview_test() ->
    {Device, Certificate, Service} = ovpn_objects(),
    Preview = ias_relationship_preview:preview(Device),

    ?assertEqual(not_linked, maps:get(related_certificate, Preview)),
    ?assertEqual(not_linked, maps:get(related_vpn_service, Preview)),
    ?assertEqual([maps:get(id, Certificate)], ids(maps:get(suggested_certificates, Preview))),
    ?assertEqual([maps:get(id, Service)], ids(maps:get(suggested_services, Preview))).

certificate_relationship_preview_test() ->
    {Device, Certificate, _Service} = ovpn_objects(),
    Preview = ias_relationship_preview:preview(Certificate),

    ?assertEqual(not_linked, maps:get(used_by_device, Preview)),
    ?assertEqual([maps:get(id, Device)], ids(maps:get(suggested_devices, Preview))).

vpn_service_relationship_preview_test() ->
    {Device, _Certificate, Service} = ovpn_objects(),
    Preview = ias_relationship_preview:preview(Service),

    ?assertEqual(not_linked, maps:get(used_by_device, Preview)),
    ?assertEqual([maps:get(id, Device)], ids(maps:get(suggested_devices, Preview))).

relationship_preview_creates_no_relationship_records_test() ->
    {Device, Certificate, Service} = ovpn_objects(),
    _ = ias_relationship_preview:preview(Device),
    _ = ias_relationship_preview:preview(Certificate),
    _ = ias_relationship_preview:preview(Service),

    RelationshipRecords = [Object || Object <- ias_demo_store:all(),
                                     maps:get(kind, Object, undefined) =:= relationship],
    ?assertEqual([], RelationshipRecords).

exact_cn_match_ranks_highest_test() ->
    ias_demo_store:clear(),
    Certificate = ias_demo_store:add_certificate(#{
        id => <<"cert_exact">>,
        import_id => <<"cert_flow">>,
        requested_cn => <<"router-1">>,
        enrollment_cn => <<"router-1-20260614-012345">>,
        subject => <<"CN=router-1-20260614-012345">>,
        source => cmp_demo_enrollment
    }),
    Exact = ias_demo_store:add_device(#{id => <<"device_exact">>,
                                        import_id => <<"device_flow">>,
                                        common_name => <<"router-1">>}),
    Prefix = ias_demo_store:add_device(#{id => <<"device_prefix">>,
                                         import_id => <<"device_flow">>,
                                         device_name => <<"router">>}),

    Preview = ias_relationship_preview:preview(Certificate),
    [First, Second | _] = maps:get(suggested_devices, Preview),

    ?assertEqual(maps:get(id, Exact), maps:get(id, First)),
    ?assertEqual(100, maps:get(relationship_score, First)),
    ?assertEqual(maps:get(id, Prefix), maps:get(id, Second)),
    ?assertEqual(50, maps:get(relationship_score, Second)).

prefix_match_ranks_below_exact_device_name_test() ->
    ias_demo_store:clear(),
    Certificate = ias_demo_store:add_certificate(#{
        id => <<"cert_prefix">>,
        import_id => <<"cert_flow">>,
        requested_cn => <<"vpn-client">>,
        enrollment_cn => <<"vpn-client-20260614-012345">>,
        source => cmp_demo_enrollment
    }),
    ExactDeviceName = ias_demo_store:add_device(#{id => <<"device_name_exact">>,
                                                 device_name => <<"vpn-client">>}),
    Prefix = ias_demo_store:add_device(#{id => <<"device_prefix">>,
                                         device_name => <<"vpn">>}),

    Preview = ias_relationship_preview:preview(Certificate),
    [First, Second | _] = maps:get(suggested_devices, Preview),

    ?assertEqual(maps:get(id, ExactDeviceName), maps:get(id, First)),
    ?assertEqual(80, maps:get(relationship_score, First)),
    ?assertEqual(maps:get(id, Prefix), maps:get(id, Second)),
    ?assertEqual(50, maps:get(relationship_score, Second)).

same_import_id_improves_ranking_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_import">>,
                                         import_id => <<"import_a">>}),
    SameImport = ias_demo_store:add_certificate(#{id => <<"cert_same_import">>,
                                                 import_id => <<"import_a">>}),
    Unrelated = ias_demo_store:add_certificate(#{id => <<"cert_unrelated">>,
                                                import_id => <<"import_b">>}),

    Preview = ias_relationship_preview:preview(Device),
    [First, Second | _] = maps:get(suggested_certificates, Preview),

    ?assertEqual(maps:get(id, SameImport), maps:get(id, First)),
    ?assert(maps:get(relationship_score, First) > maps:get(relationship_score, Second)),
    ?assertEqual(maps:get(id, Unrelated), maps:get(id, Second)).

unrelated_objects_are_ranked_lower_test() ->
    ias_demo_store:clear(),
    Certificate = ias_demo_store:add_certificate(#{id => <<"cert_unrelated_rank">>,
                                                  import_id => <<"cert_rank_flow">>,
                                                  source => cmp_demo_enrollment,
                                                  requested_cn => <<"router-1">>,
                                                  enrollment_cn => <<"router-1-20260614-012345">>}),
    Match = ias_demo_store:add_device(#{id => <<"device_match_rank">>,
                                        import_id => <<"device_match_flow">>,
                                        source => ovpn_demo_import,
                                        common_name => <<"router-1">>}),
    Unrelated = ias_demo_store:add_device(#{id => <<"device_unrelated_rank">>,
                                           import_id => <<"device_unrelated_flow">>,
                                           source => ovpn_demo_import,
                                           common_name => <<"other">>}),

    Preview = ias_relationship_preview:preview(Certificate),
    [First, Second | _] = maps:get(suggested_devices, Preview),

    ?assertEqual(maps:get(id, Match), maps:get(id, First)),
    ?assert(maps:get(relationship_score, First) > maps:get(relationship_score, Second)),
    ?assertEqual(maps:get(id, Unrelated), maps:get(id, Second)),
    ?assertEqual(0, maps:get(relationship_score, Second)).

ovpn_objects() ->
    ias_demo_store:clear(),
    {ok, OVPN} = file:read_file("test/fixtures/example.ovpn"),
    Preview = ias_ovpn_preview:analyze(OVPN),
    _ImportId = ias_demo_store:add_import(ias_ovpn_import:import_map(Preview)),
    [Device] = ias_demo_store:devices(),
    [Certificate] = ias_demo_store:certificates(),
    [Service] = ias_demo_store:services(),
    {Device, Certificate, Service}.

ids(Objects) ->
    [maps:get(id, Object) || Object <- Objects].
