-module(ias_device_vpn_access_ui_tests).
-include_lib("eunit/include/eunit.hrl").

device_vpn_access_controls_follow_runtime_state_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Context) ->
         fun() ->
             Device = maps:get(device, Context),
             Summary = vpn_summary(),

             set_runtime_peer(enabled_peer()),
             EnabledHtml = render(Device, Summary),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<"id=\"device_vpn_access\"">>)),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<"VPN Access">>)),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<"client_b">>)),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<"established">>)),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<"Disable VPN Access">>)),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<"Revoke VPN Access">>)),
             ?assertEqual(nomatch, binary:match(EnabledHtml, <<"Enable VPN Access">>)),

             set_runtime_peer(disabled_peer()),
             DisabledHtml = render(Device, Summary),
             ?assertMatch({_, _}, binary:match(DisabledHtml, <<"Enable VPN Access">>)),
             ?assertMatch({_, _}, binary:match(DisabledHtml, <<"Revoke VPN Access">>)),
             ?assertEqual(nomatch, binary:match(DisabledHtml, <<"Disable VPN Access">>)),

             set_runtime_peer(revoked_peer()),
             RevokedHtml = render(Device, Summary),
             ?assertMatch({_, _}, binary:match(RevokedHtml, <<"VPN Access Revoked">>)),
             ?assertEqual(nomatch, binary:match(RevokedHtml, <<"Enable VPN Access">>)),
             ?assertEqual(nomatch, binary:match(RevokedHtml, <<"Disable VPN Access">>)),
             ?assertEqual(nomatch, binary:match(RevokedHtml, <<"Revoke VPN Access">>))
         end
     end}.

unprovisioned_device_shows_guidance_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             Device = ias_demo_store:add_device(#{id => <<"unprovisioned-device">>,
                                                  owner => alice,
                                                  source => manual_device}),
             Html = render(Device, {error, unavailable}),
             ?assertMatch({_, _}, binary:match(Html, <<"VPN access not provisioned">>)),
             ?assertMatch({_, _}, binary:match(Html, <<"Open Provisioning Wizard">>)),
             ?assertEqual(nomatch, binary:match(Html, <<"Disable VPN Access">>)),
             ?assertEqual(nomatch, binary:match(Html, <<"Revoke VPN Access">>))
         end
     end}.

setup() ->
    PreviousTransport = application:get_env(ias, vpn_provisioning_transport),
    PreviousRpcFun = application:get_env(ias, vpn_provisioning_rpc_fun),
    ias_demo_store:clear(),
    ias_vpn_provisioning_state:reset(),
    ias_vpn_provisioning_delivery:reset(),
    Device = ias_demo_store:add_device(#{id => <<"bob-device-ui">>,
                                         owner => bob,
                                         profile_id => default_user,
                                         runtime_peer_id => client_b,
                                         vpn_peer => client_b,
                                         source => manual_device}),
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    set_runtime_peer(enabled_peer()),
    #{device => Device,
      previous_transport => PreviousTransport,
      previous_rpc_fun => PreviousRpcFun}.

cleanup(Context) ->
    restore_env(vpn_provisioning_transport, maps:get(previous_transport, Context)),
    restore_env(vpn_provisioning_rpc_fun, maps:get(previous_rpc_fun, Context)),
    ias_demo_store:clear(),
    ias_vpn_provisioning_state:reset(),
    ias_vpn_provisioning_delivery:reset().

set_runtime_peer(Peer) ->
    application:set_env(
      ias,
      vpn_provisioning_rpc_fun,
      fun(_Node, vpn_peer_registry, get, [client_b], _Timeout) -> {ok, Peer};
         (_Node, _Module, _Function, _Args, _Timeout) -> {error, unsupported_call}
      end).

enabled_peer() ->
    #{id => client_b,
      device_id => <<"bob-device-ui">>,
      profile_id => default_user,
      enabled => true,
      authorized => true,
      authorization_reason => profile_allows_vpn,
      revision => 7,
      revoked => false,
      last_provisioning_operation => upsert}.

disabled_peer() ->
    (enabled_peer())#{enabled => false,
                      last_provisioning_operation => disable}.

revoked_peer() ->
    (enabled_peer())#{enabled => false,
                      authorized => false,
                      authorization_reason => certificate_revoked,
                      revoked => true,
                      last_provisioning_operation => revoke}.

vpn_summary() ->
    {ok, #{<<"peers">> => [#{<<"id">> => <<"client_b">>,
                               <<"running">> => true,
                               <<"handshake_status">> => <<"established">>}]}}.

render(Device, Summary) ->
    iolist_to_binary(nitro:render(ias_demo:vpn_access_preview(Device, Summary))).

restore_env(Key, {ok, Value}) ->
    application:set_env(ias, Key, Value);
restore_env(Key, undefined) ->
    application:unset_env(ias, Key).
