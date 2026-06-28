-module(ias_vpn_orphan_recovery_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kvs/include/metainfo.hrl").
-include("ias_vpn_orphan_recovery_operation.hrl").

operation_lifecycle_is_durable_and_idempotent_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"store-recovery-device">>,
             Token = <<23:256>>,
             Plan = recovery_plan(DeviceId),
             {ok, Planned} = ias_vpn_orphan_recovery_store:start_or_resume(
                               DeviceId, Token, Plan, <<"admin">>, <<"review">>),
             ?assertEqual(planned, maps:get(status, Planned)),
             {ok, Same} = ias_vpn_orphan_recovery_store:start_or_resume(
                            DeviceId, Token, Plan, <<"ignored">>, <<"ignored">>),
             ?assertEqual(maps:get(operation_id, Planned),
                          maps:get(operation_id, Same)),
             {ok, Committed} = ias_kvs_transaction:run(
                                 fun() ->
                                     ias_vpn_orphan_recovery_store:
                                       mark_graph_committed_in_transaction(
                                         DeviceId, Token,
                                         #{plan_id => maps:get(plan_id, Plan),
                                           domain_record_count => 5,
                                           revision => 4})
                                 end),
             ?assertEqual(graph_committed, maps:get(status, Committed)),
             {ok, Reconciled} =
                 ias_vpn_orphan_recovery_store:mark_reconciliation_confirmed(
                   DeviceId, Token, #{state => synchronized}),
             ?assertEqual(reconciliation_confirmed,
                          maps:get(status, Reconciled)),
             {ok, Completed} = ias_vpn_orphan_recovery_store:mark_completed(
                                 DeviceId, Token, #{status => resolved}),
             ?assertEqual(completed, maps:get(status, Completed)),
             {ok, Persisted} = ias_vpn_orphan_recovery_store:get(DeviceId),
             ?assertEqual(Completed, Persisted),
             #table{copy_type = disc_copies, type = set} =
                 kvs:table(ias_vpn_orphan_recovery_operation)
         end
     end}.


incompatible_schema_is_rejected_fail_closed_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         fun() ->
             DeviceId = <<"store-recovery-invalid-schema">>,
             Invalid = #ias_vpn_orphan_recovery_operation{
                          device_id = DeviceId,
                          schema_version = 99},
             ok = kvs:put(Invalid),
             try
                 ?assertMatch(
                    {error,
                     {vpn_orphan_recovery_validation_failed,
                      {unsupported_schema_version, 99}}},
                    ias_vpn_orphan_recovery_store:ensure())
             after
                 _ = kvs:delete(ias_vpn_orphan_recovery_operation, DeviceId)
             end
         end
     end}.

setup() ->
    ok = ias_demo_store:clear(),
    ok = ias_vpn_orphan_recovery_store:ensure(),
    ok = ias_vpn_orphan_recovery_store:reset(),
    ok.

cleanup(_Context) ->
    ok = ias_vpn_orphan_recovery_store:reset(),
    ok = ias_demo_store:clear().

recovery_plan(DeviceId) ->
    PeerId = <<"store-recovery-peer">>,
    Manifest = manifest(DeviceId),
    Command = #{peer_id => PeerId,
                revision => 4,
                operation => upsert,
                source => ias,
                desired_state => #{device_id => DeviceId,
                                   profile_id => default_user,
                                   authorization_mode => policy,
                                   authorized => true,
                                   certificate_fingerprint => <<"fingerprint">>,
                                   enabled => true,
                                   recovery_manifest => Manifest}},
    Head = #{revision => 4,
             digest_version =>
                 ias_vpn_provisioning_command_digest:schema_version(),
             digest => ias_vpn_provisioning_command_digest:digest(Command),
             phase => applied,
             operation => upsert,
             source => ias,
             desired_state => maps:get(desired_state, Command)},
    Entry = #{device_id => DeviceId,
              status => orphan,
              recoverable => true,
              recovery => #{recoverable => true, mode => metadata_only},
              vpn => #{heads => [#{peer_id => PeerId, head => Head}],
                       registry => [#{id => PeerId, provisioning_source => ias}],
                       recovery_manifest => Manifest}},
    {ok, Plan} = ias_vpn_orphan_recovery:plan(Entry),
    Plan.

manifest(DeviceId) ->
    CertificateId = <<DeviceId/binary, "-certificate">>,
    ServiceId = <<DeviceId/binary, "-service">>,
    #{schema_version => 1,
      device => #{kind => device, id => DeviceId,
                  name => <<"Recovered device">>},
      certificate => #{kind => certificate, id => CertificateId,
                       fingerprint_sha256 => <<"fingerprint">>},
      vpn_service => #{kind => vpn_service, id => ServiceId,
                       remote_host => <<"vpn.example.test">>,
                       remote_port => 1194, protocol => udp},
      objects => [#{kind => device, id => DeviceId,
                    name => <<"Recovered device">>},
                  #{kind => certificate, id => CertificateId,
                    fingerprint_sha256 => <<"fingerprint">>},
                  #{kind => vpn_service, id => ServiceId,
                    remote_host => <<"vpn.example.test">>,
                    remote_port => 1194, protocol => udp}],
      relationships =>
          [#{relation_type => uses_certificate,
             source_kind => device, source_id => DeviceId,
             target_kind => certificate, target_id => CertificateId},
           #{relation_type => uses_vpn_service,
             source_kind => device, source_id => DeviceId,
             target_kind => vpn_service, target_id => ServiceId}]}.
