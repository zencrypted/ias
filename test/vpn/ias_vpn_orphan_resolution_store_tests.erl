-module(ias_vpn_orphan_resolution_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kvs/include/metainfo.hrl").

operation_lifecycle_is_durable_and_idempotent_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"store-orphan-device">>,
             Token = <<17:256>>,
             Request = request(DeviceId),
             {ok, Pending} = ias_vpn_orphan_resolution_store:start_or_resume(
                               DeviceId, Token, Request, <<"admin">>, <<"review">>),
             ?assertEqual(pending, maps:get(status, Pending)),
             {ok, Same} = ias_vpn_orphan_resolution_store:start_or_resume(
                            DeviceId, Token, Request, <<"ignored">>, <<"ignored">>),
             ?assertEqual(maps:get(operation_id, Pending),
                          maps:get(operation_id, Same)),
             {ok, VpnConfirmed} =
                 ias_vpn_orphan_resolution_store:mark_vpn_confirmed(
                   DeviceId, Token, #{outcome => decommissioned}),
             ?assertEqual(vpn_confirmed, maps:get(status, VpnConfirmed)),
             {ok, Reconciled} =
                 ias_vpn_orphan_resolution_store:mark_reconciliation_confirmed(
                   DeviceId, Token, #{state => absent,
                                      snapshot => #{device_id => DeviceId,
                                                    status => absent}}),
             ?assertEqual(reconciliation_confirmed,
                          maps:get(status, Reconciled)),
             {ok, Completed} = ias_vpn_orphan_resolution_store:mark_completed(
                                 DeviceId, Token, #{status => resolved}),
             ?assertEqual(completed, maps:get(status, Completed)),
             {ok, Persisted} = ias_vpn_orphan_resolution_store:get(DeviceId),
             ?assertEqual(Completed, Persisted),
             #table{copy_type = disc_copies, type = set} =
                 kvs:table(ias_vpn_orphan_resolution_operation)
         end
     end}.

secret_audit_text_is_rejected_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             ?assertMatch(
                {error, {vpn_orphan_resolution_start_failed, _}},
                ias_vpn_orphan_resolution_store:start_or_resume(
                  <<"secret-note-device">>,
                  <<18:256>>,
                  request(<<"secret-note-device">>),
                  <<"admin">>,
                  <<"-----BEGIN PRIVATE KEY-----">>))
         end
     end}.

setup() ->
    ok = ias_vpn_orphan_resolution_store:ensure(),
    ok = ias_vpn_orphan_resolution_store:reset(),
    ok.

cleanup(_Context) ->
    ok = ias_vpn_orphan_resolution_store:reset().

request(DeviceId) ->
    #{device_id => DeviceId,
      expected_heads => [#{peer_id => <<"peer-a">>,
                           revision => 3,
                           digest => <<5:256>>,
                           phase => applied,
                           source => ias}],
      expected_peer_ids => [<<"peer-a">>],
      expected_source => ias,
      expected_allocation_id => undefined,
      remove_identity => true}.
