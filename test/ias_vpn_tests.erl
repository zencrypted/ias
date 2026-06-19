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

create_vpn_service_requires_remote_host_test() ->
    ias_demo_store:clear(),

    ?assertEqual({error, <<"remote host is required">>},
                 ias_vpn:create_vpn_service(<<"OpenVPN">>, <<>>, <<"1194">>, udp)).

vpn_page_renders_create_service_form_test() ->
    Html = iolist_to_binary(nitro:render(ias_vpn:content({error, unavailable}))),

    ?assertMatch({_, _}, binary:match(Html, <<"Create VPN Service">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Remote Host">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Managed VPN Services">>)).
