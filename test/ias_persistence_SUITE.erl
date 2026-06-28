-module(ias_persistence_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("ias_domain_object.hrl").
-include("ias_csr_enrollment_record.hrl").
-include("ias_certificate_material_record.hrl").
-include("ias_vpn_orphan_recovery_operation.hrl").

-export([all/0,
         init_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         end_per_suite/1,
         domain_graph_survives_ias_restart/1,
         repeated_restart_is_idempotent/1,
         wizard_completion_survives_ias_restart/1,
         vpn_delivery_audit_survives_ias_restart/1,
         csr_enrollment_state_survives_ias_restart/1,
         certificate_material_survives_ias_restart/1,
         vpn_orphan_recovery_survives_ias_restart/1,
         incompatible_durable_schema_fails_closed/1,
         incompatible_csr_enrollment_schema_fails_closed/1,
         incompatible_certificate_material_schema_fails_closed/1,
         incompatible_vpn_orphan_recovery_schema_fails_closed/1,
         reconciliation_rpc/5]).

-define(COOKIE, ias_persistence_ct_cookie).
-define(STARTUP_TIMEOUT_MS, 30000).
-define(RPC_TIMEOUT_MS, 10000).
-define(START_RESULT_KEY, {ias_persistence_ct, start_result}).
-define(SNAPSHOT_KEY, {?MODULE, vpn_snapshot}).

all() ->
    [domain_graph_survives_ias_restart,
     repeated_restart_is_idempotent,
     wizard_completion_survives_ias_restart,
     vpn_delivery_audit_survives_ias_restart,
     csr_enrollment_state_survives_ias_restart,
     certificate_material_survives_ias_restart,
     vpn_orphan_recovery_survives_ias_restart,
     incompatible_durable_schema_fails_closed,
     incompatible_csr_enrollment_schema_fails_closed,
     incompatible_certificate_material_schema_fails_closed,
     incompatible_vpn_orphan_recovery_schema_fails_closed].

init_per_suite(Config) ->
    ok = ensure_distributed_controller(),
    true = erlang:set_cookie(node(), ?COOKIE),
    IasRepo = filename:absname(ias_repo_from_env()),
    ok = validate_ias_repo(IasRepo),
    [{ias_repo, IasRepo} | Config].

init_per_testcase(TestCase, Config) ->
    IasRepo = proplists:get_value(ias_repo, Config),
    RuntimeRoot = testcase_runtime_root(TestCase, Config),
    MnesiaDir = filename:join(RuntimeRoot, "mnesia"),
    ConfigPath = filename:join(RuntimeRoot, "ias-persistence.config"),
    LogPath = filename:join(RuntimeRoot, "ias-initial.log"),
    Port = free_tcp_port(),
    Node = testcase_node(TestCase),
    ok = ensure_no_conflicting_node(Node),
    ok = reset_runtime_root(RuntimeRoot),
    ok = write_runtime_config(IasRepo, ConfigPath, Port),
    case start_ias(IasRepo, Node, ConfigPath, MnesiaDir, LogPath) of
        {ok, Process, {ok, _Started}} ->
            track_ias_process(Node, Process),
            case wait_for_tcp_open(Port, ?STARTUP_TIMEOUT_MS) of
                ok ->
                    [{ias_node, Node},
                     {ias_process, Process},
                     {ias_mnesia_dir, MnesiaDir},
                     {ias_runtime_config, ConfigPath},
                     {ias_log, LogPath},
                     {ias_port, Port} | Config];
                {error, Reason} ->
                    _ = stop_ias(Node, Process),
                    ct:fail({ias_initial_http_start_failed,
                             Reason,
                             read_log(LogPath)})
            end;
        {ok, Process, StartResult} ->
            track_ias_process(Node, Process),
            _ = stop_ias(Node, Process),
            ct:fail({ias_initial_start_failed,
                     StartResult,
                     read_log(LogPath)})
    end.

end_per_testcase(_TestCase, Config) ->
    Node = proplists:get_value(ias_node, Config),
    Process = proplists:get_value(ias_process, Config),
    _ = stop_ias(Node, Process),
    ok.

end_per_suite(_Config) ->
    ok.

domain_graph_survives_ias_restart(Config) ->
    Node = proplists:get_value(ias_node, Config),
    {Objects, Relationships, Ids, Binding} = complete_graph(),
    {ok, _Graph} = rpc_ok(Node, ias_demo_store, commit_graph,
                          [Objects, Relationships]),

    DeviceId = maps:get(device, Ids),
    PeerId = maps:get(peer, Ids),
    Command0 = provisioning_command(DeviceId, PeerId),
    {ok, Command, changed} =
        rpc_ok(Node, ias_vpn_authority, prepare, [DeviceId, Command0]),
    ok = install_reconciliation_snapshot(Node,
                                         reconciliation_snapshot(DeviceId,
                                                                 PeerId,
                                                                 Command)),

    HealthBefore = rpc_ok(Node, ias_demo_store, projection_health, []),
    assert_synchronized_hashes(HealthBefore),
    DurableHash = maps:get(durable_projection_hash, HealthBefore),
    {ok, AuthorityBefore} = rpc_ok(Node, ias_vpn_authority, get, [DeviceId]),
    {ok, ReportBefore} = rpc_ok(Node, ias_vpn_reconciliation, report, []),
    assert_reconciliation_synchronized(ReportBefore, DeviceId),

    Config1 = restart_ias(Config, "ias-restarted.log", success),
    Node1 = proplists:get_value(ias_node, Config1),

    HealthAfter = rpc_ok(Node1, ias_demo_store, projection_health, []),
    assert_synchronized_hashes(HealthAfter),
    ?assertEqual(DurableHash,
                 maps:get(durable_projection_hash, HealthAfter)),
    ?assertEqual(length(Objects), maps:get(durable_objects, HealthAfter)),
    ?assertEqual(length(Relationships),
                 maps:get(durable_relationships, HealthAfter)),

    lists:foreach(
      fun(Id) ->
          ?assertMatch({ok, #{id := Id}},
                       rpc_ok(Node1, ias_demo_store, get, [Id]))
      end,
      graph_ids(Ids)),

    GraphReport = rpc_ok(Node1,
                         ias_relationship_graph,
                         graph_consistency_report,
                         []),
    ?assertEqual([], maps:get(broken_relationships, GraphReport)),
    ?assertEqual([], maps:get(unknown_relationships, GraphReport)),
    ?assertEqual(length(Relationships),
                 maps:get(total_relationships, GraphReport)),

    {ok, RestoredDevice} = rpc_ok(Node1, ias_demo_store, get, [DeviceId]),
    ?assertEqual(maps:get(runtime_peer_id, Binding),
                 maps:get(runtime_peer_id, RestoredDevice)),
    ?assertEqual(maps:get(vpn_allocation_id, Binding),
                 maps:get(vpn_allocation_id, RestoredDevice)),
    ?assertEqual(established,
                 maps:get(vpn_dynamic_pair_state, RestoredDevice)),

    {ok, AuthorityAfter} = rpc_ok(Node1, ias_vpn_authority, get, [DeviceId]),
    ?assertEqual(maps:get(revision, AuthorityBefore),
                 maps:get(revision, AuthorityAfter)),
    ?assertEqual(maps:get(canonical_command, AuthorityBefore),
                 maps:get(canonical_command, AuthorityAfter)),
    ?assertEqual(maps:get(binding, AuthorityBefore),
                 maps:get(binding, AuthorityAfter)),

    ok = install_reconciliation_snapshot(Node1,
                                         reconciliation_snapshot(DeviceId,
                                                                 PeerId,
                                                                 Command)),
    {ok, ReportAfter} = rpc_ok(Node1, ias_vpn_reconciliation, report, []),
    assert_reconciliation_synchronized(ReportAfter, DeviceId),

    Profiles = rpc_ok(Node1, ias_demo_store, security_profiles, []),
    ?assert(lists:any(fun(#{id := administrator}) -> true;
                        (_) -> false
                     end,
                     Profiles)),
    ok.

repeated_restart_is_idempotent(Config) ->
    Node = proplists:get_value(ias_node, Config),
    DeviceId = <<"stage4-repeat-device">>,
    DeletedId = <<"stage4-deleted-device">>,
    Device = simple_device(DeviceId, #{}),
    _Stored = rpc_ok(Node, ias_demo_store, put_runtime_object, [Device]),
    _Deleted = rpc_ok(Node,
                      ias_demo_store,
                      put_runtime_object,
                      [simple_device(DeletedId, #{})]),
    ok = rpc_ok(Node,
                ias_demo_store,
                delete_runtime_object,
                [device, DeletedId]),
    Initial = rpc_ok(Node, ias_demo_store, projection_health, []),
    assert_synchronized_hashes(Initial),
    Hash = maps:get(durable_projection_hash, Initial),

    Config1 = restart_ias(Config, "ias-repeat-1.log", success),
    Health1 = rpc_ok(proplists:get_value(ias_node, Config1),
                     ias_demo_store,
                     projection_health,
                     []),
    assert_stable_single_object(Health1, Hash),

    Config2 = restart_ias(Config1, "ias-repeat-2.log", success),
    Node2 = proplists:get_value(ias_node, Config2),
    Health2 = rpc_ok(Node2, ias_demo_store, projection_health, []),
    assert_stable_single_object(Health2, Hash),
    ?assertEqual(1, length(rpc_ok(Node2, ias_demo_store, runtime_objects, []))),
    ?assertMatch({ok, #{id := DeviceId}},
                 rpc_ok(Node2, ias_demo_store, get, [DeviceId])),
    ?assertEqual(not_found,
                 rpc_ok(Node2, ias_demo_store, get, [DeletedId])),
    ok.

wizard_completion_survives_ias_restart(Config) ->
    Node = proplists:get_value(ias_node, Config),
    {ok, Draft} = rpc_ok(Node,
                         ias_provisioning_wizard_store,
                         new,
                         [device_bound]),
    WizardId = maps:get(id, Draft),
    ProvisioningId = <<"stage5b-restart-provisioning">>,
    Transaction = #{id => ProvisioningId,
                    provisioning_id => ProvisioningId,
                    kind => ovpn_provisioning,
                    source => provisioning_wizard,
                    mode => device_bound,
                    subject_kind => device,
                    subject_id => <<"stage5b-device">>,
                    device_id => undefined,
                    certificate_id => undefined,
                    vpn_service_id => undefined,
                    ca_certificate_id => undefined,
                    authorization => allow,
                    status => ready_for_delivery,
                    private_key_stored => false,
                    certificate_body_stored => false,
                    ca_body_stored => false},
    Completed = Draft#{provisioning_id => ProvisioningId,
                       completed => true,
                       completed_at => <<"2026-06-27T19:40:00Z">>,
                       current_step => provisioning,
                       updated_at => <<"2026-06-27T19:40:00Z">>},
    {ok, Completed, StoredTransaction, _Changes} =
        rpc_ok(Node,
               ias_provisioning_wizard_completion,
               commit,
               [Draft, Completed, Transaction]),
    ?assertEqual(ProvisioningId, maps:get(id, StoredTransaction)),

    Config1 = restart_ias(Config, "ias-stage5b-restarted.log", success),
    Node1 = proplists:get_value(ias_node, Config1),
    ?assertMatch({ok, #{object_id := ProvisioningId,
                         payload := #{id := ProvisioningId}}},
                 rpc_ok(Node1,
                        ias_domain_store,
                        get,
                        [ovpn_provisioning, ProvisioningId])),
    ?assertMatch({ok, #{id := ProvisioningId}},
                 rpc_ok(Node1,
                        ias_ovpn_provisioning,
                        get,
                        [ProvisioningId])),
    ?assertEqual({ok, Completed},
                 rpc_ok(Node1,
                        ias_provisioning_wizard_store,
                        get,
                        [WizardId])),
    Health = rpc_ok(Node1, ias_demo_store, projection_health, []),
    assert_synchronized_hashes(Health),
    ok.

vpn_delivery_audit_survives_ias_restart(Config) ->
    Node = proplists:get_value(ias_node, Config),
    DeviceId = <<"stage6-delivery-audit-device">>,
    Command = #{peer_id => DeviceId,
                revision => 1,
                operation => disable,
                source => ias,
                desired_state => #{device_id => DeviceId,
                                   enabled => false,
                                   authorized => false,
                                   authorization_mode => policy,
                                   authorization_reason => test}},
    {ok, First} = rpc_ok(Node,
                         ias_vpn_provisioning_delivery,
                         deliver,
                         [Command]),
    DeliveryId = maps:get(delivery_id, First),
    ?assertEqual(1, maps:get(attempt, First)),
    ?assertEqual(1,
                 rpc_ok(Node,
                        ias_vpn_provisioning_delivery,
                        projection_count,
                        [])),

    Config1 = restart_ias(Config, "ias-stage6-delivery-audit.log", success),
    Node1 = proplists:get_value(ias_node, Config1),
    [Restored] = rpc_ok(Node1,
                        ias_vpn_provisioning_delivery,
                        history,
                        [DeviceId]),
    ?assertEqual(DeliveryId, maps:get(delivery_id, Restored)),
    ?assertEqual(1, maps:get(attempt, Restored)),
    ?assertEqual(disabled, maps:get(delivery_status, Restored)),
    ?assertEqual(1,
                 rpc_ok(Node1,
                        ias_vpn_provisioning_delivery,
                        projection_count,
                        [])),

    {ok, Second} = rpc_ok(Node1,
                          ias_vpn_provisioning_delivery,
                          deliver,
                          [Command]),
    ?assertEqual(2, maps:get(attempt, Second)),
    [Latest, Earlier] = rpc_ok(Node1,
                               ias_vpn_provisioning_delivery,
                               history,
                               [DeviceId]),
    ?assertEqual(maps:get(delivery_id, Second), maps:get(delivery_id, Latest)),
    ?assertEqual(DeliveryId, maps:get(delivery_id, Earlier)),
    ok.

csr_enrollment_state_survives_ias_restart(Config) ->
    Node = proplists:get_value(ias_node, Config),
    IssuedFingerprint = <<"stage6c-issued-csr">>,
    RetryableFingerprint = <<"stage6c-retryable-csr">>,
    NonRetryableFingerprint = <<"stage6c-non-retryable-csr">>,
    DeviceId = <<"stage6c-csr-device">>,
    PublicKeyFingerprint = <<"stage6c-public-key">>,
    {ok, Issued} = rpc_ok(
                     Node,
                     ias_csr_enrollment_state,
                     mark_issued,
                     [IssuedFingerprint,
                      #{device_id => DeviceId,
                        wizard_id => <<"stage6c-wizard">>,
                        public_key_fingerprint => PublicKeyFingerprint,
                        private_key_reference => <<"keys/stage6c-device.key">>,
                        certificate_id => <<"stage6c-certificate">>}]),
    {ok, Retryable} = rpc_ok(
                        Node,
                        ias_csr_enrollment_state,
                        mark_failed,
                        [RetryableFingerprint, cmp_timeout, true]),
    {ok, NonRetryable} = rpc_ok(
                           Node,
                           ias_csr_enrollment_state,
                           mark_failed,
                           [NonRetryableFingerprint,
                            cmp_unexpected_certificate_response,
                            false]),
    ?assertEqual(issued, maps:get(status, Issued)),
    ?assertEqual(true, maps:get(retryable, Retryable)),
    ?assertEqual(false, maps:get(retryable, NonRetryable)),
    ?assertEqual(3,
                 rpc_ok(Node,
                        ias_csr_enrollment_state,
                        projection_count,
                        [])),

    Config1 = restart_ias(Config, "ias-stage6c-csr-enrollment.log", success),
    Node1 = proplists:get_value(ias_node, Config1),
    ?assertMatch({ok, #{status := issued,
                        device_id := DeviceId,
                        public_key_fingerprint := PublicKeyFingerprint,
                        certificate_id := <<"stage6c-certificate">>}},
                 rpc_ok(Node1,
                        ias_csr_enrollment_state,
                        get,
                        [IssuedFingerprint])),
    ?assertMatch({error, {duplicate_csr, _}},
                 rpc_ok(Node1,
                        ias_csr_enrollment_state,
                        submitted,
                        [IssuedFingerprint])),
    ?assertMatch({error, {reused_public_key, _}},
                 rpc_ok(Node1,
                        ias_csr_enrollment_state,
                        public_key_available,
                        [DeviceId, PublicKeyFingerprint])),
    ?assertEqual(ok,
                 rpc_ok(Node1,
                        ias_csr_enrollment_state,
                        submitted,
                        [RetryableFingerprint])),
    ?assertMatch({error, {duplicate_csr, _}},
                 rpc_ok(Node1,
                        ias_csr_enrollment_state,
                        submitted,
                        [NonRetryableFingerprint])),
    ?assertEqual(3,
                 rpc_ok(Node1,
                        ias_csr_enrollment_state,
                        projection_count,
                        [])),
    Diagnostics = rpc_ok(Node1, ias_persistence_policy, diagnostics, []),
    ?assertEqual(3, maps:get(durable_csr_enrollment_states, Diagnostics)),
    ?assertEqual(3, maps:get(ets_csr_enrollment_states, Diagnostics)),
    ok.

certificate_material_survives_ias_restart(Config) ->
    Node = proplists:get_value(ias_node, Config),
    CertificateId = <<"stage6d-client-certificate">>,
    AttachedCertificateId = <<"stage6d-attached-certificate">>,
    EnrollmentId = <<"stage6d-staged-enrollment">>,
    _ = rpc_ok(Node,
               ias_demo_store,
               put_runtime_object,
               [stage6d_certificate(CertificateId)]),
    _ = rpc_ok(Node,
               ias_demo_store,
               put_runtime_object,
               [stage6d_certificate(AttachedCertificateId)]),
    {ok, Status} = rpc_ok(Node,
                          ias_certificate_material,
                          put,
                          [CertificateId,
                           client_certificate,
                           stage6d_client_pem(),
                           operator_load]),
    {ok, _Staged} = rpc_ok(Node,
                            ias_certificate_material,
                            stage_cmp,
                            [EnrollmentId, stage6d_client_pem()]),
    ?assertEqual(public_integrity_sha256,
                 maps:get(protection_mode, Status)),
    ?assertEqual(2,
                 rpc_ok(Node,
                        ias_certificate_material,
                        projection_count,
                        [])),

    Config1 = restart_ias(Config, "ias-stage6d-certificate-material.log", success),
    Node1 = proplists:get_value(ias_node, Config1),
    ?assertMatch({ok, #{certificate_id := CertificateId,
                        material_type := client_certificate,
                        source := operator_load,
                        body := _}},
                 rpc_ok(Node1,
                        ias_certificate_material,
                        get,
                        [CertificateId, operator_inspection])),
    ?assertMatch({ok, #{enrollment_id := EnrollmentId,
                        material_type := client_certificate,
                        body := _}},
                 rpc_ok(Node1,
                        ias_certificate_material_store,
                        get_staged,
                        [EnrollmentId])),
    {ok, Attached} = rpc_ok(Node1,
                            ias_certificate_material,
                            attach_staged,
                            [EnrollmentId, AttachedCertificateId]),
    ?assertEqual(cmp_response, maps:get(source, Attached)),
    ?assertEqual(not_found,
                 rpc_ok(Node1,
                        ias_certificate_material_store,
                        get_staged,
                        [EnrollmentId])),
    Diagnostics = rpc_ok(Node1, ias_persistence_policy, diagnostics, []),
    ?assertEqual(2, maps:get(durable_certificate_materials, Diagnostics)),
    ?assertEqual(2, maps:get(ets_certificate_materials, Diagnostics)),
    ?assertEqual(public_integrity_sha256,
                 maps:get(certificate_material_protection, Diagnostics)),
    ok.

vpn_orphan_recovery_survives_ias_restart(Config) ->
    Node = proplists:get_value(ias_node, Config),
    DeviceId = <<"stage7c-recovery-device">>,
    PeerId = <<"stage7c-recovery-peer">>,
    Manifest = stage7c_recovery_manifest(DeviceId),
    Command = stage7c_recovery_command(DeviceId, PeerId, Manifest),
    Snapshot = stage7c_orphan_snapshot(DeviceId, PeerId, Command),
    ok = install_reconciliation_snapshot(Node, Snapshot),
    {ok, _Scan} = rpc_ok(Node, ias_vpn_reconciliation, scan_incidents, []),
    {ok, Incident} = rpc_ok(Node,
                            ias_vpn_reconciliation,
                            incident,
                            [DeviceId]),
    Token = maps:get(token, Incident),
    {ok, Result} = rpc_ok(Node,
                          ias_vpn_reconciliation,
                          recover_orphan,
                          [DeviceId, Token, <<"ct-admin">>, <<"adopt">>]),
    ?assertEqual(completed, maps:get(status, Result)),
    ?assertEqual(metadata_only, maps:get(recovery_mode, Result)),

    Config1 = restart_ias(Config, "ias-stage7c-orphan-recovery.log", success),
    Node1 = proplists:get_value(ias_node, Config1),
    {ok, Operation} = rpc_ok(Node1,
                             ias_vpn_orphan_recovery_store,
                             get,
                             [DeviceId]),
    ?assertEqual(completed, maps:get(status, Operation)),
    ?assertEqual(Token, maps:get(incident_token, Operation)),
    {ok, Device} = rpc_ok(Node1, ias_demo_store, get, [DeviceId]),
    ?assertEqual(PeerId, maps:get(runtime_peer_id, Device)),
    {ok, Authority} = rpc_ok(Node1, ias_vpn_authority, get, [DeviceId]),
    ?assertEqual(maps:get(revision, Command), maps:get(revision, Authority)),
    ?assertEqual(Command, maps:get(canonical_command, Authority)),
    {ok, Resolved} = rpc_ok(Node1,
                            ias_vpn_reconciliation,
                            incident,
                            [DeviceId]),
    ?assertEqual(resolved, maps:get(status, Resolved)),
    {ok, Again} = rpc_ok(Node1,
                         ias_vpn_reconciliation,
                         recover_orphan,
                         [DeviceId, Token, <<"ct-admin">>, <<"retry">>]),
    ?assertEqual(maps:get(operation_id, Result),
                 maps:get(operation_id, Again)),
    ok = install_reconciliation_snapshot(Node1, Snapshot),
    {ok, Report} = rpc_ok(Node1, ias_vpn_reconciliation, report, []),
    assert_reconciliation_synchronized(Report, DeviceId),
    ok.

incompatible_durable_schema_fails_closed(Config) ->
    Node = proplists:get_value(ias_node, Config),
    InvalidId = <<"stage4-invalid-schema">>,
    Invalid = #ias_domain_object{
                 key = {device, InvalidId},
                 schema_version = 999,
                 kind = device,
                 object_id = InvalidId,
                 payload = simple_device(InvalidId, #{}),
                 revision = 1,
                 created_at = 1,
                 updated_at = 1},
    ok = rpc_ok(Node, kvs, put, [Invalid]),

    Config1 = restart_ias(Config, "ias-invalid-restart.log", failure),
    Node1 = proplists:get_value(ias_node, Config1),
    StartResult = rpc_ok(Node1,
                         persistent_term,
                         get,
                         [?START_RESULT_KEY, pending]),
    ?assertMatch({error, _}, StartResult),
    ?assert(contains_term(StartResult,
                          {unsupported_domain_schema_version, 999})),
    ?assertEqual(undefined, rpc_ok(Node1, erlang, whereis, [ias])),
    ?assertEqual(undefined,
                 rpc_ok(Node1, ets, info, [ias_demo_store])),
    ?assertEqual(false,
                 lists:keymember(ias,
                                 1,
                                 rpc_ok(Node1,
                                        application,
                                        which_applications,
                                        []))),
    Port = proplists:get_value(ias_port, Config1),
    ok = wait_for_tcp_closed(Port, 5000),
    ok.

incompatible_csr_enrollment_schema_fails_closed(Config) ->
    Node = proplists:get_value(ias_node, Config),
    Fingerprint = <<"stage6c-invalid-csr-schema">>,
    Payload = #{csr_fingerprint => Fingerprint,
                status => submitted,
                retryable => false},
    Invalid = #ias_csr_enrollment_record{
                 csr_fingerprint = Fingerprint,
                 schema_version = 999,
                 status = submitted,
                 retryable = false,
                 payload = Payload,
                 revision = 1,
                 created_at = 1,
                 updated_at = 1},
    ok = rpc_ok(Node, kvs, put, [Invalid]),

    Config1 = restart_ias(Config, "ias-invalid-csr-schema.log", failure),
    Node1 = proplists:get_value(ias_node, Config1),
    StartResult = rpc_ok(Node1,
                         persistent_term,
                         get,
                         [?START_RESULT_KEY, pending]),
    ?assertMatch({error, _}, StartResult),
    ?assert(contains_term(
              StartResult,
              {unsupported_csr_enrollment_schema_version, 999})),
    ?assertEqual(undefined, rpc_ok(Node1, erlang, whereis, [ias])),
    ?assertEqual(false,
                 lists:keymember(ias,
                                 1,
                                 rpc_ok(Node1,
                                        application,
                                        which_applications,
                                        []))),
    Port = proplists:get_value(ias_port, Config1),
    ok = wait_for_tcp_closed(Port, 5000),
    ok.

incompatible_certificate_material_schema_fails_closed(Config) ->
    Node = proplists:get_value(ias_node, Config),
    CertificateId = <<"stage6d-invalid-material-schema">>,
    _ = rpc_ok(Node,
               ias_demo_store,
               put_runtime_object,
               [stage6d_certificate(CertificateId)]),
    {ok, _} = rpc_ok(Node,
                      ias_certificate_material,
                      put,
                      [CertificateId,
                       client_certificate,
                       stage6d_client_pem(),
                       operator_load]),
    Key = {certificate, CertificateId},
    {ok, Record0} = rpc_ok(Node,
                           kvs,
                           get,
                           [ias_certificate_material_record, Key]),
    Invalid = Record0#ias_certificate_material_record{schema_version = 999},
    ok = rpc_ok(Node, kvs, put, [Invalid]),

    Config1 = restart_ias(Config, "ias-invalid-material-schema.log", failure),
    Node1 = proplists:get_value(ias_node, Config1),
    StartResult = rpc_ok(Node1,
                         persistent_term,
                         get,
                         [?START_RESULT_KEY, pending]),
    ?assertMatch({error, _}, StartResult),
    ?assert(contains_term(
              StartResult,
              {unsupported_certificate_material_schema_version, 999})),
    ?assertEqual(undefined, rpc_ok(Node1, erlang, whereis, [ias])),
    ?assertEqual(false,
                 lists:keymember(ias,
                                 1,
                                 rpc_ok(Node1,
                                        application,
                                        which_applications,
                                        []))),
    Port = proplists:get_value(ias_port, Config1),
    ok = wait_for_tcp_closed(Port, 5000),
    ok.

reconciliation_rpc(_VpnNode,
                   vpn_provisioning,
                   recovery_heads,
                   [],
                   _Timeout) ->
    Snapshot = persistent_term:get(?SNAPSHOT_KEY,
                                   #{heads => #{}, registry => []}),
    {ok, maps:get(heads, Snapshot, #{})};
reconciliation_rpc(_VpnNode,
                   vpn_peer_registry,
                   list,
                   [],
                   _Timeout) ->
    Snapshot = persistent_term:get(?SNAPSHOT_KEY,
                                   #{heads => #{}, registry => []}),
    maps:get(registry, Snapshot, []);
reconciliation_rpc(_VpnNode, Module, Function, Args, _Timeout) ->
    erlang:error({unexpected_stage4_reconciliation_rpc,
                  Module,
                  Function,
                  Args}).

stage6d_certificate(Id) ->
    #{id => Id,
      kind => certificate,
      source => certificate_issue_demo,
      name => <<"Stage 6D certificate">>,
      subject => <<"CN=Stage 6D">>,
      issuer => <<"CN=IAS Test CA">>,
      certificate_role => client_certificate,
      certificate_status => trusted,
      private_key_stored => false,
      certificate_body_stored => false,
      ca_body_stored => false}.

stage6d_client_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBZDCCAQqgAwIBAgIUa1wxwBw2MaSaN2Zaqvu/4gWUgDMwCgYIKoZIzj0EAwIw\n"
      "FjEUMBIGA1UEAwwLSUFTIFRlc3QgQ0EwHhcNMjYwNjIxMTIxMzA0WhcNMzYwNjE4\n"
      "MTIxMzA0WjAaMRgwFgYDVQQDDA9JQVMgVGVzdCBDbGllbnQwWTATBgcqhkjOPQIB\n"
      "BggqhkjOPQMBBwNCAAT9brxfCaaU/6LLtCNKICvq1UwQDTH9hS9teBzUhEPuxGcA\n"
      "0wdjEO6F1kR64uUgAoUYOOlIqj31MWH5CcqBwuuxozIwMDAMBgNVHRMBAf8EAjAA\n"
      "MAsGA1UdDwQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAjAKBggqhkjOPQQDAgNI\n"
      "ADBFAiEA2ye4DSJJuQnZ43+peLW5YsQHGEdGx9r1zuCKHxNcY0kCICsBo8QieTgA\n"
      "Iq0sBJ/RxQ+E19tAL+EarYX6zvA00gz9\n"
      "-----END CERTIFICATE-----\n">>.

incompatible_vpn_orphan_recovery_schema_fails_closed(Config) ->
    Node = proplists:get_value(ias_node, Config),
    DeviceId = <<"stage7c-invalid-recovery-schema">>,
    Invalid = #ias_vpn_orphan_recovery_operation{
                 device_id = DeviceId,
                 schema_version = 999},
    ok = rpc_ok(Node, kvs, put, [Invalid]),

    Config1 = restart_ias(Config,
                          "ias-invalid-vpn-orphan-recovery-schema.log",
                          failure),
    Node1 = proplists:get_value(ias_node, Config1),
    StartResult = rpc_ok(Node1,
                         persistent_term,
                         get,
                         [?START_RESULT_KEY, pending]),
    ?assertMatch({error, _}, StartResult),
    ?assert(contains_term(StartResult,
                          {unsupported_schema_version, 999})),
    ?assertEqual(undefined, rpc_ok(Node1, erlang, whereis, [ias])),
    ?assertEqual(undefined, rpc_ok(Node1, ets, info, [ias_demo_store])),
    ?assertEqual(false,
                 lists:keymember(ias,
                                 1,
                                 rpc_ok(Node1,
                                        application,
                                        which_applications,
                                        []))),
    ok = wait_for_tcp_closed(proplists:get_value(ias_port, Config1), 5000),
    ok.

complete_graph() ->
    DeviceId = <<"stage4-wizard-device">>,
    ServiceId = <<"stage4-wizard-service">>,
    CaId = <<"stage4-wizard-ca">>,
    ClientId = <<"stage4-wizard-client-certificate">>,
    PeerId = <<"stage4-wizard-peer">>,
    Binding = #{runtime_peer_id => PeerId,
                vpn_peer => PeerId,
                vpn_allocation_id => <<"stage4-allocation">>,
                vpn_allocator_instance_id => <<"stage4-allocator">>,
                vpn_client_peer_id => PeerId,
                vpn_allocation_slot => 7,
                vpn_allocation_generation => 3,
                vpn_allocation_state => reserved,
                vpn_allocation_persistence => durable,
                vpn_allocation_created_at => 1782500000,
                vpn_dynamic_pair_state => established,
                vpn_dynamic_pair_reconciled_at => 1782500001,
                vpn_runtime_certificate_fingerprint => fingerprint()},
    Device = simple_device(DeviceId, Binding),
    Service = #{id => ServiceId,
                kind => vpn_service,
                source => provisioning_wizard,
                name => <<"Stage 4 OpenVPN">>,
                service => openvpn,
                remote => <<"vpn.stage4.example:1194">>,
                remote_host => <<"vpn.stage4.example">>,
                remote_port => <<"1194">>,
                protocol => <<"udp">>},
    Ca = #{id => CaId,
           kind => certificate,
           source => ca_certificate,
           name => <<"Stage 4 CA">>,
           subject => <<"CN=Stage 4 CA">>,
           issuer => <<"CN=Stage 4 CA">>,
           certificate_role => ca_certificate,
           certificate_status => trusted,
           private_key_stored => false,
           certificate_body_stored => false},
    Client = #{id => ClientId,
               kind => certificate,
               source => certificate_issue_demo,
               name => <<"Stage 4 client certificate">>,
               subject => <<"CN=stage4-client">>,
               issuer => <<"CN=Stage 4 CA">>,
               certificate_role => client_certificate,
               certificate_status => trusted,
               profile_id => administrator,
               profile => administrator,
               fingerprint_sha256 => fingerprint(),
               private_key_stored => false,
               certificate_body_stored => false},
    Relationships = [
        relationship(<<"stage4-device-profile">>,
                     uses_security_profile,
                     device,
                     DeviceId,
                     security_profile,
                     administrator),
        relationship(<<"stage4-device-service">>,
                     uses_service,
                     device,
                     DeviceId,
                     vpn_service,
                     ServiceId),
        relationship(<<"stage4-device-certificate">>,
                     uses_certificate,
                     device,
                     DeviceId,
                     certificate,
                     ClientId),
        relationship(<<"stage4-service-ca">>,
                     uses_ca_certificate,
                     vpn_service,
                     ServiceId,
                     certificate,
                     CaId),
        relationship(<<"stage4-device-policy">>,
                     uses_security_policy,
                     device,
                     DeviceId,
                     security_policy,
                     <<"high_security">>),
        relationship(<<"stage4-certificate-policy">>,
                     uses_security_policy,
                     certificate,
                     ClientId,
                     security_policy,
                     <<"high_security">>)
    ],
    Ids = #{device => DeviceId,
            service => ServiceId,
            ca => CaId,
            client_certificate => ClientId,
            peer => PeerId,
            relationships => [maps:get(relationship_id, R)
                              || R <- Relationships]},
    {[Device, Service, Ca, Client], Relationships, Ids, Binding}.

simple_device(Id, Binding) ->
    maps:merge(
      #{id => Id,
        kind => device,
        source => provisioning_wizard,
        owner => alice,
        name => <<"Stage 4 persisted laptop">>,
        type => <<"vpn-client">>,
        endpoint => <<"vpn.stage4.example:1194">>,
        transport => udp,
        tunnel_device => tun,
        private_key_provider => <<"device_file">>,
        private_key_ref => <<"client.key">>,
        private_key_stored => false,
        certificate_body_stored => false,
        ca_body_stored => false},
      Binding).

relationship(Id, Type, SourceKind, SourceId, TargetKind, TargetId) ->
    #{relationship_id => Id,
      relation_type => Type,
      source_kind => SourceKind,
      source_id => SourceId,
      target_kind => TargetKind,
      target_id => TargetId}.

graph_ids(Ids) ->
    [maps:get(device, Ids),
     maps:get(service, Ids),
     maps:get(ca, Ids),
     maps:get(client_certificate, Ids)] ++ maps:get(relationships, Ids).

provisioning_command(DeviceId, PeerId) ->
    #{peer_id => PeerId,
      operation => upsert,
      source => ias,
      desired_state => #{device_id => DeviceId,
                         profile_id => administrator,
                         authorization_mode => policy,
                         authorized => true,
                         authorization_reason => stage4_restart_test,
                         certificate_fingerprint => fingerprint(),
                         enabled => true,
                         revoked => false}}.

stage7c_recovery_command(DeviceId, PeerId, Manifest) ->
    #{peer_id => PeerId,
      revision => 5,
      operation => upsert,
      source => ias,
      desired_state => #{device_id => DeviceId,
                         profile_id => default_user,
                         authorization_mode => policy,
                         authorized => true,
                         authorization_reason => stage7c_recovery_test,
                         certificate_fingerprint => fingerprint(),
                         enabled => true,
                         revoked => false,
                         recovery_manifest => Manifest}}.

stage7c_orphan_snapshot(DeviceId, PeerId, Command) ->
    Desired = maps:get(desired_state, Command),
    Head = #{revision => maps:get(revision, Command),
             digest_version =>
                 ias_vpn_provisioning_command_digest:schema_version(),
             digest => ias_vpn_provisioning_command_digest:digest(Command),
             phase => applied,
             operation => maps:get(operation, Command),
             source => ias,
             lifecycle_state => active,
             desired_state => Desired,
             updated_at => 1782500100,
             durable => true},
    Registry = [#{id => PeerId,
                  device_id => DeviceId,
                  enabled => true,
                  provisioning_source => ias,
                  profile_id => default_user,
                  authorization_mode => policy,
                  authorized => true,
                  authorization_reason => stage7c_recovery_test,
                  certificate_fingerprint => fingerprint(),
                  revision => maps:get(revision, Command),
                  revoked => false,
                  last_provisioning_operation => upsert,
                  updated_at => 1782500100}],
    #{heads => #{PeerId => Head}, registry => Registry}.

stage7c_recovery_manifest(DeviceId) ->
    CertificateId = <<DeviceId/binary, "-certificate">>,
    ServiceId = <<DeviceId/binary, "-service">>,
    Device = #{kind => device,
               id => DeviceId,
               name => <<"Recovered Stage 7C device">>},
    Certificate = #{kind => certificate,
                    id => CertificateId,
                    fingerprint_sha256 => fingerprint()},
    Service = #{kind => vpn_service,
                id => ServiceId,
                remote_host => <<"vpn.example.test">>,
                remote_port => 1194,
                protocol => udp},
    #{schema_version => 1,
      device => Device,
      certificate => Certificate,
      vpn_service => Service,
      objects => [Device, Certificate, Service],
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

reconciliation_snapshot(DeviceId, PeerId, Command) ->
    Desired = maps:get(desired_state, Command),
    Head = #{revision => maps:get(revision, Command),
             digest_version =>
                 ias_vpn_provisioning_command_digest:schema_version(),
             digest => ias_vpn_provisioning_command_digest:digest(Command),
             phase => applied,
             operation => maps:get(operation, Command),
             source => ias,
             lifecycle_state => active,
             desired_state => Desired,
             updated_at => 1782500010,
             durable => true},
    Registry = [#{id => PeerId,
                  device_id => DeviceId,
                  enabled => true,
                  provisioning_source => ias,
                  profile_id => administrator,
                  authorization_mode => policy,
                  authorized => true,
                  authorization_reason => stage4_restart_test,
                  certificate_fingerprint => fingerprint(),
                  revision => maps:get(revision, Command),
                  revoked => false,
                  last_provisioning_operation => upsert,
                  updated_at => 1782500010}],
    #{heads => #{PeerId => Head}, registry => Registry}.

install_reconciliation_snapshot(Node, Snapshot) ->
    ok = rpc_ok(Node, persistent_term, put, [?SNAPSHOT_KEY, Snapshot]),
    Fun = fun ?MODULE:reconciliation_rpc/5,
    ok = rpc_ok(Node,
                application,
                set_env,
                [ias, vpn_provisioning_transport, erlang_rpc]),
    ok = rpc_ok(Node,
                application,
                set_env,
                [ias, vpn_provisioning_rpc_fun, Fun]),
    ok.

assert_reconciliation_synchronized(Report, DeviceId) ->
    ?assertEqual(synchronized, maps:get(state, Report)),
    ?assertEqual(0, maps:get(orphan_records, Report)),
    ?assertEqual(1, maps:get(authority_records, Report)),
    [Entry] = maps:get(entries, Report),
    ?assertEqual(DeviceId, maps:get(device_id, Entry)),
    ?assertEqual(synchronized, maps:get(status, Entry)).

assert_synchronized_hashes(Health) ->
    ?assertEqual(synchronized, maps:get(status, Health)),
    ?assertEqual(sha256, maps:get(projection_hash_algorithm, Health)),
    DurableHash = maps:get(durable_projection_hash, Health),
    RuntimeHash = maps:get(ets_projection_hash, Health),
    ?assert(is_binary(DurableHash)),
    ?assertEqual(64, byte_size(DurableHash)),
    ?assertEqual(DurableHash, RuntimeHash).

assert_stable_single_object(Health, Hash) ->
    assert_synchronized_hashes(Health),
    ?assertEqual(1, maps:get(durable_objects, Health)),
    ?assertEqual(0, maps:get(durable_relationships, Health)),
    ?assertEqual(1, maps:get(ets_projection_total, Health)),
    ?assertEqual(Hash, maps:get(durable_projection_hash, Health)).

fingerprint() ->
    <<"0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF">>.

restart_ias(Config, LogName, Expected) ->
    Node = proplists:get_value(ias_node, Config),
    Process = proplists:get_value(ias_process, Config),
    ok = stop_ias(Node, Process),
    IasRepo = proplists:get_value(ias_repo, Config),
    ConfigPath = proplists:get_value(ias_runtime_config, Config),
    MnesiaDir = proplists:get_value(ias_mnesia_dir, Config),
    LogPath = filename:join(filename:dirname(
                              proplists:get_value(ias_log, Config)),
                            LogName),
    {ok, NewProcess, StartResult} =
        start_ias(IasRepo, Node, ConfigPath, MnesiaDir, LogPath),
    track_ias_process(Node, NewProcess),
    case Expected of
        success ->
            ?assertMatch({ok, _}, StartResult),
            ok = wait_for_tcp_open(proplists:get_value(ias_port, Config),
                                   ?STARTUP_TIMEOUT_MS);
        failure ->
            ?assertMatch({error, _}, StartResult),
            ok = wait_for_tcp_closed(proplists:get_value(ias_port, Config),
                                     5000)
    end,
    lists:keystore(ias_log,
                   1,
                   lists:keystore(ias_process, 1, Config,
                                  {ias_process, NewProcess}),
                   {ias_log, LogPath}).

track_ias_process(Node, Process) ->
    persistent_term:put({?MODULE, current_ias_process, Node}, Process),
    ok.

current_ias_process(Node, Fallback) ->
    persistent_term:get({?MODULE, current_ias_process, Node}, Fallback).

clear_tracked_ias_process(Node) ->
    persistent_term:erase({?MODULE, current_ias_process, Node}),
    ok.

start_ias(IasRepo, Node, ConfigPath, MnesiaDir, LogPath) ->
    Parent = self(),
    Process = spawn(fun() ->
                            ias_process_owner(Parent,
                                              IasRepo,
                                              Node,
                                              ConfigPath,
                                              MnesiaDir,
                                              LogPath)
                    end),
    receive
        {ias_process_started, Process} ->
            ok;
        {ias_process_failed, Process, Reason2} ->
            ct:fail({ias_process_spawn_failed, Reason2})
    after 10000 ->
        exit(Process, kill),
        ct:fail({ias_process_spawn_timeout, LogPath})
    end,
    case wait_for_node(Node, ?STARTUP_TIMEOUT_MS) of
        ok ->
            case wait_for_start_result(Node, ?STARTUP_TIMEOUT_MS) of
                {ok, StartResult} -> {ok, Process, StartResult};
                {error, Reason} ->
                    _ = stop_ias_process(Process),
                    ct:fail({ias_start_result_timeout,
                             Reason,
                             read_log(LogPath)})
            end;
        {error, Reason} ->
            _ = stop_ias_process(Process),
            ct:fail({ias_node_start_timeout, Reason, read_log(LogPath)})
    end.

ias_process_owner(Parent,
                  IasRepo,
                  Node,
                  ConfigPath,
                  MnesiaDir,
                  LogPath) ->
    process_flag(trap_exit, true),
    case file:open(LogPath, [write, raw, binary]) of
        {ok, Log} ->
            try
                Erl = require_executable("erl"),
                Args = ["-noshell",
                        "-noinput",
                        "-name", atom_to_list(Node),
                        "-setcookie", atom_to_list(?COOKIE),
                        "-config", filename:rootname(ConfigPath),
                        "-mnesia", "dir", erl_term_argument(MnesiaDir)]
                       ++ code_path_args(ias_code_paths(IasRepo))
                       ++ ["-eval", ias_start_expression()],
                Port = open_port({spawn_executable, Erl},
                                 [{args, Args},
                                  {cd, IasRepo},
                                  binary,
                                  exit_status,
                                  stderr_to_stdout,
                                  use_stdio]),
                OsPid = case erlang:port_info(Port, os_pid) of
                            {os_pid, Value} -> Value;
                            undefined -> undefined
                        end,
                Parent ! {ias_process_started, self()},
                ias_process_loop(Port, Log, OsPid)
            catch
                Class:Reason:Stacktrace ->
                    Parent ! {ias_process_failed,
                              self(),
                              {Class, Reason, Stacktrace}}
            after
                file:close(Log)
            end;
        {error, Reason} ->
            Parent ! {ias_process_failed,
                      self(),
                      {ias_log_open_failed, LogPath, Reason}}
    end.

ias_start_expression() ->
    "Result = application:ensure_all_started(ias), " ++
    "persistent_term:put({ias_persistence_ct,start_result}, Result), " ++
    "io:format(standard_error, \"IAS persistence CT start result: ~p~n\", [Result]), " ++
    "receive after infinity -> ok end.".

ias_process_loop(Port, Log, OsPid) ->
    receive
        {Port, {data, Data}} ->
            ok = file:write(Log, Data),
            ias_process_loop(Port, Log, OsPid);
        {Port, {exit_status, Status}} ->
            ok = file:write(Log,
                            iolist_to_binary(
                              io_lib:format("~nIAS exited with status ~p~n",
                                            [Status]))),
            ok;
        stop ->
            _ = catch port_close(Port),
            _ = terminate_os_process(OsPid),
            ok;
        {'EXIT', Port, _Reason} ->
            _ = terminate_os_process(OsPid),
            ok
    end.

stop_ias(Node, Process0) ->
    Process = current_ias_process(Node, Process0),
    _ = rpc:call(Node, init, stop, [], 2000),
    _ = wait_for_node_down(Node, 5000),
    ok = stop_ias_process(Process),
    clear_tracked_ias_process(Node).

stop_ias_process(Process) when is_pid(Process) ->
    Monitor = erlang:monitor(process, Process),
    Process ! stop,
    receive
        {'DOWN', Monitor, process, Process, _Reason} -> ok
    after 3000 ->
        exit(Process, kill),
        receive
            {'DOWN', Monitor, process, Process, _Reason} -> ok
        after 1000 -> ok
        end
    end;
stop_ias_process(_) ->
    ok.

wait_for_start_result(Node, TimeoutMs) ->
    StartedAt = erlang:monotonic_time(millisecond),
    wait_for_start_result(Node, TimeoutMs, StartedAt).

wait_for_start_result(Node, TimeoutMs, StartedAt) ->
    case rpc:call(Node,
                  persistent_term,
                  get,
                  [?START_RESULT_KEY, pending],
                  ?RPC_TIMEOUT_MS) of
        pending ->
            wait_or_timeout(fun() -> wait_for_start_result(Node,
                                                           TimeoutMs,
                                                           StartedAt)
                            end,
                            TimeoutMs,
                            StartedAt,
                            pending);
        {badrpc, Reason} ->
            wait_or_timeout(fun() -> wait_for_start_result(Node,
                                                           TimeoutMs,
                                                           StartedAt)
                            end,
                            TimeoutMs,
                            StartedAt,
                            {badrpc, Reason});
        Result ->
            {ok, Result}
    end.

wait_or_timeout(Retry, TimeoutMs, StartedAt, Last) ->
    case erlang:monotonic_time(millisecond) - StartedAt >= TimeoutMs of
        true -> {error, {timeout, Last}};
        false -> timer:sleep(100), Retry()
    end.

write_runtime_config(IasRepo, Path, Port) ->
    {ok, [Config0]} = file:consult(filename:join(IasRepo, "sys.config")),
    Config1 = set_app_env(Config0, n2o, port, Port),
    Config2 = set_app_env(Config1,
                          ias,
                          vpn_provisioning_transport,
                          disabled),
    ok = filelib:ensure_dir(Path),
    file:write_file(Path,
                    iolist_to_binary(io_lib:format("~tp.~n", [Config2]))).

set_app_env(Config, App, Key, Value) ->
    Env0 = proplists:get_value(App, Config, []),
    Env = lists:keystore(Key, 1, Env0, {Key, Value}),
    lists:keystore(App, 1, Config, {App, Env}).

testcase_runtime_root(TestCase, Config) ->
    PrivDir = proplists:get_value(priv_dir, Config, "_build/test/logs"),
    filename:join(PrivDir, atom_to_list(TestCase)).

testcase_node(TestCase) ->
    list_to_atom("ias_persistence_" ++ atom_to_list(TestCase) ++
                 "@127.0.0.1").

ias_repo_from_env() ->
    case os:getenv("IAS_REPO") of
        false -> discover_ias_repo();
        Value -> Value
    end.

discover_ias_repo() ->
    {ok, Cwd} = file:get_cwd(),
    BeamCandidates = case code:which(ias) of
                         non_existing -> [];
                         BeamPath when is_list(BeamPath) ->
                             [filename:dirname(BeamPath)]
                     end,
    %% Rebar may expose the project application through a path below _build.
    %% Prefer the Common Test working tree so a build copy is not mistaken for
    %% the source checkout and used as the base for another nested _build path.
    case first_repo_root([Cwd | BeamCandidates]) of
        {ok, Root} -> Root;
        not_found -> Cwd
    end.

first_repo_root([]) ->
    not_found;
first_repo_root([Path | Rest]) ->
    case find_repo_root(Path, 10) of
        {ok, _} = Found -> Found;
        not_found -> first_repo_root(Rest)
    end.

find_repo_root(_Path, 0) ->
    not_found;
find_repo_root(Path, Attempts) ->
    case filelib:is_regular(filename:join(Path, "rebar.config")) andalso
         filelib:is_regular(filename:join(Path, "sys.config")) of
        true -> {ok, Path};
        false ->
            Parent = filename:dirname(Path),
            case Parent =:= Path of
                true -> not_found;
                false -> find_repo_root(Parent, Attempts - 1)
            end
    end.

validate_ias_repo(IasRepo) ->
    Required = [filename:join(IasRepo, "rebar.config"),
                filename:join(IasRepo, "sys.config")],
    case [Path || Path <- Required, not filelib:is_regular(Path)] of
        [] -> ok;
        Missing -> ct:fail({invalid_ias_repo, IasRepo, Missing})
    end.

reset_runtime_root(RuntimeRoot) ->
    case file:del_dir_r(RuntimeRoot) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} -> ct:fail({runtime_root_reset_failed,
                                    RuntimeRoot,
                                    Reason})
    end,
    filelib:ensure_dir(filename:join(RuntimeRoot, "placeholder")).

ensure_no_conflicting_node(Node) ->
    case net_adm:ping(Node) of
        pang -> ok;
        pong ->
            _ = rpc:call(Node, init, stop, [], 1000),
            case wait_for_node_down(Node, 5000) of
                ok -> ok;
                {error, Reason} -> ct:fail({stale_ias_persistence_node,
                                            Node,
                                            Reason})
            end
    end.

ensure_distributed_controller() ->
    case node() of
        nonode@nohost ->
            case net_kernel:start(['ias_persistence_controller@127.0.0.1',
                                   longnames]) of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                Other -> ct:fail({cannot_start_distributed_controller, Other})
            end;
        _ -> ok
    end.

ias_code_paths(IasRepo) ->
    TestPatterns = profile_code_path_patterns(IasRepo, "test"),
    DefaultPatterns = profile_code_path_patterns(IasRepo, "default"),
    %% A partially populated test profile must not hide the default profile:
    %% the application descriptor can still live in the latter while CT beams
    %% are loaded from the former.
    ProfilePaths = wildcard_paths(TestPatterns ++ DefaultPatterns),
    CurrentTestPath = case code:which(?MODULE) of
                          non_existing -> [];
                          BeamPath -> [filename:dirname(BeamPath)]
                      end,
    Paths = unique_paths(ProfilePaths ++ CurrentTestPath),
    AppPaths = [Path || Path <- Paths,
                        filelib:is_regular(filename:join(Path, "ias.app"))],
    case {Paths, AppPaths} of
        {[], _} ->
            ct:fail({ias_code_paths_missing,
                     TestPatterns ++ DefaultPatterns});
        {_, []} ->
            ct:fail({ias_application_descriptor_missing,
                     IasRepo,
                     Paths});
        {_, _} ->
            Paths
    end.

profile_code_path_patterns(IasRepo, Profile) ->
    %% rebar3 normally uses _build/<profile>/lib, but this project keeps the
    %% historical {deps_dir, "deps"} layout. Support both so the detached IAS
    %% VM receives the application descriptor as well as every dependency.
    lists:append(
      [[filename:join([IasRepo, "_build", Profile, Container, "*", "ebin"]),
        filename:join([IasRepo, "_build", Profile, Container, "*", "test"])]
       || Container <- ["lib", "deps"]]).

wildcard_paths(Patterns) ->
    lists:append([filelib:wildcard(Pattern) || Pattern <- Patterns]).

unique_paths(Paths) ->
    lists:reverse(
      lists:foldl(fun(Path, Acc) ->
                          case lists:member(Path, Acc) of
                              true -> Acc;
                              false -> [Path | Acc]
                          end
                  end,
                  [],
                  Paths)).

code_path_args(Paths) ->
    %% Each later -pa is prepended by erl. Pass lower-priority fallback paths
    %% first so the freshly compiled test profile remains ahead of default.
    lists:append([["-pa", Path] || Path <- lists:reverse(Paths)]).

rpc_ok(Node, Module, Function, Args) ->
    case rpc:call(Node, Module, Function, Args, ?RPC_TIMEOUT_MS) of
        {badrpc, Reason} -> ct:fail({ias_rpc_failed,
                                    Node,
                                    Module,
                                    Function,
                                    Reason});
        Result -> Result
    end.

free_tcp_port() ->
    {ok, Socket} = gen_tcp:listen(0,
                                  [binary,
                                   {active, false},
                                   {reuseaddr, true},
                                   {ip, {127,0,0,1}}]),
    {ok, {_Address, Port}} = inet:sockname(Socket),
    ok = gen_tcp:close(Socket),
    Port.

wait_for_tcp_open(Port, TimeoutMs) ->
    wait_for_tcp_state(Port, open, TimeoutMs,
                       erlang:monotonic_time(millisecond)).

wait_for_tcp_closed(Port, TimeoutMs) ->
    wait_for_tcp_state(Port, closed, TimeoutMs,
                       erlang:monotonic_time(millisecond)).

wait_for_tcp_state(Port, Expected, TimeoutMs, StartedAt) ->
    State = case gen_tcp:connect({127,0,0,1},
                                 Port,
                                 [binary, {active, false}],
                                 250) of
                {ok, Socket} -> ok = gen_tcp:close(Socket), open;
                {error, _} -> closed
            end,
    case State =:= Expected of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) - StartedAt >= TimeoutMs of
                true -> {error, {tcp_state_timeout, Port, Expected, State}};
                false -> timer:sleep(100),
                         wait_for_tcp_state(Port,
                                            Expected,
                                            TimeoutMs,
                                            StartedAt)
            end
    end.

wait_for_node(Node, TimeoutMs) ->
    wait_for_node(Node, TimeoutMs, erlang:monotonic_time(millisecond)).

wait_for_node(Node, TimeoutMs, StartedAt) ->
    case net_adm:ping(Node) of
        pong -> ok;
        pang ->
            case erlang:monotonic_time(millisecond) - StartedAt >= TimeoutMs of
                true -> {error, timeout};
                false -> timer:sleep(100),
                         wait_for_node(Node, TimeoutMs, StartedAt)
            end
    end.

wait_for_node_down(Node, TimeoutMs) ->
    wait_for_node_down(Node, TimeoutMs,
                       erlang:monotonic_time(millisecond)).

wait_for_node_down(Node, TimeoutMs, StartedAt) ->
    case net_adm:ping(Node) of
        pang -> ok;
        pong ->
            case erlang:monotonic_time(millisecond) - StartedAt >= TimeoutMs of
                true -> {error, timeout};
                false -> timer:sleep(100),
                         wait_for_node_down(Node, TimeoutMs, StartedAt)
            end
    end.

require_executable(Name) ->
    case os:find_executable(Name) of
        false -> erlang:error({executable_not_found, Name});
        Path -> Path
    end.

erl_term_argument(Term) ->
    lists:flatten(io_lib:format("~tp", [Term])).

terminate_os_process(undefined) ->
    ok;
terminate_os_process(OsPid) when is_integer(OsPid) ->
    _ = os:cmd("kill -TERM " ++ integer_to_list(OsPid) ++ " 2>/dev/null || true"),
    ok.

contains_term(Term, Expected) when Term =:= Expected ->
    true;
contains_term(Term, Expected) when is_tuple(Term) ->
    lists:any(fun(Item) -> contains_term(Item, Expected) end,
              tuple_to_list(Term));
contains_term(Term, Expected) when is_list(Term) ->
    lists:any(fun(Item) -> contains_term(Item, Expected) end, Term);
contains_term(Term, Expected) when is_map(Term) ->
    lists:any(fun({Key, Value}) ->
                      contains_term(Key, Expected) orelse
                      contains_term(Value, Expected)
              end,
              maps:to_list(Term));
contains_term(_Term, _Expected) ->
    false.

read_log(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> Binary;
        {error, Reason} -> {log_unavailable, Reason}
    end.
