-module(ias_vpn_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("nitro/include/nitro.hrl").

create_vpn_service_stores_runtime_service_test() ->
    ias_demo_store:clear(),

    {ok, Service} = ias_vpn:create_vpn_service(<<"Office VPN">>,
                                               <<"vpn.example.com">>,
                                               <<"443">>,
                                               tcp),

    ?assertEqual(vpn_service, maps:get(kind, Service)),
    ?assertEqual(manual_vpn_service, maps:get(source, Service)),
    ?assertEqual(<<"Office VPN">>, maps:get(name, Service)),
    ?assertEqual(<<"vpn.example.com:443">>, maps:get(remote, Service)),
    ?assertEqual(tcp, maps:get(protocol, Service)),
    ?assertMatch({ok, _}, ias_demo_store:get(maps:get(id, Service))).


create_vpn_service_links_policy_and_ca_certificate_test() ->
    ias_demo_store:clear(),
    CaCertificate = ias_demo_store:add_certificate(#{id => <<"vpn_service_ca_certificate">>,
                                                     source => ca_certificate,
                                                     subject => <<"CN=CA">>}),

    {ok, Service} = ias_vpn:create_vpn_service(<<"Office VPN">>,
                                               <<"vpn.example.com">>,
                                               <<"1194">>,
                                               udp,
                                               <<"standard">>,
                                               maps:get(id, CaCertificate)),

    ?assertEqual(<<"standard">>, maps:get(security_policy_id, Service)),
    ?assertEqual(maps:get(id, CaCertificate), maps:get(ca_certificate_id, Service)),
    ?assertMatch({linked, _}, ias_relationship_link:status(uses_security_policy,
                                                           maps:get(id, Service),
                                                           <<"standard">>)),
    ?assertMatch({linked, _}, ias_relationship_link:status(uses_ca_certificate,
                                                           maps:get(id, Service),
                                                           maps:get(id, CaCertificate))).

create_vpn_service_requires_remote_host_test() ->
    ias_demo_store:clear(),

    ?assertEqual({error, <<"remote host is required">>},
                 ias_vpn:create_vpn_service(<<"OpenVPN">>, <<>>, <<"1194">>, udp)).

vpn_page_renders_create_service_form_test() ->
    Html = iolist_to_binary(nitro:render(ias_vpn:content({error, unavailable}))),

    ?assertMatch({_, _}, binary:match(Html, <<"Create VPN Service">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Remote Host">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Security Policy">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"CA Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Managed VPN Services">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_runtime_summary">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"vpn_runtime_auto_refresh">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Refresh now">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Auto-refresh: 2s">>)).

vpn_page_honors_runtime_development_bypass_test() ->
    Summary = #{<<"counts">> => #{<<"configured">> => 1,
                                   <<"running">> => 1,
                                   <<"stopped">> => 0,
                                   <<"certificates">> => 1},
                <<"peers">> => [#{<<"id">> => <<"client_a">>,
                                    <<"running">> => true,
                                    <<"mode">> => <<"tun">>,
                                    <<"ip">> => <<"10.20.30.1">>,
                                    <<"remote_peer_id">> => <<"peer_b">>,
                                    <<"authorization_mode">> => <<"development_bypass">>,
                                    <<"authorized">> => true,
                                    <<"authorization_reason">> => <<"development_bypass">>,
                                    <<"certificate">> => #{<<"trusted">> => true,
                                                               <<"key_match">> => true,
                                                               <<"not_after">> => <<"270622203259Z">>}}]},

    Html = iolist_to_binary(nitro:render(ias_vpn:content({ok, Summary}))),

    ?assertMatch({_, _}, binary:match(Html, <<"client_a">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"development bypass">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"270622203259Z">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"vpn not permitted by profile">>)).

vpn_page_keeps_ias_policy_evaluation_for_policy_mode_test() ->
    Summary = #{<<"counts">> => #{},
                <<"peers">> => [#{<<"id">> => <<"unmanaged_peer">>,
                                    <<"running">> => true,
                                    <<"authorization_mode">> => <<"policy">>,
                                    <<"authorized">> => true,
                                    <<"authorization_reason">> => <<"runtime allow must not override IAS">>}]},

    Html = iolist_to_binary(nitro:render(ias_vpn:content({ok, Summary}))),

    ?assertMatch({_, _}, binary:match(Html, <<"vpn not permitted by profile">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"runtime allow must not override IAS">>)).
