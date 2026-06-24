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
             ?assertMatch({_, _}, binary:match(EnabledHtml, client_peer_id())),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<"Dynamic VPN Allocation">>)),
             ?assertMatch({_, _}, binary:match(EnabledHtml, allocation_id())),
             ?assertMatch({_, _}, binary:match(EnabledHtml, gateway_peer_id())),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<">dynamic</td>">>)),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<"established">>)),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<"Disable VPN Access">>)),
             ?assertMatch({_, _}, binary:match(EnabledHtml, <<"Revoke VPN Access">>)),
             ?assertEqual(nomatch, binary:match(EnabledHtml, <<"Enable VPN Access">>)),
             ?assertEqual(nomatch, binary:match(EnabledHtml, <<"Decommission VPN Access">>)),

             set_runtime_peer(disabled_peer()),
             DisabledHtml = render(Device, Summary),
             ?assertMatch({_, _}, binary:match(DisabledHtml, <<"Enable VPN Access">>)),
             ?assertMatch({_, _}, binary:match(DisabledHtml, <<"Revoke VPN Access">>)),
             ?assertMatch({_, _}, binary:match(DisabledHtml, <<"Decommission VPN Access">>)),
             ?assertEqual(nomatch, binary:match(DisabledHtml, <<"Disable VPN Access">>)),

             set_runtime_peer(revoked_peer()),
             RevokedHtml = render(Device, Summary),
             ?assertMatch({_, _}, binary:match(RevokedHtml, <<"VPN Access Revoked">>)),
             ?assertEqual(nomatch, binary:match(RevokedHtml, <<"Enable VPN Access">>)),
             ?assertEqual(nomatch, binary:match(RevokedHtml, <<"Disable VPN Access">>)),
             ?assertEqual(nomatch, binary:match(RevokedHtml, <<"Revoke VPN Access">>)),
             ?assertMatch({_, _}, binary:match(RevokedHtml, <<"Decommission VPN Access">>))
         end
     end}.

reserved_device_shows_dynamic_allocation_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             Device = ias_demo_store:add_device(
                        maps:merge(
                          #{id => <<"reserved-device">>,
                            owner => alice,
                            source => manual_device},
                          allocation_fields())),
             Html = render(Device, {error, unavailable}),
             ?assertMatch({_, _}, binary:match(Html, <<"VPN access not provisioned">>)),
             ?assertMatch({_, _}, binary:match(Html, <<"Dynamic VPN Allocation">>)),
             ?assertMatch({_, _}, binary:match(Html, allocation_id())),
             ?assertMatch({_, _}, binary:match(Html, client_peer_id())),
             ?assertMatch({_, _}, binary:match(Html, gateway_peer_id())),
             ?assertMatch({_, _}, binary:match(Html, <<">reserved</td>">>))
         end
     end}.



decommissioned_device_shows_audit_and_reprovision_guidance_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             Summary = #{device_id => <<"decommissioned-device-ui">>,
                         allocation_id => <<"released-allocation-ui">>,
                         client_peer_id => <<"released-client-ui">>,
                         gateway_peer_id => <<"released-gateway-ui">>,
                         allocation_state => released,
                         registry_state => removed,
                         identity_state => removed,
                         decommissioned_at => 1782302000},
             Device = ias_demo_store:add_device(
                        #{id => <<"decommissioned-device-ui">>,
                          owner => alice,
                          peer_id => <<"decommissioned-device-ui">>,
                          source => manual_device,
                          vpn_last_decommission => Summary,
                          vpn_decommission_history => [Summary]}),
             Html = render(Device, {error, unavailable}),
             ?assertMatch({_, _}, binary:match(Html, <<"VPN access not provisioned">>)),
             ?assertMatch({_, _}, binary:match(Html, <<"Last VPN Decommission">>)),
             ?assertMatch({_, _}, binary:match(Html, <<"released-allocation-ui">>)),
             ?assertMatch({_, _}, binary:match(Html, <<"released-client-ui">>)),
             ?assertMatch({_, _}, binary:match(Html, <<"removed">>)),
             ?assertMatch({_, _}, binary:match(Html, <<"Open Provisioning Wizard">>)),
             ?assertEqual(nomatch, binary:match(Html, <<"Decommission VPN Access">>))
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
             ?assertEqual(nomatch, binary:match(Html, <<"Dynamic VPN Allocation">>)),
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
    Device = ias_demo_store:add_device(
               maps:merge(
                 #{id => <<"bob-device-ui">>,
                   owner => bob,
                   profile_id => default_user,
                   runtime_peer_id => client_peer_id(),
                   vpn_peer => client_peer_id(),
                   source => manual_device},
                 (allocation_fields())#{vpn_dynamic_pair_state => established,
                                      vpn_dynamic_pair_reconciled_at => 1782290000})),
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
    ClientPeerId = client_peer_id(),
    application:set_env(
      ias,
      vpn_provisioning_rpc_fun,
      fun(_Node, vpn_peer_registry, get, [PeerId], _Timeout)
            when PeerId =:= ClientPeerId ->
              {ok, Peer};
         (_Node, _Module, _Function, _Args, _Timeout) ->
              {error, unsupported_call}
      end).

enabled_peer() ->
    #{id => client_peer_id(),
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
    {ok, #{<<"peers">> => [#{<<"id">> => client_peer_id(),
                               <<"running">> => true,
                               <<"handshake_status">> => <<"established">>}]}}.

allocation_fields() ->
    #{vpn_allocation_id => allocation_id(),
      vpn_allocator_instance_id => <<"allocator-ui-test">>,
      vpn_client_peer_id => client_peer_id(),
      vpn_gateway_peer_id => gateway_peer_id(),
      vpn_allocation_slot => 3,
      vpn_allocation_generation => 9,
      vpn_allocation_state => reserved,
      vpn_allocation_persistence => volatile,
      vpn_allocation_created_at => 1782289900}.

allocation_id() -> <<"dynamic-vpn-3_allocator-ui-test_9">>.
client_peer_id() -> <<"client_dyn_3_allocator-ui-test_9">>.
gateway_peer_id() -> <<"gateway_dyn_3_allocator-ui-test_9">>.

render(Device, Summary) ->
    iolist_to_binary(nitro:render(ias_demo:vpn_access_preview(Device, Summary))).

restore_env(Key, {ok, Value}) ->
    application:set_env(ias, Key, Value);
restore_env(Key, undefined) ->
    application:unset_env(ias, Key).
