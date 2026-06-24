-module(ias_vpn_reconciliation_tests).

-include_lib("eunit/include/eunit.hrl").

synchronized_snapshot_is_reported_read_only_test_() ->
    reconciliation_fixture(
      fun(DeviceId, PeerId, Command) ->
          Head = head(Command, applied),
          set_snapshot(#{PeerId => Head},
                       [registry_entry(DeviceId, PeerId, Command)]),
          {ok, Entry} = ias_vpn_reconciliation:device(DeviceId),
          ?assertEqual(synchronized, maps:get(status, Entry)),
          ?assertEqual(in_sync, maps:get(reason, Entry)),
          ?assertEqual(true, maps:get(read_only, Entry)),
          ?assertEqual(none, maps:get(automatic_action, Entry)),
          ?assertEqual(false, maps:get(replay_performed, Entry)),
          ?assertEqual(true, maps:get(digest_match, Entry)),
          ?assertEqual(1, maps:get(revision, maps:get(ias, Entry))),
          ?assertEqual(1,
                       maps:get(revision,
                                maps:get(head, maps:get(vpn, Entry)))),
          {ok, Report} = ias_vpn_reconciliation:report(),
          ?assertEqual(synchronized, maps:get(state, Report)),
          ?assertEqual(1,
                       maps:get(synchronized, maps:get(counts, Report))),
          ?assertEqual(0, maps:get(drift_records, Report))
      end).

vpn_behind_and_pending_are_reported_without_replay_test_() ->
    reconciliation_fixture(
      fun(DeviceId, PeerId, Command1) ->
          {ok, Command2, changed} = ias_vpn_authority:prepare(
                                      DeviceId,
                                      command(DeviceId, PeerId, disable, false)),
          set_snapshot(#{PeerId => head(Command1, applied)},
                       [registry_entry(DeviceId, PeerId, Command1)]),
          {ok, Behind} = ias_vpn_reconciliation:device(DeviceId),
          ?assertEqual(vpn_behind, maps:get(status, Behind)),
          ?assertEqual(vpn_revision_behind, maps:get(reason, Behind)),
          ?assertEqual(false, maps:get(replay_performed, Behind)),

          set_snapshot(#{PeerId => head(Command2, pending)},
                       [registry_entry(DeviceId, PeerId, Command2)]),
          {ok, Pending} = ias_vpn_reconciliation:device(DeviceId),
          ?assertEqual(vpn_behind, maps:get(status, Pending)),
          ?assertEqual(vpn_command_pending, maps:get(reason, Pending)),
          ?assertEqual(true, maps:get(digest_match, Pending))
      end).

divergence_and_missing_snapshots_are_distinguished_test_() ->
    reconciliation_fixture(
      fun(DeviceId, PeerId, Command) ->
          Conflicting = (head(Command, applied))#{digest => <<0:256>>},
          set_snapshot(#{PeerId => Conflicting},
                       [registry_entry(DeviceId, PeerId, Command)]),
          {ok, Divergence} = ias_vpn_reconciliation:device(DeviceId),
          ?assertEqual(divergence, maps:get(status, Divergence)),
          ?assertEqual(command_digest_mismatch,
                       maps:get(reason, Divergence)),

          set_snapshot(#{}, []),
          {ok, MissingHead} = ias_vpn_reconciliation:device(DeviceId),
          ?assertEqual(missing_in_vpn, maps:get(status, MissingHead)),
          ?assertEqual(provisioning_head_missing,
                       maps:get(reason, MissingHead)),

          set_snapshot(#{PeerId => head(Command, applied)}, []),
          {ok, MissingRegistry} = ias_vpn_reconciliation:device(DeviceId),
          ?assertEqual(missing_in_vpn, maps:get(status, MissingRegistry)),
          ?assertEqual(runtime_registry_missing,
                       maps:get(reason, MissingRegistry))
      end).

vpn_only_device_is_reported_as_orphan_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"vpn-orphan-device">>,
             PeerId = <<"vpn-orphan-peer">>,
             Command = (command(DeviceId, PeerId, upsert, true))#{revision => 7},
             set_snapshot(#{PeerId => head(Command, applied)},
                          [registry_entry(DeviceId, PeerId, Command)]),
             {ok, Report} = ias_vpn_reconciliation:report(),
             ?assertEqual(drift_detected, maps:get(state, Report)),
             ?assertEqual(1, maps:get(orphan_records, Report)),
             ?assertEqual(1, maps:get(orphan, maps:get(counts, Report))),
             [Orphan] = maps:get(entries, Report),
             ?assertEqual(DeviceId, maps:get(device_id, Orphan)),
             ?assertEqual(orphan, maps:get(status, Orphan)),
             ?assertEqual(vpn_device_without_ias_authority,
                          maps:get(reason, Orphan)),
             ?assertEqual(false, maps:get(replay_performed, Orphan))
         end
     end}.

transport_disabled_fails_without_vpn_calls_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             application:set_env(ias, vpn_provisioning_transport, disabled),
             ?assertEqual({error, vpn_transport_disabled},
                          ias_vpn_reconciliation:report())
         end
     end}.

reconciliation_fixture(TestFun) ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"ias-reconciliation-device">>,
             PeerId = <<"ias-reconciliation-peer">>,
             Command0 = command(DeviceId, PeerId, upsert, true),
             {ok, Command, changed} = ias_vpn_authority:prepare(DeviceId,
                                                                Command0),
             TestFun(DeviceId, PeerId, Command)
         end
     end}.

setup() ->
    Previous = #{transport => application:get_env(ias,
                                                   vpn_provisioning_transport),
                 rpc_fun => application:get_env(ias,
                                                 vpn_provisioning_rpc_fun)},
    ok = ias_demo_store:clear(),
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    Previous.

cleanup(Previous) ->
    ok = ias_demo_store:clear(),
    restore_env(vpn_provisioning_transport, maps:get(transport, Previous)),
    restore_env(vpn_provisioning_rpc_fun, maps:get(rpc_fun, Previous)).

set_snapshot(Heads, Registry) ->
    Fun = fun(_Node, vpn_provisioning, recovery_heads, [], _Timeout) ->
                  {ok, Heads};
             (_Node, vpn_peer_registry, list, [], _Timeout) ->
                  Registry;
             (_Node, Module, Function, Args, _Timeout) ->
                  erlang:error({unexpected_reconciliation_rpc,
                                Module,
                                Function,
                                Args})
          end,
    application:set_env(ias, vpn_provisioning_rpc_fun, Fun).

head(Command, Phase) ->
    #{revision => maps:get(revision, Command),
      digest => vpn_digest(Command),
      phase => Phase,
      operation => maps:get(operation, Command),
      source => ias,
      lifecycle_state => case maps:get(operation, Command) of
                             disable -> disabled;
                             revoke -> revoked;
                             remove -> removed;
                             _ -> active
                         end,
      desired_state => maps:get(desired_state, Command),
      updated_at => 1782340000,
      durable => true}.

registry_entry(DeviceId, PeerId, Command) ->
    Desired = maps:get(desired_state, Command),
    #{id => PeerId,
      device_id => DeviceId,
      enabled => maps:get(enabled, Desired, true),
      authorized => maps:get(authorized, Desired, true),
      authorization_mode => maps:get(authorization_mode, Desired, policy),
      authorization_reason => maps:get(authorization_reason, Desired, undefined),
      provisioning_source => ias,
      revision => maps:get(revision, Command),
      revoked => maps:get(revoked, Desired, false),
      last_provisioning_operation => maps:get(operation, Command),
      updated_at => 1782340000}.

command(DeviceId, PeerId, Operation, Enabled) ->
    #{peer_id => PeerId,
      operation => Operation,
      source => ias,
      desired_state => #{device_id => DeviceId,
                         profile_id => default_user,
                         authorization_mode => policy,
                         authorized => Enabled,
                         authorization_reason => reconciliation_test,
                         enabled => Enabled,
                         revoked => Operation =:= revoke}}.

vpn_digest(Command) ->
    crypto:hash(sha256,
                term_to_binary(maps:remove(dynamic_device_id, Command),
                               [deterministic])).

restore_env(Key, {ok, Value}) -> application:set_env(ias, Key, Value);
restore_env(Key, undefined) -> application:unset_env(ias, Key).
