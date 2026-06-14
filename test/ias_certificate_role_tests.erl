-module(ias_certificate_role_tests).
-include_lib("eunit/include/eunit.hrl").

imported_certificate_becomes_current_test() ->
    {Device, Imported, _Issued} = lifecycle_objects(),
    Status = ias_certificate_role:device_status(Device),
    Role = ias_certificate_role:certificate_role(Imported),

    ?assertEqual(maps:get(id, Imported),
                 maps:get(id, maps:get(current_certificate, Status))),
    ?assertEqual(imported, maps:get(origin, Role)),
    ?assertEqual(current, maps:get(role, Role)).

issued_certificate_becomes_candidate_test() ->
    {Device, _Imported, Issued} = lifecycle_objects(),
    Status = ias_certificate_role:device_status(Device),
    Role = ias_certificate_role:certificate_role(Issued),

    ?assertEqual(maps:get(id, Issued),
                 maps:get(id, maps:get(candidate_certificate, Status))),
    ?assertEqual(issued, maps:get(origin, Role)),
    ?assertEqual(candidate, maps:get(role, Role)).

replacement_preview_is_generated_test() ->
    {Device, Imported, Issued} = lifecycle_objects(),
    Preview = ias_certificate_role:replacement_preview(Device),

    ?assertEqual(maps:get(id, Imported), maps:get(id, maps:get(current, Preview))),
    ?assertEqual(maps:get(id, Issued), maps:get(id, maps:get(future, Preview))),
    ?assertEqual(<<"replacement possible">>, maps:get(action, Preview)).

no_replacement_action_is_executed_test() ->
    {Device, _Imported, _Issued} = lifecycle_objects(),
    _Status = ias_certificate_role:device_status(Device),
    _Preview = ias_certificate_role:replacement_preview(Device),

    ?assertEqual([], ias_demo_store:relationships()).

lifecycle_objects() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{
        id => <<"ovpn_import_31_device">>,
        import_id => <<"ovpn_import_31">>,
        source => ovpn_demo_import,
        type => <<"vpn-client">>,
        endpoint => <<"example.com:1194">>
    }),
    Imported = ias_demo_store:add_certificate(#{
        id => <<"ovpn_import_31_certificate">>,
        import_id => <<"ovpn_import_31">>,
        source => ovpn_demo_import,
        ca_present => true,
        client_certificate_present => true,
        private_key_present => true,
        private_key_stored => false
    }),
    Issued = ias_demo_store:add_certificate(#{
        id => <<"cmp_enrollment_31_certificate">>,
        import_id => <<"cmp_enrollment_31">>,
        source => cmp_demo_enrollment,
        subject => <<"CN=vpn-client-20260614-012345">>,
        issuer => <<"CN=CA">>,
        requested_cn => <<"vpn-client">>,
        enrollment_cn => <<"vpn-client-20260614-012345">>,
        private_key_stored => false,
        certificate_body_stored => false
    }),
    {Device, Imported, Issued}.
