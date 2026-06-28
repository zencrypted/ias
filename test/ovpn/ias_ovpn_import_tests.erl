-module(ias_ovpn_import_tests).
-include_lib("eunit/include/eunit.hrl").

fixture() ->
    {ok, Bin} = file:read_file("test/fixtures/example.ovpn"),
    Bin.

fixture_preview() ->
    ias_ovpn_preview:analyze(fixture()).

preview_extraction_test() ->
    Preview = fixture_preview(),
    ?assertEqual(true, maps:get(detected, Preview)),
    ?assertEqual(<<"example.com">>, maps:get(remote_host, Preview)),
    ?assertEqual(1194, maps:get(remote_port, Preview)),
    ?assertEqual(<<"udp">>, maps:get(proto, Preview)),
    ?assertEqual(<<"tun">>, maps:get(dev, Preview)),
    ?assertEqual(0, maps:get(route_count, Preview)),
    ?assertEqual(true, maps:get(tls_auth, Preview)),
    ?assertEqual(<<"BF-CBC">>, maps:get(cipher, Preview)),
    ?assertEqual(true, maps:get(compression, Preview)),
    ?assertEqual(true, maps:get(has_ca, Preview)),
    ?assertEqual(true, maps:get(has_cert, Preview)),
    ?assertEqual(true, maps:get(has_key, Preview)).

demo_import_store_test() ->
    ias_demo_store:clear(),
    Preview = fixture_preview(),
    ImportMap = ias_ovpn_import:import_map(Preview),
    _ImportId = ias_demo_store:add_import(ImportMap),

    [Device] = ias_demo_store:devices(),
    [Certificate] = ias_demo_store:certificates(),
    [VpnService] = ias_demo_store:services(),

    ?assertEqual(<<"vpn-client">>, maps:get(type, Device)),
    ?assertEqual(<<"example.com:1194">>, maps:get(endpoint, Device)),
    ?assertEqual(<<"udp">>, maps:get(transport, Device)),
    ?assertEqual(<<"tun">>, maps:get(tunnel_device, Device)),

    ?assertEqual(true, maps:get(ca_present, Certificate)),
    ?assertEqual(true, maps:get(client_certificate_present, Certificate)),
    ?assertEqual(true, maps:get(private_key_present, Certificate)),
    ?assertEqual(false, maps:get(private_key_stored, Certificate)),
    ?assertEqual(false, maps:is_key(private_key, Certificate)),
    ?assertEqual(false, maps:is_key(private_key_body, Certificate)),
    ?assertEqual(false, maps:is_key(certificate_body, Certificate)),
    ?assertEqual(false, maps:is_key(ca_body, Certificate)),
    ?assertEqual(false, maps:is_key(tls_auth_body, Certificate)),
    ?assertEqual(true, maps:get(tls_auth_present, Certificate)),

    ?assertEqual(openvpn, maps:get(service, VpnService)),
    ?assertEqual(<<"example.com:1194">>, maps:get(remote, VpnService)),
    ?assertEqual(<<"udp">>, maps:get(protocol, VpnService)),
    ?assertEqual(<<"BF-CBC">>, maps:get(cipher, VpnService)),
    ?assertEqual(true, maps:get(compression, VpnService)),
    ?assertEqual(0, maps:get(routes, VpnService)),

    Stored = term_to_binary(ias_demo_store:all()),
    ?assertEqual(nomatch, binary:match(Stored, <<"BEGIN PRIVATE KEY">>)),
    ?assertEqual(nomatch, binary:match(Stored, <<"BEGIN CERTIFICATE">>)),
    ?assertEqual(nomatch, binary:match(Stored, <<"OpenVPN Static key">>)).
