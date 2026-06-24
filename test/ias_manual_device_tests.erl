-module(ias_manual_device_tests).
-include_lib("eunit/include/eunit.hrl").

manual_device_creation_success_test() ->
    ias_demo_store:clear(),

    {ok, Device} = ias_manual_device:create(valid_fields()),

    ?assertEqual(device, maps:get(kind, Device)),
    ?assertEqual(<<"Work Laptop">>, maps:get(name, Device)),
    ?assertEqual(<<"vpn-client">>, maps:get(type, Device)),
    ?assertEqual(<<"tun">>, maps:get(tunnel_device, Device)),
    ?assertEqual(<<"udp">>, maps:get(transport, Device)),
    ?assertEqual(<<"10.0.0.10">>, maps:get(endpoint, Device)),
    ?assertEqual(<<"device_file">>, maps:get(private_key_provider, Device)),
    ?assertEqual(<<"client.key">>, maps:get(private_key_ref, Device)),
    ?assertMatch(<<"manual_device_", _/binary>>, maps:get(id, Device)).

manual_device_source_is_manual_device_test() ->
    ias_demo_store:clear(),

    {ok, Device} = ias_manual_device:create(valid_fields()),

    ?assertEqual(manual_device, maps:get(source, Device)).

manual_device_appears_in_devices_list_test() ->
    ias_demo_store:clear(),

    {ok, Device} = ias_manual_device:create(valid_fields()),

    ?assert(lists:any(fun(Stored) ->
        maps:get(id, Stored, undefined) =:= maps:get(id, Device)
    end, ias_demo_store:devices())).

manual_device_name_is_required_test() ->
    ias_demo_store:clear(),

    Result = ias_manual_device:create((valid_fields())#{name => <<"   ">>}),

    ?assertEqual({error, <<"Device Name is required">>}, Result),
    ?assertEqual([], ias_demo_store:devices()).

manual_device_invalid_transport_is_rejected_test() ->
    ias_demo_store:clear(),

    Result = ias_manual_device:create((valid_fields())#{transport => <<"icmp">>}),

    ?assertEqual({error, <<"Transport must be udp or tcp">>}, Result),
    ?assertEqual([], ias_demo_store:devices()).

manual_device_user_input_stays_binary_test() ->
    ias_demo_store:clear(),

    {ok, Device} = ias_manual_device:create((valid_fields())#{
        name => <<"  Branch Tablet  ">>,
        type => <<"  vpn-client  ">>,
        tunnel_device => <<" tun ">>,
        transport => <<" tcp ">>,
        endpoint => <<" vpn.example.com ">>
    }),

    ?assertEqual(<<"Branch Tablet">>, maps:get(name, Device)),
    ?assertEqual(<<"vpn-client">>, maps:get(type, Device)),
    ?assertEqual(<<"tun">>, maps:get(tunnel_device, Device)),
    ?assertEqual(<<"tcp">>, maps:get(transport, Device)),
    ?assertEqual(<<"vpn.example.com">>, maps:get(endpoint, Device)),
    ?assert(is_binary(maps:get(name, Device))),
    ?assert(is_binary(maps:get(type, Device))),
    ?assert(is_binary(maps:get(tunnel_device, Device))),
    ?assert(is_binary(maps:get(transport, Device))),
    ?assert(is_binary(maps:get(endpoint, Device))),
    ?assert(is_binary(maps:get(private_key_provider, Device))),
    ?assert(is_binary(maps:get(private_key_ref, Device))).

manual_device_valid_relative_private_key_reference_test() ->
    ias_demo_store:clear(),

    {ok, Device} = ias_manual_device:create((valid_fields())#{
        private_key_ref => <<" keys/client.key ">>
    }),

    ?assertEqual(<<"keys/client.key">>, maps:get(private_key_ref, Device)).

manual_device_invalid_private_key_reference_is_rejected_test() ->
    ias_demo_store:clear(),

    InvalidRefs = [<<>>, <<"/client.key">>, <<"../client.key">>,
                   <<"keys/../client.key">>, <<"C:/client.key">>,
                   <<"keys\\client.key">>, <<"keys/client\n.key">>,
                   <<"keys/\"client.key">>],
    [?assertMatch({error, _},
                  ias_manual_device:create((valid_fields())#{private_key_ref => Ref}))
     || Ref <- InvalidRefs],
    ?assertEqual([], ias_demo_store:devices()).

manual_device_demo_state_roundtrip_test() ->
    ias_demo_store:clear(),
    {ok, Device} = ias_manual_device:create(valid_fields()),
    Snapshot = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    Result = ias_demo_state:import(Snapshot),

    ?assert(maps:get(imported_objects, Result) >= 1),
    ?assertMatch({ok, #{kind := device, source := manual_device}},
                 ias_demo_store:get(maps:get(id, Device))).

manual_device_available_for_relationship_lookup_test() ->
    ias_demo_store:clear(),
    {ok, Device} = ias_manual_device:create(valid_fields()),
    Certificate = ias_demo_store:add_certificate(#{id => <<"manual_device_certificate">>,
                                                   source => certificate_issue_demo,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),
    Service = ias_demo_store:add_service(#{id => <<"manual_device_service">>,
                                           source => manual_vpn_service,
                                           remote => <<"vpn.example.com:1194">>,
                                           protocol => udp}),

    ?assertEqual(link, ias_relationship_link:status(uses_certificate,
                                                    maps:get(id, Device),
                                                    maps:get(id, Certificate))),
    ?assertEqual(link, ias_relationship_link:status(uses_service,
                                                    maps:get(id, Device),
                                                    maps:get(id, Service))).

existing_ovpn_import_devices_still_work_test() ->
    ias_demo_store:clear(),
    ImportId = ias_demo_store:add_import(#{
        device => #{type => <<"vpn-client">>,
                    endpoint => <<"imported.example.com">>,
                    transport => <<"udp">>,
                    tunnel_device => <<"tun">>},
        certificate => #{ca_present => true,
                         client_certificate_present => true,
                         private_key_present => true,
                         tls_auth_present => false},
        vpn_service => #{service => openvpn,
                         remote => <<"imported.example.com:1194">>,
                         protocol => <<"udp">>,
                         routes => 0}
    }),
    DeviceId = ias_html:join([ImportId, <<"_device">>]),

    ?assertMatch({ok, #{kind := device, source := ovpn_demo_import}},
                 ias_demo_store:get(DeviceId)).

valid_fields() ->
    #{name => <<"Work Laptop">>,
      type => <<"vpn-client">>,
      tunnel_device => <<"tun">>,
      transport => <<"udp">>,
      endpoint => <<"10.0.0.10">>}.

manual_device_preserves_owner_test() ->
    ias_demo_store:clear(),
    {ok, Device} = ias_manual_device:create(#{name => <<"Owned Laptop">>,
                                               type => <<"vpn-client">>,
                                               tunnel_device => <<"tun">>,
                                               transport => <<"udp">>,
                                               owner => bob}),
    ?assertEqual(bob, maps:get(owner, Device)).
