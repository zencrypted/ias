-module(ias_vpn_reconciliation_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kvs/include/metainfo.hrl").

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
             ?assertEqual(false, maps:get(replay_performed, Orphan)),
             ?assertEqual(false, maps:get(recoverable, Orphan)),
             ?assertEqual(recovery_manifest_missing,
                          maps:get(reason, maps:get(recovery, Orphan)))
         end
     end}.

vpn_only_device_with_manifest_has_recovery_preview_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"vpn-recoverable-device">>,
             PeerId = <<"vpn-recoverable-peer">>,
             Manifest = recovery_manifest(DeviceId),
             Command0 = command(DeviceId, PeerId, upsert, true),
             Desired0 = maps:get(desired_state, Command0),
             Command = Command0#{revision => 8,
                                 desired_state => Desired0#{recovery_manifest =>
                                                               Manifest}},
             set_snapshot(#{PeerId => head(Command, applied)},
                          [registry_entry(DeviceId, PeerId, Command)]),
             {ok, Report} = ias_vpn_reconciliation:report(),
             [Orphan] = maps:get(entries, Report),
             ?assertEqual(orphan, maps:get(status, Orphan)),
             ?assertEqual(true, maps:get(recoverable, Orphan)),
             Recovery = maps:get(recovery, Orphan),
             ?assertEqual(true, maps:get(recoverable, Recovery)),
             ?assertEqual(metadata_only, maps:get(mode, Recovery)),
             ?assertEqual(DeviceId, maps:get(device_id, Recovery)),
             ?assertEqual(3, maps:get(object_count, Recovery)),
             ?assertEqual(2, maps:get(relationship_count, Recovery)),
             ?assertEqual(Manifest,
                          maps:get(recovery_manifest, maps:get(vpn, Orphan)))
         end
     end}.

safe_replay_preserves_durable_command_and_is_idempotent_test_() ->
    reconciliation_fixture(
      fun(DeviceId, PeerId, Command1) ->
          {ok, Command2, changed} = ias_vpn_authority:prepare(
                                      DeviceId,
                                      command(DeviceId,
                                              PeerId,
                                              disable,
                                              false)),
          Tracker = replay_tracker(behind,
                                   DeviceId,
                                   PeerId,
                                   Command1,
                                   Command2),
          {ok, Before} = ias_vpn_reconciliation:device(DeviceId),
          ?assertEqual(vpn_behind, maps:get(status, Before)),
          ?assertEqual(2,
                       maps:get(revision,
                                maps:get(ias, Before))),

          {ok, Replay} = ias_vpn_reconciliation:replay(DeviceId),
          ?assertEqual(replayed, maps:get(outcome, Replay)),
          ?assertEqual(true, maps:get(replay_performed, Replay)),
          ?assertEqual(vpn_behind, maps:get(trigger_status, Replay)),
          ?assertEqual(2, maps:get(command_revision, Replay)),
          ?assertEqual(applied,
                       maps:get(delivery_status,
                                maps:get(delivery, Replay))),
          ?assertEqual(synchronized,
                       maps:get(status, maps:get('after', Replay))),
          ?assertEqual(1, tracker_value(Tracker, apply_count)),

          {ok, Authority} = ias_vpn_authority:get(DeviceId),
          ?assertEqual(Command2,
                       maps:get(canonical_command, Authority)),
          ?assertEqual(2, maps:get(revision, Authority)),
          HistoryAfterReplay = ias_vpn_provisioning_delivery:history(DeviceId),
          ?assertEqual(1, length(HistoryAfterReplay)),

          {ok, NoOp} = ias_vpn_reconciliation:replay(DeviceId),
          ?assertEqual(already_synchronized, maps:get(outcome, NoOp)),
          ?assertEqual(false, maps:get(replay_performed, NoOp)),
          ?assertEqual(1, tracker_value(Tracker, apply_count)),
          ?assertEqual(HistoryAfterReplay,
                       ias_vpn_provisioning_delivery:history(DeviceId)),
          ets:delete(Tracker)
      end).

missing_projection_is_replayed_by_safe_batch_test_() ->
    reconciliation_fixture(
      fun(DeviceId, PeerId, Command1) ->
          {ok, Command2, changed} = ias_vpn_authority:prepare(
                                      DeviceId,
                                      command(DeviceId,
                                              PeerId,
                                              disable,
                                              false)),
          Tracker = replay_tracker(missing,
                                   DeviceId,
                                   PeerId,
                                   Command1,
                                   Command2),
          {ok, Before} = ias_vpn_reconciliation:device(DeviceId),
          ?assertEqual(missing_in_vpn, maps:get(status, Before)),

          {ok, Result} = ias_vpn_reconciliation:replay(),
          ?assertEqual(synchronized, maps:get(state, Result)),
          ?assertEqual(1, maps:get(attempted_records, Result)),
          ?assertEqual(1, maps:get(replayed_records, Result)),
          ?assertEqual(0, maps:get(blocked_records, Result)),
          ?assertEqual(0, maps:get(failed_records, Result)),
          ?assertEqual(1, tracker_value(Tracker, apply_count)),
          ?assertEqual(0,
                       maps:get(drift_records,
                                maps:get('after', Result))),
          ets:delete(Tracker)
      end).

divergence_and_foreign_vpn_state_are_never_replayed_test_() ->
    reconciliation_fixture(
      fun(DeviceId, PeerId, Command1) ->
          Conflicting = (head(Command1, applied))#{digest => <<0:256>>},
          set_snapshot(#{PeerId => Conflicting},
                       [registry_entry(DeviceId, PeerId, Command1)]),
          ?assertEqual({error,
                        {vpn_replay_blocked,
                         divergence,
                         command_digest_mismatch}},
                       ias_vpn_reconciliation:replay(DeviceId)),

          {ok, _Command2, changed} = ias_vpn_authority:prepare(
                                       DeviceId,
                                       command(DeviceId,
                                               PeerId,
                                               disable,
                                               false)),
          ForeignHead = (head(Command1, applied))#{source => external},
          set_snapshot(#{PeerId => ForeignHead},
                       [registry_entry(DeviceId, PeerId, Command1)]),
          ?assertEqual({error,
                        {vpn_replay_blocked,
                         divergence,
                         vpn_state_not_owned_by_ias}},
                       ias_vpn_reconciliation:replay(DeviceId))
      end).

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


orphan_decommission_saga_is_durable_and_idempotent_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"vpn-orphan-decommission-device">>,
             PeerId = <<"vpn-orphan-decommission-peer">>,
             Command = (command(DeviceId, PeerId, upsert, true))#{revision => 6},
             Tracker = orphan_decommission_tracker(DeviceId,
                                                    PeerId,
                                                    Command,
                                                    success),
             {ok, _} = ias_vpn_reconciliation:scan_incidents(),
             {ok, Incident0} = ias_vpn_reconciliation:incident(DeviceId),
             Token = maps:get(token, Incident0),
             ?assertEqual(orphan, maps:get(kind, Incident0)),

             {ok, Result} = ias_vpn_reconciliation:decommission_orphan(
                              DeviceId,
                              Token,
                              <<"admin">>,
                              <<"remove orphan">>),
             ?assertEqual(decommission_orphan,
                          maps:get(requested_action, Result)),
             ?assertEqual(completed, maps:get(status, Result)),
             ?assertEqual(1, tracker_value(Tracker, decommission_count)),
             {ok, Operation} = ias_vpn_orphan_resolution_store:get(DeviceId),
             ?assertEqual(completed, maps:get(status, Operation)),
             ?assertEqual(<<"admin">>, maps:get(actor, Operation)),
             {ok, Incident1} = ias_vpn_reconciliation:incident(DeviceId),
             ?assertEqual(resolved, maps:get(status, Incident1)),

             {ok, Retry} = ias_vpn_reconciliation:decommission_orphan(
                              DeviceId,
                              Token,
                              <<"admin">>,
                              <<"retry">>),
             ?assertEqual(completed, maps:get(status, Retry)),
             ?assertEqual(1, tracker_value(Tracker, decommission_count)),
             ets:delete(Tracker)
         end
     end}.

orphan_decommission_snapshot_conflict_is_fail_closed_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"vpn-orphan-conflict-device">>,
             PeerId = <<"vpn-orphan-conflict-peer">>,
             Command = (command(DeviceId, PeerId, upsert, true))#{revision => 3},
             Tracker = orphan_decommission_tracker(DeviceId,
                                                    PeerId,
                                                    Command,
                                                    conflict),
             {ok, _} = ias_vpn_reconciliation:scan_incidents(),
             {ok, Incident} = ias_vpn_reconciliation:incident(DeviceId),
             Token = maps:get(token, Incident),
             ?assertEqual({error,
                           {vpn_orphan_decommission_failed,
                            orphan_snapshot_conflict}},
                          ias_vpn_reconciliation:decommission_orphan(
                            DeviceId,
                            Token,
                            <<"admin">>,
                            <<"stale snapshot">>)),
             {ok, Operation} = ias_vpn_orphan_resolution_store:get(DeviceId),
             ?assertEqual(pending, maps:get(status, Operation)),
             ?assertEqual(1, maps:get(attempts, Operation)),
             {ok, StillOpen} = ias_vpn_reconciliation:incident(DeviceId),
             ?assertEqual(open, maps:get(status, StillOpen)),
             ?assertEqual(1, tracker_value(Tracker, decommission_count)),
             ets:delete(Tracker)
         end
     end}.

recoverable_orphan_is_adopted_atomically_and_idempotently_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"vpn-recovery-device">>,
             PeerId = <<"vpn-recovery-peer">>,
             Manifest = recovery_manifest(DeviceId),
             Command0 = command(DeviceId, PeerId, upsert, true),
             Desired0 = maps:get(desired_state, Command0),
             Command = Command0#{revision => 6,
                                 desired_state => Desired0#{recovery_manifest =>
                                                               Manifest}},
             set_snapshot(#{PeerId => head(Command, applied)},
                          [registry_entry(DeviceId, PeerId, Command)]),
             {ok, _Scan} = ias_vpn_reconciliation:scan_incidents(),
             {ok, Incident} = ias_vpn_reconciliation:incident(DeviceId),
             Token = maps:get(token, Incident),
             {ok, Result} = ias_vpn_reconciliation:recover_orphan(
                              DeviceId, Token, <<"admin">>, <<"adopt">>),
             ?assertEqual(completed, maps:get(status, Result)),
             ?assertEqual(metadata_only, maps:get(recovery_mode, Result)),
             {ok, Device} = ias_demo_store:get(DeviceId),
             ?assertEqual(device, maps:get(kind, Device)),
             {ok, Authority} = ias_vpn_authority:get(DeviceId),
             ?assertEqual(6, maps:get(revision, Authority)),
             ?assertEqual(Command, maps:get(canonical_command, Authority)),
             Binding = maps:get(binding, Authority),
             ?assertEqual(PeerId, maps:get(runtime_peer_id, Binding)),
             ?assertEqual(recovered, maps:get(vpn_allocation_state, Binding)),
             {ok, Operation} = ias_vpn_orphan_recovery_store:get(DeviceId),
             ?assertEqual(completed, maps:get(status, Operation)),
             {ok, Resolved} = ias_vpn_reconciliation:incident(DeviceId),
             ?assertEqual(resolved, maps:get(status, Resolved)),
             {ok, Again} = ias_vpn_reconciliation:recover_orphan(
                             DeviceId, Token, <<"admin">>, <<"retry">>),
             ?assertEqual(maps:get(operation_id, Result),
                          maps:get(operation_id, Again)),
             {ok, Entry} = ias_vpn_reconciliation:device(DeviceId),
             ?assertEqual(synchronized, maps:get(status, Entry))
         end
     end}.

vpn_digest_mismatch_blocks_orphan_recovery_before_commit_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"vpn-recovery-digest-device">>,
             PeerId = <<"vpn-recovery-digest-peer">>,
             Manifest = recovery_manifest(DeviceId),
             Command0 = command(DeviceId, PeerId, upsert, true),
             Desired0 = maps:get(desired_state, Command0),
             Command = Command0#{revision => 9,
                                 desired_state => Desired0#{recovery_manifest =>
                                                               Manifest}},
             InvalidHead = (head(Command, applied))#{digest => <<0:256>>},
             set_snapshot(#{PeerId => InvalidHead},
                          [registry_entry(DeviceId, PeerId, Command)]),
             {ok, _Scan} = ias_vpn_reconciliation:scan_incidents(),
             {ok, Incident} = ias_vpn_reconciliation:incident(DeviceId),
             ?assertEqual(
                {error, recovery_command_digest_mismatch},
                ias_vpn_reconciliation:recover_orphan(
                  DeviceId, maps:get(token, Incident),
                  <<"admin">>, <<"digest mismatch">>)),
             ?assertEqual(not_found, ias_demo_store:get(DeviceId)),
             ?assertEqual(not_found, ias_vpn_authority:get(DeviceId)),
             ?assertEqual(not_found,
                          ias_vpn_orphan_recovery_store:get(DeviceId))
         end
     end}.

recovery_transaction_rolls_back_graph_and_authority_on_late_conflict_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"vpn-recovery-rollback-device">>,
             PeerId = <<"vpn-recovery-rollback-peer">>,
             Manifest = recovery_manifest(DeviceId),
             Command0 = command(DeviceId, PeerId, upsert, true),
             Desired0 = maps:get(desired_state, Command0),
             Command = Command0#{revision => 4,
                                 desired_state => Desired0#{recovery_manifest =>
                                                               Manifest}},
             set_snapshot(#{PeerId => head(Command, applied)},
                          [registry_entry(DeviceId, PeerId, Command)]),
             {ok, _Scan} = ias_vpn_reconciliation:scan_incidents(),
             {ok, Incident} = ias_vpn_reconciliation:incident(DeviceId),
             Token = maps:get(token, Incident),
             {ok, Report} = ias_vpn_reconciliation:report(),
             [Entry] = [Candidate || Candidate <- maps:get(entries, Report),
                                     maps:get(device_id, Candidate) =:= DeviceId],
             {ok, Plan} = ias_vpn_orphan_recovery:plan(Entry),
             {ok, _Operation} =
                 ias_vpn_orphan_recovery_store:start_or_resume(
                   DeviceId, Token, Plan, <<"admin">>, <<"rollback test">>),
             CertificateId = <<DeviceId/binary, "-certificate">>,
             {ok, _ConflictingRecord, changed} =
                 ias_domain_store:put(
                   #{kind => certificate,
                     id => CertificateId,
                     fingerprint_sha256 => <<"conflicting-fingerprint">>}),
             ?assertMatch(
                {error,
                 {vpn_orphan_recovery_commit_failed,
                  {vpn_orphan_recovery_object_conflict,
                   certificate,
                   _}}},
                ias_vpn_orphan_recovery:commit(DeviceId, Token, Plan)),
             ?assertEqual(not_found, ias_demo_store:get(DeviceId)),
             ?assertEqual(not_found, ias_vpn_authority:get(DeviceId)),
             {ok, Operation} = ias_vpn_orphan_recovery_store:get(DeviceId),
             ?assertEqual(planned, maps:get(status, Operation))
         end
     end}.

changed_vpn_snapshot_blocks_planned_recovery_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"vpn-recovery-stale-device">>,
             PeerId = <<"vpn-recovery-stale-peer">>,
             Manifest = recovery_manifest(DeviceId),
             Command0 = command(DeviceId, PeerId, upsert, true),
             Desired0 = maps:get(desired_state, Command0),
             Command = Command0#{revision => 2,
                                 desired_state => Desired0#{recovery_manifest =>
                                                               Manifest}},
             Registry = registry_entry(DeviceId, PeerId, Command),
             set_snapshot(#{PeerId => head(Command, applied)}, [Registry]),
             {ok, _Scan} = ias_vpn_reconciliation:scan_incidents(),
             {ok, Incident} = ias_vpn_reconciliation:incident(DeviceId),
             Token = maps:get(token, Incident),
             {ok, Report} = ias_vpn_reconciliation:report(),
             [Entry] = [Candidate || Candidate <- maps:get(entries, Report),
                                     maps:get(device_id, Candidate) =:= DeviceId],
             {ok, Plan} = ias_vpn_orphan_recovery:plan(Entry),
             {ok, _Operation} =
                 ias_vpn_orphan_recovery_store:start_or_resume(
                   DeviceId, Token, Plan, <<"admin">>, <<"stale snapshot">>),
             ChangedRegistry = Registry#{enabled => false},
             set_snapshot(#{PeerId => head(Command, applied)},
                          [ChangedRegistry]),
             ?assertEqual(
                {error, orphan_snapshot_conflict},
                ias_vpn_reconciliation:recover_orphan(
                  DeviceId, Token, <<"admin">>, <<"retry">>)),
             ?assertEqual(not_found, ias_demo_store:get(DeviceId)),
             ?assertEqual(not_found, ias_vpn_authority:get(DeviceId)),
             {ok, Operation} = ias_vpn_orphan_recovery_store:get(DeviceId),
             ?assertEqual(planned, maps:get(status, Operation)),
             ?assertEqual(1, maps:get(attempts, Operation))
         end
     end}.

conflicting_ias_object_blocks_orphan_recovery_without_authority_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"vpn-recovery-conflict-device">>,
             PeerId = <<"vpn-recovery-conflict-peer">>,
             _ = ias_demo_store:put_runtime_object(
                   #{kind => device, id => DeviceId,
                     name => <<"Conflicting device">>,
                     source => manual_device}),
             Manifest = recovery_manifest(DeviceId),
             Command0 = command(DeviceId, PeerId, upsert, true),
             Desired0 = maps:get(desired_state, Command0),
             Command = Command0#{revision => 3,
                                 desired_state => Desired0#{recovery_manifest =>
                                                               Manifest}},
             set_snapshot(#{PeerId => head(Command, applied)},
                          [registry_entry(DeviceId, PeerId, Command)]),
             {ok, _Scan} = ias_vpn_reconciliation:scan_incidents(),
             {ok, Incident} = ias_vpn_reconciliation:incident(DeviceId),
             ?assertMatch(
                {error, {vpn_orphan_recovery_object_conflict, device, _}},
                ias_vpn_reconciliation:recover_orphan(
                  DeviceId, maps:get(token, Incident),
                  <<"admin">>, <<"must not overwrite">>)),
             ?assertEqual(not_found, ias_vpn_authority:get(DeviceId))
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
    ok = ias_vpn_provisioning_delivery:reset(),
    ok = ias_vpn_orphan_resolution_store:reset(),
    ok = ias_vpn_orphan_recovery_store:reset(),
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    Previous.

cleanup(Previous) ->
    ok = ias_demo_store:clear(),
    ok = ias_vpn_provisioning_delivery:reset(),
    ok = ias_vpn_orphan_resolution_store:reset(),
    ok = ias_vpn_orphan_recovery_store:reset(),
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

replay_tracker(InitialState,
               DeviceId,
               PeerId,
               BeforeCommand,
               ReplayCommand) ->
    Tracker = ets:new(ias_vpn_reconciliation_replay_tracker,
                      [set, private]),
    true = ets:insert(Tracker,
                      [{state, InitialState},
                       {apply_count, 0}]),
    Fun = fun(_Node, vpn_provisioning, recovery_heads, [], _Timeout) ->
                  case tracker_value(Tracker, state) of
                      behind -> {ok, #{PeerId => head(BeforeCommand, applied)}};
                      missing -> {ok, #{}};
                      synchronized ->
                          {ok, #{PeerId => head(ReplayCommand, applied)}}
                  end;
             (_Node, vpn_peer_registry, list, [], _Timeout) ->
                  case tracker_value(Tracker, state) of
                      behind -> [registry_entry(DeviceId,
                                                PeerId,
                                                BeforeCommand)];
                      missing -> [];
                      synchronized -> [registry_entry(DeviceId,
                                                      PeerId,
                                                      ReplayCommand)]
                  end;
             (_Node, vpn_provisioning, apply, [Delivered], _Timeout) ->
                  case Delivered =:= ReplayCommand of
                      true -> ok;
                      false -> erlang:error({unexpected_replay_command,
                                             Delivered,
                                             ReplayCommand})
                  end,
                  _ = ets:update_counter(Tracker, apply_count, 1),
                  true = ets:insert(Tracker, {state, synchronized}),
                  {ok, #{operation => maps:get(operation, ReplayCommand),
                         peer => registry_entry(DeviceId,
                                                PeerId,
                                                ReplayCommand)}};
             (_Node, Module, Function, Args, _Timeout) ->
                  erlang:error({unexpected_replay_rpc,
                                Module,
                                Function,
                                Args})
          end,
    application:set_env(ias, vpn_provisioning_rpc_fun, Fun),
    Tracker.


orphan_decommission_tracker(DeviceId, PeerId, Command, Outcome) ->
    Tracker = ets:new(ias_vpn_orphan_decommission_tracker,
                      [set, private]),
    true = ets:insert(Tracker,
                      [{state, present},
                       {decommission_count, 0}]),
    Head = head(Command, applied),
    Registry = registry_entry(DeviceId, PeerId, Command),
    Fun = fun(_Node, vpn_provisioning, recovery_heads, [], _Timeout) ->
                  case tracker_value(Tracker, state) of
                      present -> {ok, #{PeerId => Head}};
                      absent -> {ok, #{}}
                  end;
             (_Node, vpn_peer_registry, list, [], _Timeout) ->
                  case tracker_value(Tracker, state) of
                      present -> [Registry];
                      absent -> []
                  end;
             (_Node, vpn_provisioning, decommission_orphan, [Request], _Timeout) ->
                  ?assertEqual(DeviceId, maps:get(device_id, Request)),
                  ?assertEqual(ias, maps:get(expected_source, Request)),
                  ?assertEqual([PeerId], maps:get(expected_peer_ids, Request)),
                  _ = ets:update_counter(Tracker, decommission_count, 1),
                  case Outcome of
                      success ->
                          true = ets:insert(Tracker, {state, absent}),
                          {ok, #{outcome => decommissioned,
                                 device_id => DeviceId,
                                 removed_peer_ids => [PeerId]}};
                      conflict ->
                          {error, orphan_snapshot_conflict}
                  end;
             (_Node, Module, Function, Args, _Timeout) ->
                  erlang:error({unexpected_orphan_decommission_rpc,
                                Module,
                                Function,
                                Args})
          end,
    application:set_env(ias, vpn_provisioning_rpc_fun, Fun),
    Tracker.

tracker_value(Tracker, Key) ->
    [{Key, Value}] = ets:lookup(Tracker, Key),
    Value.

head(Command, Phase) ->
    #{revision => maps:get(revision, Command),
      digest_version => ias_vpn_provisioning_command_digest:schema_version(),
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
                         certificate_fingerprint => <<"fingerprint">>,
                         enabled => Enabled,
                         revoked => Operation =:= revoke}}.


recovery_manifest(DeviceId) ->
    CertificateId = <<DeviceId/binary, "-certificate">>,
    ServiceId = <<DeviceId/binary, "-service">>,
    #{schema_version => 1,
      provisioning_transaction_id => <<"vpn-provisioning-transaction">>,
      device => #{kind => device,
                  id => DeviceId,
                  name => <<"Recovered device">>},
      certificate => #{kind => certificate,
                       id => CertificateId,
                       fingerprint_sha256 => <<"fingerprint">>},
      vpn_service => #{kind => vpn_service,
                       id => ServiceId,
                       remote_host => <<"vpn.example.test">>,
                       remote_port => 1194,
                       protocol => udp},
      objects => [#{kind => device,
                    id => DeviceId,
                    name => <<"Recovered device">>},
                  #{kind => certificate,
                    id => CertificateId,
                    fingerprint_sha256 => <<"fingerprint">>},
                  #{kind => vpn_service,
                    id => ServiceId,
                    remote_host => <<"vpn.example.test">>,
                    remote_port => 1194,
                    protocol => udp}],
      relationships =>
          [#{relation_type => uses_certificate,
             source_kind => device,
             source_id => DeviceId,
             target_kind => certificate,
             target_id => CertificateId},
           #{relation_type => uses_vpn_service,
             source_kind => device,
             source_id => DeviceId,
             target_kind => vpn_service,
             target_id => ServiceId}]}.

vpn_digest(Command) ->
    ias_vpn_provisioning_command_digest:digest(Command).

restore_env(Key, {ok, Value}) -> application:set_env(ias, Key, Value);
restore_env(Key, undefined) -> application:unset_env(ias, Key).

divergence_incident_requires_current_token_and_verified_resolution_test_() ->
    reconciliation_fixture(
      fun(DeviceId, PeerId, Command) ->
          Conflicting = (head(Command, applied))#{digest => <<0:256>>},
          set_snapshot(#{PeerId => Conflicting},
                       [registry_entry(DeviceId, PeerId, Command)]),
          {ok, Scan} = ias_vpn_reconciliation:scan_incidents(),
          ?assertEqual(1, maps:get(active_records, Scan)),
          {ok, Incident0} = ias_vpn_reconciliation:incident(DeviceId),
          Token = maps:get(token, Incident0),
          ?assertEqual(32, byte_size(Token)),
          #table{copy_type = disc_copies,
                 type = set} = kvs:table(ias_vpn_reconciliation_incident),
          ?assertEqual(open, maps:get(status, Incident0)),
          ?assertEqual(divergence, maps:get(kind, Incident0)),
          ?assertMatch({error, _},
                       ias_vpn_reconciliation:acknowledge_incident(
                         DeviceId, <<0:256>>, <<"admin">>, <<"stale">>)),
          {ok, Incident1} = ias_vpn_reconciliation:acknowledge_incident(
                              DeviceId, Token, <<"admin">>, <<"reviewed">>),
          ?assertEqual(acknowledged, maps:get(status, Incident1)),
          ?assertMatch({error, {vpn_incident_still_active, divergence, _}},
                       ias_vpn_reconciliation:resolve_incident(
                         DeviceId, Token, <<"admin">>, <<"too early">>)),

          set_snapshot(#{PeerId => head(Command, applied)},
                       [registry_entry(DeviceId, PeerId, Command)]),
          {ok, Resolved} = ias_vpn_reconciliation:resolve_incident(
                             DeviceId, Token, <<"admin">>, <<"verified">>),
          ?assertEqual(resolved, maps:get(status, Resolved)),
          ?assertEqual(synchronized,
                       maps:get(state, maps:get(verified_clearance, Resolved)))
      end).

orphan_incident_resolves_only_after_vpn_state_disappears_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"vpn-orphan-incident-device">>,
             PeerId = <<"vpn-orphan-incident-peer">>,
             Command = (command(DeviceId, PeerId, upsert, true))#{revision => 4},
             set_snapshot(#{PeerId => head(Command, applied)},
                          [registry_entry(DeviceId, PeerId, Command)]),
             {ok, _} = ias_vpn_reconciliation:scan_incidents(),
             {ok, Incident0} = ias_vpn_reconciliation:incident(DeviceId),
             Token = maps:get(token, Incident0),
             ?assertEqual(orphan, maps:get(kind, Incident0)),

             set_snapshot(#{}, []),
             {ok, Resolved} = ias_vpn_reconciliation:resolve_incident(
                                DeviceId, Token, <<"admin">>, <<"removed">>),
             ?assertEqual(resolved, maps:get(status, Resolved)),
             ?assertEqual(absent,
                          maps:get(state, maps:get(verified_clearance, Resolved)))
         end
     end}.
