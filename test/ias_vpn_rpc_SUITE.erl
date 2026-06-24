-module(ias_vpn_rpc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0,
         init_per_suite/1,
         init_per_testcase/2,
         end_per_suite/1,
         provisioning_lifecycle/1,
         provisioning_identity_and_revision_guards/1,
         provisioned_peer_transfers_dataplane_payload/1,
         dataplane_survives_authenticated_rekey/1,
         dataplane_recovers_after_peer_restart/1,
         replayed_dataplane_frame_is_rejected/1,
         previous_epoch_expires_after_grace_window/1,
         out_of_order_frames_within_replay_window_are_accepted/1,
         wizard_provisions_device_into_vpn_runtime/1]).

-define(VPN_NODE, 'vpn_ct@127.0.0.1').
-define(COOKIE, ias_vpn_ct_cookie).
-define(STARTUP_TIMEOUT_MS, 30000).
-define(RPC_TIMEOUT_MS, 5000).

all() ->
    [provisioning_lifecycle,
     provisioning_identity_and_revision_guards,
     provisioned_peer_transfers_dataplane_payload,
     dataplane_survives_authenticated_rekey,
     dataplane_recovers_after_peer_restart,
     replayed_dataplane_frame_is_rejected,
     previous_epoch_expires_after_grace_window,
     out_of_order_frames_within_replay_window_are_accepted,
     wizard_provisions_device_into_vpn_runtime].

init_per_suite(Config) ->
    ok = ensure_distributed_controller(),
    true = erlang:set_cookie(node(), ?COOKIE),
    ok = ensure_ias_test_runtime(),
    VpnRepo = vpn_repo(Config),
    ok = validate_vpn_repo(VpnRepo),
    ok = ensure_no_conflicting_vpn_node(),
    ok = ensure_vpn_test_ports_available(),
    LogPath = filename:join([cwd(), "_build", "test", "logs", "ias_vpn_rpc", "vpn.log"]),
    ok = filelib:ensure_dir(LogPath),
    ok = prepare_vpn(VpnRepo),
    {ok, VpnProcess} = start_vpn(VpnRepo, LogPath),
    case wait_for_vpn_ready(?VPN_NODE, VpnProcess, ?STARTUP_TIMEOUT_MS) of
        ok ->
            {ok, RuntimeTemplates} = configure_vpn_test_runtime(?VPN_NODE),
            application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
            application:set_env(ias, vpn_provisioning_vpn_node, ?VPN_NODE),
            application:set_env(ias, vpn_provisioning_rpc_timeout, ?RPC_TIMEOUT_MS),
            application:set_env(ias, vpn_dynamic_allocation_reservation, true),
            application:set_env(ias, vpn_dynamic_pair_delivery, true),
            application:set_env(ias, vpn_dynamic_pair_rpc_timeout, 30000),
            application:set_env(ias, vpn_provisioning_runtime_peer_id, client_a),
            application:set_env(ias, vpn_provisioning_runtime_peer_slots,
                                #{alice => client_a, bob => client_b}),
            [{vpn_repo, VpnRepo},
             {vpn_node, ?VPN_NODE},
             {vpn_process, VpnProcess},
             {vpn_log, LogPath},
             {vpn_runtime_templates, RuntimeTemplates} | Config];
        {error, Reason} ->
            _ = stop_vpn_process(VpnProcess),
            ct:fail({vpn_startup_failed, Reason, read_log(LogPath)})
    end.

configure_vpn_test_runtime(VpnNode) ->
    case rpc:call(VpnNode,
                  application,
                  get_env,
                  [vpn, runtime_config_templates],
                  ?RPC_TIMEOUT_MS) of
        {ok, Templates} when is_map(Templates) ->
            case maps:find(client_a, Templates) of
                {ok, ClientATemplate} when is_map(ClientATemplate) ->
                    DynamicTemplate =
                        ClientATemplate#{id => ias_ct_dynamic_template,
                                         ifname => <<"tun11">>,
                                         ip => "10.20.30.11",
                                         local_udp_port => 5561},
                    ok = rpc:call(VpnNode,
                                  application,
                                  unset_env,
                                  [vpn, runtime_config_templates],
                                  ?RPC_TIMEOUT_MS),
                    ok = rpc:call(VpnNode,
                                  application,
                                  set_env,
                                  [vpn, runtime_config_template, DynamicTemplate],
                                  ?RPC_TIMEOUT_MS),
                    {ok, Templates};
                _ ->
                    ct:fail({vpn_client_a_template_missing, Templates})
            end;
        undefined ->
            {ok, undefined};
        {badrpc, Reason} ->
            ct:fail({vpn_test_runtime_config_failed, Reason});
        Other ->
            ct:fail({invalid_vpn_runtime_templates, Other})
    end.

init_per_testcase(wizard_provisions_device_into_vpn_runtime, Config) ->
    VpnNode = proplists:get_value(vpn_node, Config, ?VPN_NODE),
    Templates = proplists:get_value(vpn_runtime_templates, Config, undefined),
    ok = restore_vpn_slot_templates(VpnNode, Templates),
    Config;
init_per_testcase(_TestCase, Config) ->
    Config.

restore_vpn_slot_templates(_VpnNode, undefined) ->
    ok;
restore_vpn_slot_templates(VpnNode, Templates) when is_map(Templates) ->
    ok = rpc:call(VpnNode,
                  application,
                  unset_env,
                  [vpn, runtime_config_template],
                  ?RPC_TIMEOUT_MS),
    ok = rpc:call(VpnNode,
                  application,
                  set_env,
                  [vpn, runtime_config_templates, Templates],
                  ?RPC_TIMEOUT_MS),
    ok.

end_per_suite(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config, ?VPN_NODE),
    _ = rpc:call(VpnNode, init, stop, [], ?RPC_TIMEOUT_MS),
    timer:sleep(500),
    case proplists:get_value(vpn_process, Config) of
        undefined -> ok;
        Process -> _ = stop_vpn_process(Process)
    end,
    application:unset_env(ias, vpn_provisioning_transport),
    application:unset_env(ias, vpn_provisioning_vpn_node),
    application:unset_env(ias, vpn_provisioning_rpc_timeout),
    application:unset_env(ias, vpn_dynamic_allocation_reservation),
    application:unset_env(ias, vpn_dynamic_pair_delivery),
    application:unset_env(ias, vpn_dynamic_pair_rpc_timeout),
    application:unset_env(ias, vpn_provisioning_runtime_peer_id),
    application:unset_env(ias, vpn_provisioning_runtime_peer_slots),
    ok.

provisioning_lifecycle(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config),
    pong = net_adm:ping(VpnNode),
    {ok, ClientAEntry} = rpc:call(VpnNode,
                                  vpn_peer_registry,
                                  get,
                                  [client_a],
                                  ?RPC_TIMEOUT_MS),
    ActualFingerprint = maps:get(certificate_fingerprint, ClientAEntry),
    DeviceId = unique_id(<<"ias_ct_device_">>),
    ok = reset_ias_state(),
    allow = prepare_authorized_device(DeviceId, ActualFingerprint),

    {ok, UpsertResult} = ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, upsert),
    UpsertCommand = maps:get(command, UpsertResult),
    UpsertDelivery = maps:get(delivery, UpsertResult),
    ?assertEqual(applied, maps:get(delivery_status, UpsertDelivery)),
    ?assertEqual(1, maps:get(revision, UpsertCommand)),
    timer:sleep(500),

    {ok, RegistryAfterUpsert} = rpc:call(VpnNode,
                                         vpn_peer_registry,
                                         get,
                                         [DeviceId],
                                         ?RPC_TIMEOUT_MS),
    ?assertEqual(ActualFingerprint,
                 maps:get(certificate_fingerprint, RegistryAfterUpsert)),
    ?assert(lists:member(DeviceId, running_peers(VpnNode))),

    {ok, RepeatedDelivery} = ias_vpn_provisioning_delivery:deliver(UpsertCommand),
    ?assertEqual(unchanged, maps:get(delivery_status, RepeatedDelivery)),
    ?assertEqual(1, maps:get(revision, RepeatedDelivery)),

    {ok, DisableResult} = ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, disable),
    ?assertEqual(applied, delivery_status(DisableResult)),
    ?assertEqual(2, command_revision(DisableResult)),
    timer:sleep(300),
    ?assertNot(lists:member(DeviceId, running_peers(VpnNode))),

    {ok, EnableResult} = ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, enable),
    ?assertEqual(applied, delivery_status(EnableResult)),
    ?assertEqual(3, command_revision(EnableResult)),
    timer:sleep(500),
    ?assert(lists:member(DeviceId, running_peers(VpnNode))),

    {ok, RevokeResult} = ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, revoke),
    ?assertEqual(applied, delivery_status(RevokeResult)),
    ?assertEqual(4, command_revision(RevokeResult)),
    timer:sleep(300),
    {ok, RegistryAfterRevoke} = rpc:call(VpnNode,
                                         vpn_peer_registry,
                                         get,
                                         [DeviceId],
                                         ?RPC_TIMEOUT_MS),
    ?assertEqual(false, maps:get(enabled, RegistryAfterRevoke)),
    ?assertEqual(false, maps:get(authorized, RegistryAfterRevoke)),
    ?assertEqual(true, maps:get(revoked, RegistryAfterRevoke)),
    ?assertEqual(certificate_revoked,
                 maps:get(authorization_reason, RegistryAfterRevoke)),
    ?assertNot(lists:member(DeviceId, running_peers(VpnNode))),

    {ok, RejectedEnableResult} =
        ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, enable),
    ?assertEqual(rejected, delivery_status(RejectedEnableResult)),
    ?assertEqual(5, command_revision(RejectedEnableResult)),
    ?assertEqual({error, revoked},
                 maps:get(vpn_result, maps:get(delivery, RejectedEnableResult))),
    ?assertNot(lists:member(DeviceId, running_peers(VpnNode))),

    History = ias_vpn_provisioning_delivery:history(DeviceId),
    ?assertEqual(6, length(History)),
    ?assertEqual(false, history_contains(History, <<"private_key">>)),
    ?assertEqual(false, history_contains(History, <<"ovpn">>)),
    ?assertEqual(false, history_contains(History, <<"session_key">>)),
    ?assertEqual(false, history_contains(History, <<"ecdh">>)),

    Status = ias_vpn_provisioning_delivery:status(DeviceId),
    ?assertEqual(6, maps:get(attempts, Status)),
    ?assertEqual(5, maps:get(current_revision, Status)),
    ?assertEqual(rejected, maps:get(last_delivery_status, Status)),
    ok.

provisioning_identity_and_revision_guards(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config),
    pong = net_adm:ping(VpnNode),
    ActualFingerprint = actual_vpn_fingerprint(VpnNode),

    MismatchedDeviceId = unique_id(<<"ias_ct_bad_fingerprint_">>),
    ok = reset_ias_state(),
    allow = prepare_authorized_device(MismatchedDeviceId,
                                      <<"00:11:22:33:44:55:66:77">>),
    {ok, MismatchResult} =
        ias_vpn_provisioning_delivery:build_and_deliver(MismatchedDeviceId, upsert),
    ?assertEqual(rejected, delivery_status(MismatchResult)),
    ?assertEqual({error, certificate_fingerprint_mismatch},
                 maps:get(vpn_result, maps:get(delivery, MismatchResult))),
    ?assertNot(lists:member(MismatchedDeviceId, running_peers(VpnNode))),

    DeviceId = unique_id(<<"ias_ct_revision_guard_">>),
    ok = reset_ias_state(),
    allow = prepare_authorized_device(DeviceId, ActualFingerprint),

    {ok, UpsertResult} = ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, upsert),
    UpsertCommand = maps:get(command, UpsertResult),
    ?assertEqual(applied, delivery_status(UpsertResult)),
    ?assertEqual(1, command_revision(UpsertResult)),
    timer:sleep(300),
    ?assert(lists:member(DeviceId, running_peers(VpnNode))),

    {ok, DisableResult} = ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, disable),
    ?assertEqual(applied, delivery_status(DisableResult)),
    ?assertEqual(2, command_revision(DisableResult)),
    timer:sleep(300),
    ?assertNot(lists:member(DeviceId, running_peers(VpnNode))),

    {ok, StaleDelivery} = ias_vpn_provisioning_delivery:deliver(UpsertCommand),
    ?assertEqual(rejected, maps:get(delivery_status, StaleDelivery)),
    ?assertEqual({error, stale_revision}, maps:get(vpn_result, StaleDelivery)),

    {ok, RegistryAfterStale} = rpc:call(VpnNode,
                                        vpn_peer_registry,
                                        get,
                                        [DeviceId],
                                        ?RPC_TIMEOUT_MS),
    ?assertEqual(2, maps:get(revision, RegistryAfterStale)),
    ?assertEqual(false, maps:get(enabled, RegistryAfterStale)),
    ?assertNot(lists:member(DeviceId, running_peers(VpnNode))),

    History = ias_vpn_provisioning_delivery:history(DeviceId),
    ?assertEqual(3, length(History)),
    [Latest | _] = History,
    ?assertEqual(rejected, maps:get(delivery_status, Latest)),
    ?assertEqual(1, maps:get(revision, Latest)),
    ?assertEqual(false, history_contains(History, <<"private_key">>)),
    ?assertEqual(false, history_contains(History, <<"session_key">>)),
    ok.

provisioned_peer_transfers_dataplane_payload(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config),
    pong = net_adm:ping(VpnNode),
    ActualFingerprint = actual_vpn_fingerprint(VpnNode),
    DeviceId = unique_id(<<"ias_ct_dataplane_">>),
    Payload = <<"ias-vpn-dataplane-probe">>,
    ExpectedDigest = crypto:hash(sha256, Payload),

    ok = reset_ias_state(),
    allow = prepare_authorized_peer(DeviceId, client_a, ActualFingerprint),
    {ok, UpsertResult} =
        ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, upsert),
    ?assertEqual(applied, delivery_status(UpsertResult)),
    ?assertEqual(1, command_revision(UpsertResult)),
    timer:sleep(500),
    ?assert(lists:member(client_a, running_peers(VpnNode))),

    ok = rpc:call(VpnNode,
                  vpn_manager,
                  debug_clear_received_payloads,
                  [peer_b],
                  ?RPC_TIMEOUT_MS),
    {ok, Sent} = rpc:call(VpnNode,
                          vpn_manager,
                          debug_send_payload,
                          [client_a, Payload],
                          ?RPC_TIMEOUT_MS),
    ?assertEqual(true, maps:get(sent, Sent)),
    ?assertEqual(byte_size(Payload), maps:get(bytes, Sent)),
    ?assertEqual(ExpectedDigest, maps:get(sha256, Sent)),

    {ok, Received} = wait_for_received_payload(VpnNode, peer_b, Payload, 5000),
    ?assertEqual(Payload, maps:get(payload, Received)),
    ?assertEqual(byte_size(Payload), maps:get(bytes, Received)),
    ?assertEqual(ExpectedDigest, maps:get(sha256, Received)),
    ?assertEqual(<<"client_a">>, maps:get(peer_id, Received)),
    ?assertEqual(maps:get(key_epoch, Sent), maps:get(key_epoch, Received)),
    ?assertEqual(maps:get(seq, Sent), maps:get(seq, Received)),

    {ok, ReceivedHistory} = rpc:call(VpnNode,
                                     vpn_manager,
                                     debug_received_payloads,
                                     [peer_b],
                                     ?RPC_TIMEOUT_MS),
    Matching = [Entry || Entry <- ReceivedHistory,
                         maps:get(payload, Entry, undefined) =:= Payload],
    ?assertEqual(1, length(Matching)),
    ok.

dataplane_survives_authenticated_rekey(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config),
    pong = net_adm:ping(VpnNode),
    ActualFingerprint = actual_vpn_fingerprint(VpnNode),
    DeviceId = unique_id(<<"ias_ct_rekey_">>),
    BeforePayload = <<"ias-vpn-before-rekey">>,
    AfterPayload = <<"ias-vpn-after-rekey">>,

    ok = reset_ias_state(),
    allow = prepare_authorized_peer(DeviceId, client_a, ActualFingerprint),
    {ok, UpsertDelivery} =
        deliver_upsert_after_runtime_revision(VpnNode,
                                              DeviceId,
                                              client_a),
    ?assertEqual(applied, maps:get(delivery_status, UpsertDelivery)),
    timer:sleep(500),
    ?assert(lists:member(client_a, running_peers(VpnNode))),
    ?assert(lists:member(peer_b, running_peers(VpnNode))),

    ok = rpc:call(VpnNode,
                  vpn_manager,
                  debug_clear_received_payloads,
                  [peer_b],
                  ?RPC_TIMEOUT_MS),
    {ok, BeforeState} = rpc:call(VpnNode,
                                 vpn_manager,
                                 debug_session_state,
                                 [client_a],
                                 ?RPC_TIMEOUT_MS),
    ?assertEqual(established, maps:get(handshake_status, BeforeState)),
    EpochBefore = maps:get(current_epoch, BeforeState),
    ?assert(EpochBefore > 0),
    RekeysBefore = maps:get(rekeys_completed, BeforeState),

    {ok, SentBefore} = rpc:call(VpnNode,
                                vpn_manager,
                                debug_send_payload,
                                [client_a, BeforePayload],
                                ?RPC_TIMEOUT_MS),
    {ok, ReceivedBefore} =
        wait_for_received_payload(VpnNode, peer_b, BeforePayload, 5000),
    ?assertEqual(EpochBefore, maps:get(key_epoch, SentBefore)),
    ?assertEqual(EpochBefore, maps:get(key_epoch, ReceivedBefore)),

    {ok, NextEpoch} = rpc:call(VpnNode,
                               vpn_manager,
                               rekey,
                               [client_a],
                               ?RPC_TIMEOUT_MS),
    ?assertEqual(EpochBefore + 1, NextEpoch),
    {ok, ClientAfterRekey} = rpc:call(VpnNode,
                                      vpn_manager,
                                      debug_wait_for_epoch,
                                      [client_a, NextEpoch, 5000],
                                      7000),
    {ok, PeerAfterRekey} = rpc:call(VpnNode,
                                    vpn_manager,
                                    debug_wait_for_epoch,
                                    [peer_b, NextEpoch, 5000],
                                    7000),
    ?assertEqual(established, maps:get(handshake_status, ClientAfterRekey)),
    ?assertEqual(established, maps:get(handshake_status, PeerAfterRekey)),
    ?assertEqual(EpochBefore, maps:get(previous_epoch, ClientAfterRekey)),
    ?assertEqual(EpochBefore, maps:get(previous_epoch, PeerAfterRekey)),
    ?assert(maps:get(rekeys_completed, ClientAfterRekey) >= RekeysBefore + 1),

    {ok, SentAfter} = rpc:call(VpnNode,
                               vpn_manager,
                               debug_send_payload,
                               [client_a, AfterPayload],
                               ?RPC_TIMEOUT_MS),
    {ok, ReceivedAfter} =
        wait_for_received_payload(VpnNode, peer_b, AfterPayload, 5000),
    ?assertEqual(NextEpoch, maps:get(key_epoch, SentAfter)),
    ?assertEqual(NextEpoch, maps:get(key_epoch, ReceivedAfter)),
    ?assertEqual(AfterPayload, maps:get(payload, ReceivedAfter)),

    {ok, ClientFinalState} = rpc:call(VpnNode,
                                      vpn_manager,
                                      debug_session_state,
                                      [client_a],
                                      ?RPC_TIMEOUT_MS),
    {ok, PeerFinalState} = rpc:call(VpnNode,
                                    vpn_manager,
                                    debug_session_state,
                                    [peer_b],
                                    ?RPC_TIMEOUT_MS),
    ?assertEqual(NextEpoch, maps:get(current_epoch, ClientFinalState)),
    ?assertEqual(NextEpoch, maps:get(current_epoch, PeerFinalState)),
    ?assert(maps:get(tx_packets_since_rekey, ClientFinalState) >= 1),
    ?assert(maps:get(rx_packets_since_rekey, PeerFinalState) >= 1),

    {ok, ReceivedHistory} = rpc:call(VpnNode,
                                     vpn_manager,
                                     debug_received_payloads,
                                     [peer_b],
                                     ?RPC_TIMEOUT_MS),
    BeforeMatches = [Entry || Entry <- ReceivedHistory,
                              maps:get(payload, Entry, undefined) =:= BeforePayload],
    AfterMatches = [Entry || Entry <- ReceivedHistory,
                             maps:get(payload, Entry, undefined) =:= AfterPayload],
    ?assertEqual(1, length(BeforeMatches)),
    ?assertEqual(1, length(AfterMatches)),
    ok.


dataplane_recovers_after_peer_restart(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config),
    pong = net_adm:ping(VpnNode),
    ActualFingerprint = actual_vpn_fingerprint(VpnNode),
    DeviceId = unique_id(<<"ias_ct_restart_">>),
    BeforePayload = <<"ias-vpn-before-peer-restart">>,
    AfterPayload = <<"ias-vpn-after-peer-restart">>,

    ok = reset_ias_state(),
    allow = prepare_authorized_peer(DeviceId, client_a, ActualFingerprint),
    {ok, UpsertDelivery} =
        deliver_upsert_after_runtime_revision(VpnNode,
                                              DeviceId,
                                              client_a),
    ?assertEqual(applied, maps:get(delivery_status, UpsertDelivery)),
    timer:sleep(500),
    ?assert(lists:member(client_a, running_peers(VpnNode))),

    {ok, RegistryBeforeRestart} = rpc:call(VpnNode,
                                           vpn_peer_registry,
                                           get,
                                           [client_a],
                                           ?RPC_TIMEOUT_MS),
    RevisionBeforeRestart = maps:get(revision, RegistryBeforeRestart),
    DeliveryHistoryBeforeRestart = ias_vpn_provisioning_delivery:history(DeviceId),

    ok = rpc:call(VpnNode,
                  vpn_manager,
                  debug_clear_received_payloads,
                  [peer_b],
                  ?RPC_TIMEOUT_MS),
    {ok, _SentBeforeRestart} = rpc:call(VpnNode,
                                        vpn_manager,
                                        debug_send_payload,
                                        [client_a, BeforePayload],
                                        ?RPC_TIMEOUT_MS),
    {ok, ReceivedBeforeRestart} =
        wait_for_received_payload(VpnNode, peer_b, BeforePayload, 5000),
    ?assertEqual(BeforePayload, maps:get(payload, ReceivedBeforeRestart)),

    {ok, OldPid} = rpc:call(VpnNode,
                            vpn_manager,
                            debug_peer_pid,
                            [client_a],
                            ?RPC_TIMEOUT_MS),
    {ok, OldPid} = rpc:call(VpnNode,
                            vpn_manager,
                            debug_restart_peer,
                            [client_a],
                            ?RPC_TIMEOUT_MS),
    {ok, NewPid} = wait_for_peer_restart(VpnNode, client_a, OldPid, 5000),
    ?assert(OldPid =/= NewPid),
    ?assertEqual(true,
                 rpc:call(VpnNode, erlang, is_process_alive, [NewPid], ?RPC_TIMEOUT_MS)),

    {ok, ClientRecoveredState} =
        wait_for_session_established(VpnNode, client_a, 5000),
    {ok, PeerRecoveredState} =
        wait_for_session_established(VpnNode, peer_b, 5000),
    ?assertEqual(established, maps:get(handshake_status, ClientRecoveredState)),
    ?assertEqual(established, maps:get(handshake_status, PeerRecoveredState)),

    {ok, _SentAfterRestart} = rpc:call(VpnNode,
                                       vpn_manager,
                                       debug_send_payload,
                                       [client_a, AfterPayload],
                                       ?RPC_TIMEOUT_MS),
    {ok, ReceivedAfterRestart} =
        wait_for_received_payload(VpnNode, peer_b, AfterPayload, 5000),
    ?assertEqual(AfterPayload, maps:get(payload, ReceivedAfterRestart)),

    {ok, RegistryAfterRestart} = rpc:call(VpnNode,
                                          vpn_peer_registry,
                                          get,
                                          [client_a],
                                          ?RPC_TIMEOUT_MS),
    ?assertEqual(RevisionBeforeRestart, maps:get(revision, RegistryAfterRestart)),
    ?assertEqual(DeliveryHistoryBeforeRestart,
                 ias_vpn_provisioning_delivery:history(DeviceId)),

    {ok, ReceivedHistory} = rpc:call(VpnNode,
                                     vpn_manager,
                                     debug_received_payloads,
                                     [peer_b],
                                     ?RPC_TIMEOUT_MS),
    AfterMatches = [Entry || Entry <- ReceivedHistory,
                             maps:get(payload, Entry, undefined) =:= AfterPayload],
    ?assertEqual(1, length(AfterMatches)),
    ok.


replayed_dataplane_frame_is_rejected(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config),
    pong = net_adm:ping(VpnNode),
    ActualFingerprint = actual_vpn_fingerprint(VpnNode),
    DeviceId = unique_id(<<"ias_ct_replay_">>),
    Payload = <<"ias-vpn-replay-probe">>,

    ok = reset_ias_state(),
    allow = prepare_authorized_peer(DeviceId, client_a, ActualFingerprint),
    {ok, UpsertDelivery} =
        deliver_upsert_after_runtime_revision(VpnNode,
                                              DeviceId,
                                              client_a),
    ?assertEqual(applied, maps:get(delivery_status, UpsertDelivery)),
    timer:sleep(500),
    ?assert(lists:member(client_a, running_peers(VpnNode))),

    ok = rpc:call(VpnNode,
                  vpn_manager,
                  debug_clear_received_payloads,
                  [peer_b],
                  ?RPC_TIMEOUT_MS),
    {ok, Sent} = rpc:call(VpnNode,
                          vpn_manager,
                          debug_send_payload,
                          [client_a, Payload],
                          ?RPC_TIMEOUT_MS),
    KeyEpoch = maps:get(key_epoch, Sent),
    Seq = maps:get(seq, Sent),
    {ok, FirstReceipt} =
        wait_for_received_payload(VpnNode, peer_b, Payload, 5000),
    ?assertEqual(KeyEpoch, maps:get(key_epoch, FirstReceipt)),
    ?assertEqual(Seq, maps:get(seq, FirstReceipt)),

    {ok, PeerStatsBefore} = peer_link_stats(VpnNode, peer_b),
    DuplicateBefore = maps:get(duplicate_frames, PeerStatsBefore, 0),
    ReplayDropsBefore = maps:get(replay_drops, PeerStatsBefore, 0),
    RejectedBefore = maps:get(frames_rejected, PeerStatsBefore, 0),

    ok = rpc:call(VpnNode,
                  vpn_manager,
                  debug_replay_frame,
                  [client_a, KeyEpoch, Seq],
                  ?RPC_TIMEOUT_MS),
    {ok, PeerStatsAfter} =
        wait_for_replay_rejection(VpnNode,
                                  peer_b,
                                  DuplicateBefore + 1,
                                  ReplayDropsBefore + 1,
                                  5000),
    ?assertEqual(DuplicateBefore + 1,
                 maps:get(duplicate_frames, PeerStatsAfter, 0)),
    ?assertEqual(ReplayDropsBefore + 1,
                 maps:get(replay_drops, PeerStatsAfter, 0)),
    ?assert(maps:get(frames_rejected, PeerStatsAfter, 0) >= RejectedBefore + 1),

    {ok, ReceivedHistory} = rpc:call(VpnNode,
                                     vpn_manager,
                                     debug_received_payloads,
                                     [peer_b],
                                     ?RPC_TIMEOUT_MS),
    Matches = [Entry || Entry <- ReceivedHistory,
                        maps:get(payload, Entry, undefined) =:= Payload],
    ?assertEqual(1, length(Matches)),
    ok.


previous_epoch_expires_after_grace_window(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config),
    pong = net_adm:ping(VpnNode),
    ActualFingerprint = actual_vpn_fingerprint(VpnNode),
    DeviceId = unique_id(<<"ias_ct_previous_epoch_">>),
    Payload = <<"ias-vpn-previous-epoch-probe">>,

    ok = reset_ias_state(),
    allow = prepare_authorized_peer(DeviceId, client_a, ActualFingerprint),
    {ok, UpsertDelivery} =
        deliver_upsert_after_runtime_revision(VpnNode,
                                              DeviceId,
                                              client_a),
    ?assertEqual(applied, maps:get(delivery_status, UpsertDelivery)),
    timer:sleep(500),

    ok = rpc:call(VpnNode,
                  vpn_manager,
                  debug_clear_received_payloads,
                  [peer_b],
                  ?RPC_TIMEOUT_MS),
    {ok, Sent} = rpc:call(VpnNode,
                          vpn_manager,
                          debug_send_payload,
                          [client_a, Payload],
                          ?RPC_TIMEOUT_MS),
    PreviousEpoch = maps:get(key_epoch, Sent),
    PreviousSeq = maps:get(seq, Sent),
    {ok, FirstReceipt} =
        wait_for_received_payload(VpnNode, peer_b, Payload, 5000),
    ?assertEqual(PreviousEpoch, maps:get(key_epoch, FirstReceipt)),
    ?assertEqual(PreviousSeq, maps:get(seq, FirstReceipt)),

    {ok, NextEpoch} = rpc:call(VpnNode,
                               vpn_manager,
                               rekey,
                               [client_a],
                               ?RPC_TIMEOUT_MS),
    ?assertEqual(PreviousEpoch + 1, NextEpoch),
    {ok, _ClientAfterRekey} = rpc:call(VpnNode,
                                       vpn_manager,
                                       debug_wait_for_epoch,
                                       [client_a, NextEpoch, 5000],
                                       7000),
    {ok, PeerAfterRekey} = rpc:call(VpnNode,
                                    vpn_manager,
                                    debug_wait_for_epoch,
                                    [peer_b, NextEpoch, 5000],
                                    7000),
    ?assertEqual(PreviousEpoch, maps:get(previous_epoch, PeerAfterRekey)),
    GraceRemaining = maps:get(previous_epoch_expires_in_ms, PeerAfterRekey),
    ?assert(is_integer(GraceRemaining)),
    ?assert(GraceRemaining > 0),

    {ok, StatsBeforeGraceReplay} = peer_link_stats(VpnNode, peer_b),
    DuplicateBefore = maps:get(duplicate_frames, StatsBeforeGraceReplay, 0),
    ReplayDropsBefore = maps:get(replay_drops, StatsBeforeGraceReplay, 0),
    StaleBefore = maps:get(stale_epoch_drops, StatsBeforeGraceReplay, 0),

    ok = rpc:call(VpnNode,
                  vpn_manager,
                  debug_replay_frame,
                  [client_a, PreviousEpoch, PreviousSeq],
                  ?RPC_TIMEOUT_MS),
    {ok, StatsDuringGrace} =
        wait_for_replay_rejection(VpnNode,
                                  peer_b,
                                  DuplicateBefore + 1,
                                  ReplayDropsBefore + 1,
                                  5000),
    ?assertEqual(StaleBefore, maps:get(stale_epoch_drops, StatsDuringGrace, 0)),

    %% The previous epoch can remain visible in a debug snapshot until the
    %% next frame is evaluated, and automatic rekeys may replace it with a
    %% newer previous epoch.  The security contract is therefore tested at
    %% the dataplane boundary: wait past the advertised grace period and
    %% require the captured epoch to be rejected as stale.
    timer:sleep(GraceRemaining + 500),

    {ok, StatsBeforeExpiredReplay} = peer_link_stats(VpnNode, peer_b),
    StaleBeforeExpiredReplay =
        maps:get(stale_epoch_drops, StatsBeforeExpiredReplay, 0),
    RejectedBeforeExpiredReplay =
        maps:get(frames_rejected, StatsBeforeExpiredReplay, 0),

    ok = rpc:call(VpnNode,
                  vpn_manager,
                  debug_replay_frame,
                  [client_a, PreviousEpoch, PreviousSeq],
                  ?RPC_TIMEOUT_MS),
    {ok, StatsAfterExpiredReplay} =
        wait_for_stale_epoch_rejection(VpnNode,
                                       peer_b,
                                       StaleBeforeExpiredReplay + 1,
                                       RejectedBeforeExpiredReplay + 1,
                                       5000),
    ?assertEqual(StaleBeforeExpiredReplay + 1,
                 maps:get(stale_epoch_drops, StatsAfterExpiredReplay, 0)),

    {ok, ReceivedHistory} = rpc:call(VpnNode,
                                     vpn_manager,
                                     debug_received_payloads,
                                     [peer_b],
                                     ?RPC_TIMEOUT_MS),
    Matches = [Entry || Entry <- ReceivedHistory,
                        maps:get(payload, Entry, undefined) =:= Payload],
    ?assertEqual(1, length(Matches)),
    ok.

out_of_order_frames_within_replay_window_are_accepted(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config),
    pong = net_adm:ping(VpnNode),
    ActualFingerprint = actual_vpn_fingerprint(VpnNode),
    DeviceId = unique_id(<<"ias_ct_out_of_order_">>),
    FirstPayload = <<"ias-vpn-sequence-first">>,
    DelayedPayload = <<"ias-vpn-sequence-delayed">>,
    AheadPayload = <<"ias-vpn-sequence-ahead">>,
    Payloads = [FirstPayload, DelayedPayload, AheadPayload],
    SendOrder = [1, 3, 2],

    ok = reset_ias_state(),
    allow = prepare_authorized_peer(DeviceId, client_a, ActualFingerprint),
    {ok, UpsertDelivery} =
        deliver_upsert_after_runtime_revision(VpnNode,
                                              DeviceId,
                                              client_a),
    ?assertEqual(applied, maps:get(delivery_status, UpsertDelivery)),
    {ok, _ClientSession} =
        wait_for_session_established(VpnNode, client_a, 5000),
    {ok, _PeerSession} =
        wait_for_session_established(VpnNode, peer_b, 5000),

    {ok, RegistryBefore} = rpc:call(VpnNode,
                                    vpn_peer_registry,
                                    get,
                                    [client_a],
                                    ?RPC_TIMEOUT_MS),
    RevisionBefore = maps:get(revision, RegistryBefore),
    DeliveryHistoryBefore = ias_vpn_provisioning_delivery:history(DeviceId),

    ok = rpc:call(VpnNode,
                  vpn_manager,
                  debug_clear_received_payloads,
                  [peer_b],
                  ?RPC_TIMEOUT_MS),
    {ok, StatsBefore} = peer_link_stats(VpnNode, peer_b),
    FramesAcceptedBefore = maps:get(frames_accepted, StatsBefore, 0),
    FramesRejectedBefore = maps:get(frames_rejected, StatsBefore, 0),
    ReplayDropsBefore = maps:get(replay_drops, StatsBefore, 0),
    DuplicateFramesBefore = maps:get(duplicate_frames, StatsBefore, 0),
    ReplayBefore = maps:get(replay, StatsBefore),
    CurrentReplayBefore = maps:get(current, ReplayBefore),
    ReplayAcceptedBefore = maps:get(accepted, CurrentReplayBefore, 0),
    ReplayDuplicatesBefore = maps:get(duplicates, CurrentReplayBefore, 0),
    ReplayTooOldBefore = maps:get(too_old, CurrentReplayBefore, 0),

    {ok, SentBatch} = rpc:call(VpnNode,
                               vpn_manager,
                               debug_send_payloads,
                               [client_a, Payloads, SendOrder],
                               ?RPC_TIMEOUT_MS),
    ?assertEqual(3, maps:get(sent, SentBatch)),
    [FirstFrame, DelayedFrame, AheadFrame] = maps:get(frames, SentBatch),
    KeyEpoch = maps:get(key_epoch, SentBatch),
    FirstSeq = maps:get(seq, FirstFrame),
    DelayedSeq = maps:get(seq, DelayedFrame),
    AheadSeq = maps:get(seq, AheadFrame),
    ?assertEqual(FirstSeq + 1, DelayedSeq),
    ?assertEqual(FirstSeq + 2, AheadSeq),
    ?assertEqual([FirstSeq, AheadSeq, DelayedSeq],
                 maps:get(send_order, SentBatch)),

    {ok, Received} =
        wait_for_received_payloads(VpnNode, peer_b, Payloads, 5000),
    ?assertEqual([FirstPayload, AheadPayload, DelayedPayload],
                 [maps:get(payload, Entry) || Entry <- Received]),
    ?assertEqual([FirstSeq, AheadSeq, DelayedSeq],
                 [maps:get(seq, Entry) || Entry <- Received]),
    ?assertEqual([KeyEpoch, KeyEpoch, KeyEpoch],
                 [maps:get(key_epoch, Entry) || Entry <- Received]),

    {ok, StatsAfter} = peer_link_stats(VpnNode, peer_b),
    ?assertEqual(FramesAcceptedBefore + 3,
                 maps:get(frames_accepted, StatsAfter, 0)),
    ?assertEqual(FramesRejectedBefore,
                 maps:get(frames_rejected, StatsAfter, 0)),
    ?assertEqual(ReplayDropsBefore,
                 maps:get(replay_drops, StatsAfter, 0)),
    ?assertEqual(DuplicateFramesBefore,
                 maps:get(duplicate_frames, StatsAfter, 0)),
    CurrentReplayAfter = maps:get(current, maps:get(replay, StatsAfter)),
    ?assertEqual(AheadSeq, maps:get(highest, CurrentReplayAfter)),
    ?assertEqual(ReplayAcceptedBefore + 3,
                 maps:get(accepted, CurrentReplayAfter, 0)),
    ?assertEqual(ReplayDuplicatesBefore,
                 maps:get(duplicates, CurrentReplayAfter, 0)),
    ?assertEqual(ReplayTooOldBefore,
                 maps:get(too_old, CurrentReplayAfter, 0)),

    {ok, SessionAfter} = rpc:call(VpnNode,
                                  vpn_manager,
                                  debug_session_state,
                                  [peer_b],
                                  ?RPC_TIMEOUT_MS),
    ?assertEqual(established, maps:get(handshake_status, SessionAfter)),
    ?assertEqual(KeyEpoch, maps:get(current_epoch, SessionAfter)),

    {ok, RegistryAfter} = rpc:call(VpnNode,
                                   vpn_peer_registry,
                                   get,
                                   [client_a],
                                   ?RPC_TIMEOUT_MS),
    ?assertEqual(RevisionBefore, maps:get(revision, RegistryAfter)),
    ?assertEqual(DeliveryHistoryBefore,
                 ias_vpn_provisioning_delivery:history(DeviceId)),
    ok.


peer_link_stats(VpnNode, PeerId) ->
    case rpc:call(VpnNode,
                  vpn_manager,
                  peer_stats,
                  [PeerId],
                  ?RPC_TIMEOUT_MS) of
        #{link := LinkStats} when is_map(LinkStats) ->
            {ok, LinkStats};
        Other ->
            {error, Other}
    end.


wait_for_stale_epoch_rejection(VpnNode,
                               PeerId,
                               ExpectedStaleDrops,
                               ExpectedRejected,
                               TimeoutMs) ->
    wait_for_stale_epoch_rejection(VpnNode,
                                   PeerId,
                                   ExpectedStaleDrops,
                                   ExpectedRejected,
                                   TimeoutMs,
                                   erlang:monotonic_time(millisecond),
                                   not_started).

wait_for_stale_epoch_rejection(VpnNode,
                               PeerId,
                               ExpectedStaleDrops,
                               ExpectedRejected,
                               TimeoutMs,
                               StartedAt,
                               _LastResult) ->
    Result = peer_link_stats(VpnNode, PeerId),
    case Result of
        {ok, Stats} ->
            StaleDrops = maps:get(stale_epoch_drops, Stats, 0),
            Rejected = maps:get(frames_rejected, Stats, 0),
            case StaleDrops >= ExpectedStaleDrops andalso
                 Rejected >= ExpectedRejected of
                true ->
                    {ok, Stats};
                false ->
                    wait_for_stale_epoch_rejection_retry(VpnNode,
                                                         PeerId,
                                                         ExpectedStaleDrops,
                                                         ExpectedRejected,
                                                         TimeoutMs,
                                                         StartedAt,
                                                         Result)
            end;
        _ ->
            wait_for_stale_epoch_rejection_retry(VpnNode,
                                                 PeerId,
                                                 ExpectedStaleDrops,
                                                 ExpectedRejected,
                                                 TimeoutMs,
                                                 StartedAt,
                                                 Result)
    end.

wait_for_stale_epoch_rejection_retry(VpnNode,
                                     PeerId,
                                     ExpectedStaleDrops,
                                     ExpectedRejected,
                                     TimeoutMs,
                                     StartedAt,
                                     LastResult) ->
    Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
    case Elapsed >= TimeoutMs of
        true ->
            ct:fail({vpn_stale_epoch_not_rejected,
                     PeerId,
                     ExpectedStaleDrops,
                     ExpectedRejected,
                     LastResult});
        false ->
            timer:sleep(100),
            wait_for_stale_epoch_rejection(VpnNode,
                                           PeerId,
                                           ExpectedStaleDrops,
                                           ExpectedRejected,
                                           TimeoutMs,
                                           StartedAt,
                                           LastResult)
    end.

wait_for_replay_rejection(VpnNode,
                          PeerId,
                          ExpectedDuplicates,
                          ExpectedReplayDrops,
                          TimeoutMs) ->
    wait_for_replay_rejection(VpnNode,
                              PeerId,
                              ExpectedDuplicates,
                              ExpectedReplayDrops,
                              TimeoutMs,
                              erlang:monotonic_time(millisecond),
                              not_started).

wait_for_replay_rejection(VpnNode,
                          PeerId,
                          ExpectedDuplicates,
                          ExpectedReplayDrops,
                          TimeoutMs,
                          StartedAt,
                          _LastResult) ->
    Result = peer_link_stats(VpnNode, PeerId),
    case Result of
        {ok, Stats} ->
            Duplicates = maps:get(duplicate_frames, Stats, 0),
            ReplayDrops = maps:get(replay_drops, Stats, 0),
            case Duplicates >= ExpectedDuplicates andalso
                 ReplayDrops >= ExpectedReplayDrops of
                true ->
                    {ok, Stats};
                false ->
                    wait_for_replay_rejection_retry(VpnNode,
                                                    PeerId,
                                                    ExpectedDuplicates,
                                                    ExpectedReplayDrops,
                                                    TimeoutMs,
                                                    StartedAt,
                                                    Result)
            end;
        _ ->
            wait_for_replay_rejection_retry(VpnNode,
                                            PeerId,
                                            ExpectedDuplicates,
                                            ExpectedReplayDrops,
                                            TimeoutMs,
                                            StartedAt,
                                            Result)
    end.

wait_for_replay_rejection_retry(VpnNode,
                                PeerId,
                                ExpectedDuplicates,
                                ExpectedReplayDrops,
                                TimeoutMs,
                                StartedAt,
                                LastResult) ->
    Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
    case Elapsed >= TimeoutMs of
        true ->
            ct:fail({vpn_replay_not_rejected,
                     PeerId,
                     ExpectedDuplicates,
                     ExpectedReplayDrops,
                     LastResult});
        false ->
            timer:sleep(100),
            wait_for_replay_rejection(VpnNode,
                                      PeerId,
                                      ExpectedDuplicates,
                                      ExpectedReplayDrops,
                                      TimeoutMs,
                                      StartedAt,
                                      LastResult)
    end.

deliver_upsert_after_runtime_revision(VpnNode, DeviceId, PeerId) ->
    {ok, Command0} = ias_vpn_provisioning_command:build(DeviceId, upsert),
    RuntimeRevision =
        case rpc:call(VpnNode,
                      vpn_peer_registry,
                      get,
                      [PeerId],
                      ?RPC_TIMEOUT_MS) of
            {ok, RegistryEntry} -> maps:get(revision, RegistryEntry, 0);
            not_found -> 0
        end,
    Command = Command0#{revision => RuntimeRevision + 1},
    ias_vpn_provisioning_delivery:deliver(Command).


wait_for_peer_restart(VpnNode, PeerId, OldPid, TimeoutMs) ->
    wait_for_peer_restart(VpnNode,
                          PeerId,
                          OldPid,
                          TimeoutMs,
                          erlang:monotonic_time(millisecond),
                          not_started).

wait_for_peer_restart(VpnNode, PeerId, OldPid, TimeoutMs, StartedAt, LastResult) ->
    Result = rpc:call(VpnNode,
                      vpn_manager,
                      debug_peer_pid,
                      [PeerId],
                      ?RPC_TIMEOUT_MS),
    case Result of
        {ok, NewPid} when is_pid(NewPid), NewPid =/= OldPid ->
            {ok, NewPid};
        _ ->
            Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
            case Elapsed >= TimeoutMs of
                true ->
                    ct:fail({vpn_peer_not_restarted, PeerId, LastResult, Result});
                false ->
                    timer:sleep(100),
                    wait_for_peer_restart(VpnNode,
                                          PeerId,
                                          OldPid,
                                          TimeoutMs,
                                          StartedAt,
                                          Result)
            end
    end.

wait_for_session_established(VpnNode, PeerId, TimeoutMs) ->
    wait_for_session_established(VpnNode,
                                 PeerId,
                                 TimeoutMs,
                                 erlang:monotonic_time(millisecond)).

wait_for_session_established(VpnNode, PeerId, TimeoutMs, StartedAt) ->
    case rpc:call(VpnNode,
                  vpn_manager,
                  debug_session_state,
                  [PeerId],
                  ?RPC_TIMEOUT_MS) of
        {ok, #{handshake_status := established} = SessionState} ->
            {ok, SessionState};
        LastResult ->
            Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
            case Elapsed >= TimeoutMs of
                true ->
                    ct:fail({vpn_session_not_reestablished, PeerId, LastResult});
                false ->
                    timer:sleep(100),
                    wait_for_session_established(VpnNode,
                                                 PeerId,
                                                 TimeoutMs,
                                                 StartedAt)
            end
    end.

wait_for_received_payloads(VpnNode, PeerId, Payloads, TimeoutMs) ->
    wait_for_received_payloads(VpnNode,
                               PeerId,
                               Payloads,
                               TimeoutMs,
                               erlang:monotonic_time(millisecond)).

wait_for_received_payloads(VpnNode, PeerId, Payloads, TimeoutMs, StartedAt) ->
    case rpc:call(VpnNode,
                  vpn_manager,
                  debug_received_payloads,
                  [PeerId],
                  ?RPC_TIMEOUT_MS) of
        {ok, Entries} when is_list(Entries) ->
            Matches = [Entry || Entry <- Entries,
                                lists:member(maps:get(payload,
                                                      Entry,
                                                      undefined),
                                             Payloads)],
            case length(Matches) >= length(Payloads) of
                true ->
                    {ok, Matches};
                false ->
                    wait_for_received_payloads_retry(VpnNode,
                                                     PeerId,
                                                     Payloads,
                                                     TimeoutMs,
                                                     StartedAt,
                                                     Entries)
            end;
        Other ->
            wait_for_received_payloads_retry(VpnNode,
                                             PeerId,
                                             Payloads,
                                             TimeoutMs,
                                             StartedAt,
                                             Other)
    end.

wait_for_received_payloads_retry(VpnNode,
                                 PeerId,
                                 Payloads,
                                 TimeoutMs,
                                 StartedAt,
                                 LastResult) ->
    Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
    case Elapsed >= TimeoutMs of
        true ->
            ct:fail({dataplane_payloads_not_received,
                     PeerId,
                     Payloads,
                     LastResult});
        false ->
            timer:sleep(100),
            wait_for_received_payloads(VpnNode,
                                       PeerId,
                                       Payloads,
                                       TimeoutMs,
                                       StartedAt)
    end.

wait_for_received_payload(VpnNode, PeerId, Payload, TimeoutMs) ->
    wait_for_received_payload(VpnNode,
                              PeerId,
                              Payload,
                              TimeoutMs,
                              erlang:monotonic_time(millisecond)).

wait_for_received_payload(VpnNode, PeerId, Payload, TimeoutMs, StartedAt) ->
    case rpc:call(VpnNode,
                  vpn_manager,
                  debug_received_payloads,
                  [PeerId],
                  ?RPC_TIMEOUT_MS) of
        {ok, Entries} when is_list(Entries) ->
            case [Entry || Entry <- Entries,
                          maps:get(payload, Entry, undefined) =:= Payload] of
                [Entry | _] ->
                    {ok, Entry};
                [] ->
                    wait_for_received_payload_retry(
                      VpnNode, PeerId, Payload, TimeoutMs, StartedAt, no_payload)
            end;
        Other ->
            wait_for_received_payload_retry(
              VpnNode, PeerId, Payload, TimeoutMs, StartedAt, Other)
    end.

wait_for_received_payload_retry(VpnNode, PeerId, Payload, TimeoutMs, StartedAt, LastResult) ->
    Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
    case Elapsed >= TimeoutMs of
        true ->
            ct:fail({dataplane_payload_not_received, PeerId, LastResult});
        false ->
            timer:sleep(100),
            wait_for_received_payload(VpnNode, PeerId, Payload, TimeoutMs, StartedAt)
    end.

ensure_distributed_controller() ->
    case node() of
        nonode@nohost ->
            case net_kernel:start(['ias_ct_controller@127.0.0.1', longnames]) of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                Other -> ct:fail({cannot_start_distributed_controller, Other})
            end;
        _ ->
            ok
    end.

ensure_ias_test_runtime() ->
    %% The CT controller exercises IAS modules directly. Starting the full IAS
    %% application also starts BPE, which expects its production KVS schema and
    %% is unrelated to this provisioning contract test. Only start the OTP
    %% applications needed by the command and certificate helpers.
    RequiredApps = [crypto, public_key, inets],
    case [Failure || App <- RequiredApps,
                     Failure <- [application:ensure_all_started(App)],
                     not runtime_started(Failure)] of
        [] -> ok;
        Failures -> ct:fail({ias_test_runtime_start_failed, Failures})
    end.

runtime_started({ok, _Apps}) ->
    true;
runtime_started({error, {already_started, _App}}) ->
    true;
runtime_started(_) ->
    false.

vpn_repo(Config) ->
    Raw = case os:getenv("VPN_REPO") of
              false -> proplists:get_value(vpn_repo, Config, "../vpn");
              Value -> Value
          end,
    filename:absname(Raw).

validate_vpn_repo(VpnRepo) ->
    Required = [filename:join(VpnRepo, "rebar.config"),
                filename:join(VpnRepo, "config/sys.debug.config"),
                filename:join(VpnRepo, "tools/ensure-debug-ovpn.sh")],
    case [Path || Path <- Required, not filelib:is_regular(Path)] of
        [] -> ok;
        Missing -> ct:fail({invalid_vpn_repo, VpnRepo, Missing})
    end.

ensure_no_conflicting_vpn_node() ->
    case net_adm:ping('vpn@127.0.0.1') of
        pang -> ok;
        pong -> ct:fail({conflicting_vpn_node_running, 'vpn@127.0.0.1'})
    end,
    case net_adm:ping(?VPN_NODE) of
        pang ->
            ok;
        pong ->
            _ = rpc:call(?VPN_NODE, init, stop, [], 1000),
            case wait_for_node_down(?VPN_NODE, 5000) of
                ok -> ok;
                {error, Reason} -> ct:fail({stale_vpn_ct_node, Reason})
            end
    end,
    ok.

prepare_vpn(VpnRepo) ->
    Command = "cd " ++ shell_quote(VpnRepo) ++
              " && ./tools/prepare-debug-topology.sh" ++
              " && rebar3 as debug compile",
    case run_command(Command, 120000) of
        {ok, Output} ->
            ct:pal("VPN preparation output:~n~s", [Output]),
            ok;
        {error, Status, Output} ->
            ct:fail({vpn_prepare_failed, Status, Output})
    end.

start_vpn(VpnRepo, LogPath) ->
    Parent = self(),
    Process = spawn(fun() -> vpn_process_owner(Parent, VpnRepo, LogPath) end),
    receive
        {vpn_process_started, Process} ->
            {ok, Process};
        {vpn_process_failed, Process, Reason} ->
            {error, Reason}
    after 10000 ->
        exit(Process, kill),
        {error, {vpn_spawn_failed, timeout}}
    end.

vpn_process_owner(Parent, VpnRepo, LogPath) ->
    process_flag(trap_exit, true),
    case file:open(LogPath, [write, raw, binary]) of
        {ok, Log} ->
            try
                Erl = require_executable("erl"),
                EbinPaths = vpn_ebin_paths(VpnRepo),
                Args = ["-noshell",
                        "-noinput",
                        "-name", "vpn_ct@127.0.0.1",
                        "-setcookie", "ias_vpn_ct_cookie",
                        "-config", filename:join(VpnRepo, "config/sys.debug")]
                       ++ code_path_args(EbinPaths)
                       ++ ["-eval", vpn_start_expression()],
                Port = open_port({spawn_executable, Erl},
                                 [{args, Args},
                                  {cd, VpnRepo},
                                  binary,
                                  exit_status,
                                  stderr_to_stdout,
                                  use_stdio]),
                OsPid = case erlang:port_info(Port, os_pid) of
                            {os_pid, Pid} -> Pid;
                            undefined -> undefined
                        end,
                Parent ! {vpn_process_started, self()},
                vpn_process_loop(Port, Log, OsPid)
            catch
                Class:Reason:Stacktrace ->
                    Parent ! {vpn_process_failed,
                              self(),
                              {vpn_spawn_failed, Class, Reason, Stacktrace}}
            after
                file:close(Log)
            end;
        {error, Reason} ->
            Parent ! {vpn_process_failed,
                      self(),
                      {vpn_log_open_failed, LogPath, Reason}}
    end.

require_executable(Name) ->
    case os:find_executable(Name) of
        false -> erlang:error({executable_not_found, Name});
        Path -> Path
    end.

vpn_ebin_paths(VpnRepo) ->
    Patterns = [
        filename:join([VpnRepo, "_build", "debug", "lib", "*", "ebin"]),
        filename:join([VpnRepo, "_build", "debug", "deps", "*", "ebin"]),
        filename:join([VpnRepo, "_build", "default", "lib", "*", "ebin"]),
        filename:join([VpnRepo, "_build", "default", "deps", "*", "ebin"])
    ],
    Paths = unique_paths(lists:append([filelib:wildcard(Pattern) || Pattern <- Patterns])),
    case Paths of
        [] -> erlang:error({vpn_code_path_not_found, Patterns});
        _ -> Paths
    end.

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
    %% erl processes repeated -pa options by prepending each path. Pass lower
    %% priority fallback profiles first so the freshly compiled debug profile
    %% remains ahead of any stale default-profile beams.
    lists:append([["-pa", Path] || Path <- lists:reverse(Paths)]).

vpn_start_expression() ->
    "case application:ensure_all_started(vpn) of "
    "{ok, _} -> receive after infinity -> ok end; "
    "{error, Reason} -> io:format(standard_error, "
    "\"VPN startup failed: ~p~n\", [Reason]), halt(1) end.".

vpn_process_loop(Port, Log, OsPid) ->
    receive
        {Port, {data, Data}} ->
            ok = file:write(Log, Data),
            vpn_process_loop(Port, Log, OsPid);
        {Port, {exit_status, Status}} ->
            ok = file:write(Log,
                            iolist_to_binary(io_lib:format("~nVPN exited with status ~p~n",
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

ensure_vpn_test_ports_available() ->
    Ports = [5556, 5557, 5560, 5561, 5562, 20000, 30000],
    case [Port || Port <- Ports, not udp_port_available(Port)] of
        [] ->
            ok;
        BusyPorts ->
            ct:fail({vpn_test_ports_in_use,
                     BusyPorts,
                     "Another VPN instance may still be running in a terminal. "
                     "Stop it and rerun the Common Test suite."})
    end.

udp_port_available(Port) ->
    case gen_udp:open(Port,
                      [binary,
                       {active, false},
                       {ip, {127, 0, 0, 1}},
                       {reuseaddr, false}]) of
        {ok, Socket} ->
            ok = gen_udp:close(Socket),
            true;
        {error, eaddrinuse} ->
            false;
        {error, Reason} ->
            ct:fail({vpn_test_port_probe_failed, Port, Reason})
    end.

terminate_os_process(undefined) ->
    ok;
terminate_os_process(OsPid) when is_integer(OsPid) ->
    Command = "kill -TERM " ++ integer_to_list(OsPid) ++
              " 2>/dev/null || true; sleep 1; " ++
              "kill -KILL " ++ integer_to_list(OsPid) ++
              " 2>/dev/null || true",
    _ = run_command(Command, 3000),
    ok.

wait_for_vpn_ready(Node, Process, TimeoutMs) ->
    Monitor = erlang:monitor(process, Process),
    StartedAt = erlang:monotonic_time(millisecond),
    Result = wait_for_vpn_ready(Node,
                                Process,
                                Monitor,
                                TimeoutMs,
                                StartedAt,
                                not_connected),
    erlang:demonitor(Monitor, [flush]),
    Result.

wait_for_vpn_ready(Node, Process, Monitor, TimeoutMs, StartedAt, LastReason) ->
    Ready = case net_adm:ping(Node) of
                pang ->
                    {error, not_connected};
                pong ->
                    case rpc:call(Node, code, which, [vpn_peer_registry], ?RPC_TIMEOUT_MS) of
                        non_existing ->
                            {error, vpn_code_not_loaded};
                        {badrpc, CodeProbeReason} ->
                            {error, {vpn_code_probe_failed, CodeProbeReason}};
                        _BeamPath ->
                            case rpc:call(Node,
                                          application,
                                          which_applications,
                                          [],
                                          ?RPC_TIMEOUT_MS) of
                                Apps when is_list(Apps) ->
                                    case lists:keymember(vpn, 1, Apps) of
                                        true -> vpn_test_api_ready(Node);
                                        false -> {error, vpn_application_not_started}
                                    end;
                                {badrpc, AppProbeReason} ->
                                    {error, {vpn_application_probe_failed, AppProbeReason}}
                            end
                    end
            end,
    case Ready of
        ok ->
            ok;
        {error, ReadyReason} ->
            Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
            case Elapsed >= TimeoutMs of
                true -> {error, {timeout, ReadyReason, LastReason}};
                false ->
                    receive
                        {'DOWN', Monitor, process, Process, ExitReason} ->
                            {error, {vpn_process_exited, ExitReason}}
                    after 250 ->
                        wait_for_vpn_ready(Node,
                                           Process,
                                           Monitor,
                                           TimeoutMs,
                                           StartedAt,
                                           ReadyReason)
                    end
            end
    end.



wizard_provisions_device_into_vpn_runtime(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config),
    pong = net_adm:ping(VpnNode),
    FixtureFingerprint = actual_vpn_fingerprint(VpnNode),
    DeviceId = unique_id(<<"ias_ct_wizard_device_">>),
    ServiceId = unique_id(<<"ias_ct_wizard_service_">>),
    CaCertificateId = unique_id(<<"ias_ct_wizard_ca_">>),
    ClientCertificateId = unique_id(<<"ias_ct_wizard_client_">>),

    ok = reset_ias_state(),
    ok = ias_provisioning_wizard_store:clear(),
    {Device, Service, CaCertificate, ClientCertificate} =
        prepare_wizard_vpn_objects(DeviceId,
                                   ServiceId,
                                   CaCertificateId,
                                   ClientCertificateId,
                                   FixtureFingerprint),
    ?assertEqual([], ias_vpn_provisioning_delivery:history(DeviceId)),

    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    WizardId = maps:get(id, Draft0),
    {ok, _} = ias_provisioning_wizard_store:select_existing_user(
                WizardId, alice),
    {ok, _} = ias_provisioning_wizard_store:select_existing_device(
                WizardId, maps:get(id, Device)),
    {ok, _} = ias_provisioning_wizard_store:select_existing_security_profile(
                WizardId, administrator),
    {ok, _} = ias_provisioning_wizard_store:select_existing_vpn_service(
                WizardId, maps:get(id, Service)),
    {ok, _} = ias_provisioning_wizard_store:select_existing_ca_certificate(
                WizardId, maps:get(id, CaCertificate)),
    {ok, _} = ias_provisioning_wizard_store:select_existing_client_certificate(
                WizardId, maps:get(id, ClientCertificate)),

    {ok, SelectedDraft} = ias_provisioning_wizard_store:get(WizardId),
    {ok, ReadyDraft} = ensure_wizard_relationships(WizardId, SelectedDraft),
    ?assertEqual(true,
                 ias_provisioning_wizard_store:relationships_ready(ReadyDraft)),
    ?assertEqual(true,
                 ias_provisioning_wizard_store:material_readiness_ready(ReadyDraft)),

    {ok, CompletedDraft, Transaction} =
        ias_provisioning_wizard_store:create_provisioning(WizardId),
    ?assertEqual(true, maps:get(completed, CompletedDraft)),
    ?assertEqual(provisioning, maps:get(current_step, CompletedDraft)),
    ?assertEqual(maps:get(id, Transaction),
                 maps:get(provisioning_id, CompletedDraft)),
    ?assertEqual(DeviceId, maps:get(device_id, Transaction)),
    ?assertEqual(ServiceId, maps:get(vpn_service_id, Transaction)),
    ?assertEqual(CaCertificateId, maps:get(ca_certificate_id, Transaction)),
    ?assertEqual(ClientCertificateId, maps:get(certificate_id, Transaction)),
    ?assertEqual(allow, maps:get(authorization, Transaction)),
    ?assertEqual(ready_for_delivery, maps:get(status, Transaction)),

    {ok, ProvisioningResult} =
        ias_vpn_wizard_provisioning:provision(WizardId),
    RuntimePeerId = maps:get(runtime_peer_id, ProvisioningResult),
    GatewayPeerId = maps:get(gateway_peer_id, ProvisioningResult),
    AllocationId = maps:get(allocation_id, ProvisioningResult),
    AllocatorInstanceId = maps:get(allocator_instance_id, ProvisioningResult),
    ?assert(is_binary(RuntimePeerId)),
    ?assert(is_binary(GatewayPeerId)),
    ?assert(is_binary(AllocationId)),
    ?assert(is_binary(AllocatorInstanceId)),
    ?assert(RuntimePeerId =/= client_a),
    ?assert(GatewayPeerId =/= peer_b),

    DeliveryResult = #{command => maps:get(command, ProvisioningResult),
                       delivery => maps:get(delivery, ProvisioningResult)},
    ?assertEqual(applied, delivery_status(DeliveryResult)),
    ?assertEqual(1, command_revision(DeliveryResult)),
    Command = maps:get(command, DeliveryResult),
    ?assertEqual(RuntimePeerId, maps:get(peer_id, Command)),
    CommandDesired = maps:get(desired_state, Command),
    ?assertEqual(DeviceId, maps:get(device_id, CommandDesired)),
    ?assertEqual(administrator, maps:get(profile_id, CommandDesired)),

    DynamicPair = maps:get(dynamic_pair, ProvisioningResult),
    ?assertEqual(AllocationId, maps:get(allocation_id, DynamicPair)),
    ?assertEqual(RuntimePeerId, maps:get(client_peer_id, DynamicPair)),
    ?assertEqual(GatewayPeerId, maps:get(gateway_peer_id, DynamicPair)),
    ?assertEqual(established, maps:get(state, DynamicPair)),

    {ok, ClientSession} = wait_for_session_established(
                            VpnNode, RuntimePeerId, 10000),
    {ok, GatewaySession} = wait_for_session_established(
                             VpnNode, GatewayPeerId, 10000),
    ?assertEqual(established, maps:get(handshake_status, ClientSession)),
    ?assertEqual(established, maps:get(handshake_status, GatewaySession)),

    {ok, RuntimePeer} = rpc:call(VpnNode,
                                 vpn_peer_registry,
                                 get,
                                 [RuntimePeerId],
                                 ?RPC_TIMEOUT_MS),
    DynamicFingerprint = maps:get(certificate_fingerprint, RuntimePeer),
    ?assertEqual(RuntimePeerId, maps:get(id, RuntimePeer)),
    ?assertEqual(DeviceId, maps:get(device_id, RuntimePeer)),
    ?assertEqual(AllocationId, maps:get(allocation_id, RuntimePeer)),
    ?assertEqual(client, maps:get(allocation_role, RuntimePeer)),
    ?assertEqual(DynamicFingerprint,
                 maps:get(certificate_fingerprint, CommandDesired)),
    ?assert(FixtureFingerprint =/= DynamicFingerprint),
    ?assertEqual(1, maps:get(revision, RuntimePeer)),
    ?assertEqual(true, maps:get(enabled, RuntimePeer)),
    ?assertEqual(true, maps:get(authorized, RuntimePeer)),
    ?assertEqual(administrator, maps:get(profile_id, RuntimePeer)),
    ?assert(lists:member(RuntimePeerId, running_peers(VpnNode))),
    ?assert(lists:member(GatewayPeerId, running_peers(VpnNode))),

    {ok, GatewayPeer} = rpc:call(VpnNode,
                                 vpn_peer_registry,
                                 get,
                                 [GatewayPeerId],
                                 ?RPC_TIMEOUT_MS),
    ?assertEqual(DeviceId, maps:get(device_id, GatewayPeer)),
    ?assertEqual(AllocationId, maps:get(allocation_id, GatewayPeer)),
    ?assertEqual(gateway, maps:get(allocation_role, GatewayPeer)),

    {ok, StoredDevice} = ias_demo_store:get(DeviceId),
    ?assertEqual(RuntimePeerId, maps:get(runtime_peer_id, StoredDevice)),
    ?assertEqual(GatewayPeerId, maps:get(vpn_gateway_peer_id, StoredDevice)),
    ?assertEqual(DynamicFingerprint,
                 maps:get(vpn_runtime_certificate_fingerprint, StoredDevice)),

    InitialHistory = ias_vpn_provisioning_delivery:history(DeviceId),
    ?assertEqual(1, length(InitialHistory)),
    [InitialDelivery] = InitialHistory,
    ?assertEqual(upsert, maps:get(operation, InitialDelivery)),
    ?assertEqual(applied, maps:get(delivery_status, InitialDelivery)),
    ?assertEqual(1, maps:get(revision, InitialDelivery)),

    {ok, RevokeResult} = ias_vpn_access_lifecycle:revoke(DeviceId),
    ?assertEqual(RuntimePeerId, maps:get(runtime_peer_id, RevokeResult)),
    ?assertEqual(revoke, maps:get(operation, RevokeResult)),
    ?assertEqual(2, maps:get(revision, RevokeResult)),
    ?assertEqual(applied, maps:get(delivery_status, RevokeResult)),
    {ok, RevokedDeliveryPeer} = maps:get(runtime, RevokeResult),
    ?assertEqual(RuntimePeerId, maps:get(id, RevokedDeliveryPeer)),
    ?assertEqual(false, maps:get(enabled, RevokedDeliveryPeer)),
    ?assertEqual(false, maps:get(authorized, RevokedDeliveryPeer)),
    ?assertEqual(true, maps:get(revoked, RevokedDeliveryPeer)),
    ?assertEqual(certificate_revoked,
                 maps:get(authorization_reason, RevokedDeliveryPeer)),
    ?assertEqual(revoke,
                 maps:get(last_provisioning_operation, RevokedDeliveryPeer)),
    timer:sleep(300),

    {ok, RevokedRuntimePeer} = rpc:call(VpnNode,
                                        vpn_peer_registry,
                                        get,
                                        [RuntimePeerId],
                                        ?RPC_TIMEOUT_MS),
    ?assertEqual(DeviceId, maps:get(device_id, RevokedRuntimePeer)),
    ?assertEqual(2, maps:get(revision, RevokedRuntimePeer)),
    ?assertEqual(false, maps:get(enabled, RevokedRuntimePeer)),
    ?assertEqual(false, maps:get(authorized, RevokedRuntimePeer)),
    ?assertEqual(true, maps:get(revoked, RevokedRuntimePeer)),
    ?assertEqual(certificate_revoked,
                 maps:get(authorization_reason, RevokedRuntimePeer)),

    {ok, QuiescedGatewayPeer} = rpc:call(VpnNode,
                                         vpn_peer_registry,
                                         get,
                                         [GatewayPeerId],
                                         ?RPC_TIMEOUT_MS),
    ?assertEqual(DeviceId, maps:get(device_id, QuiescedGatewayPeer)),
    ?assertEqual(AllocationId, maps:get(allocation_id, QuiescedGatewayPeer)),
    ?assertEqual(gateway, maps:get(allocation_role, QuiescedGatewayPeer)),
    ?assertEqual(false, maps:get(enabled, QuiescedGatewayPeer)),
    ?assertEqual(true, maps:get(authorized, QuiescedGatewayPeer)),
    ?assertEqual(false, maps:get(revoked, QuiescedGatewayPeer)),
    ?assertNot(lists:member(RuntimePeerId, running_peers(VpnNode))),
    ?assertNot(lists:member(GatewayPeerId, running_peers(VpnNode))),

    {ok, RejectedEnableResult} = ias_vpn_access_lifecycle:enable(DeviceId),
    ?assertEqual(RuntimePeerId, maps:get(runtime_peer_id, RejectedEnableResult)),
    ?assertEqual(enable, maps:get(operation, RejectedEnableResult)),
    ?assertEqual(3, maps:get(revision, RejectedEnableResult)),
    ?assertEqual(rejected, maps:get(delivery_status, RejectedEnableResult)),
    ?assertEqual(undefined, maps:get(runtime, RejectedEnableResult)),
    ?assertEqual({error, revoked},
                 maps:get(vpn_result,
                          maps:get(delivery, RejectedEnableResult))),
    timer:sleep(300),
    ?assertNot(lists:member(RuntimePeerId, running_peers(VpnNode))),
    ?assertNot(lists:member(GatewayPeerId, running_peers(VpnNode))),

    LifecycleHistory = ias_vpn_provisioning_delivery:history(DeviceId),
    ?assertEqual(3, length(LifecycleHistory)),
    LifecycleStatus = ias_vpn_provisioning_delivery:status(DeviceId),
    ?assertEqual(3, maps:get(attempts, LifecycleStatus)),
    ?assertEqual(3, maps:get(current_revision, LifecycleStatus)),
    ?assertEqual(rejected,
                 maps:get(last_delivery_status, LifecycleStatus)),
    ?assertEqual(false,
                 history_contains(LifecycleHistory, <<"private_key">>)),
    ?assertEqual(false, history_contains(LifecycleHistory, <<"ovpn">>)),
    ?assertEqual(false,
                 history_contains(LifecycleHistory, <<"session_key">>)),

    {ok, DecommissionResult} =
        ias_vpn_access_lifecycle:decommission(
          DeviceId,
          #{remove_identity => true}),
    ?assertEqual(decommission,
                 maps:get(operation, DecommissionResult)),
    ?assertEqual(AllocationId,
                 maps:get(allocation_id, DecommissionResult)),
    ?assertEqual(RuntimePeerId,
                 maps:get(client_peer_id, DecommissionResult)),
    ?assertEqual(GatewayPeerId,
                 maps:get(gateway_peer_id, DecommissionResult)),
    ?assertEqual(released,
                 maps:get(allocation_state, DecommissionResult)),
    ?assertEqual(removed,
                 maps:get(registry_state, DecommissionResult)),
    ?assertEqual(removed,
                 maps:get(identity_state, DecommissionResult)),
    ?assert(maps:get(wizard_drafts_cleared, DecommissionResult) >= 1),

    ?assertEqual({error, not_found},
                 rpc:call(VpnNode,
                          vpn_peer_allocator,
                          lookup,
                          [DeviceId],
                          ?RPC_TIMEOUT_MS)),
    ?assertEqual({error, not_found},
                 rpc:call(VpnNode,
                          vpn_peer_registry,
                          get,
                          [RuntimePeerId],
                          ?RPC_TIMEOUT_MS)),
    ?assertEqual({error, not_found},
                 rpc:call(VpnNode,
                          vpn_peer_registry,
                          get,
                          [GatewayPeerId],
                          ?RPC_TIMEOUT_MS)),
    ?assertNot(lists:member(RuntimePeerId, running_peers(VpnNode))),
    ?assertNot(lists:member(GatewayPeerId, running_peers(VpnNode))),

    {ok, DecommissionedDevice} = ias_demo_store:get(DeviceId),
    ?assertEqual(false, maps:is_key(runtime_peer_id, DecommissionedDevice)),
    ?assertEqual(false, maps:is_key(vpn_peer, DecommissionedDevice)),
    ?assertEqual(false, maps:is_key(vpn_allocation_id, DecommissionedDevice)),
    ?assertEqual(false, maps:is_key(vpn_client_peer_id, DecommissionedDevice)),
    ?assertEqual(false, maps:is_key(vpn_gateway_peer_id, DecommissionedDevice)),
    ?assertEqual(false,
                 maps:is_key(vpn_runtime_certificate_fingerprint,
                             DecommissionedDevice)),
    DecommissionAudit = maps:get(vpn_last_decommission,
                                 DecommissionedDevice),
    ?assertEqual(AllocationId,
                 maps:get(allocation_id, DecommissionAudit)),
    ?assertEqual(removed,
                 maps:get(identity_state, DecommissionAudit)),
    ?assertEqual([DecommissionAudit],
                 maps:get(vpn_decommission_history,
                          DecommissionedDevice)),

    DecommissionStatus = ias_vpn_access_lifecycle:status(DeviceId),
    ?assertEqual(undefined,
                 maps:get(runtime_peer_id, DecommissionStatus)),
    ?assertEqual(not_bound,
                 maps:get(runtime, DecommissionStatus)),
    ?assertEqual(undefined,
                 maps:get(allocation, DecommissionStatus)),
    ?assertEqual(decommissioned,
                 maps:get(binding_mode, DecommissionStatus)),
    ?assertEqual(DecommissionAudit,
                 maps:get(decommission, DecommissionStatus)),

    {ok, ClearedDraft} = ias_provisioning_wizard_store:get(WizardId),
    ?assertEqual(undefined,
                 maps:get(vpn_allocation_id, ClearedDraft, undefined)),
    ?assertEqual(undefined,
                 maps:get(vpn_client_peer_id, ClearedDraft, undefined)),
    ?assertEqual(undefined,
                 maps:get(vpn_gateway_peer_id, ClearedDraft, undefined)),

    {ok, ReprovisioningResult} =
        ias_vpn_wizard_provisioning:provision(WizardId),
    NewRuntimePeerId = maps:get(runtime_peer_id, ReprovisioningResult),
    NewGatewayPeerId = maps:get(gateway_peer_id, ReprovisioningResult),
    NewAllocationId = maps:get(allocation_id, ReprovisioningResult),
    ?assert(NewRuntimePeerId =/= RuntimePeerId),
    ?assert(NewGatewayPeerId =/= GatewayPeerId),
    ?assert(NewAllocationId =/= AllocationId),
    ReprovisioningDelivery =
        #{command => maps:get(command, ReprovisioningResult),
          delivery => maps:get(delivery, ReprovisioningResult)},
    ?assertEqual(applied, delivery_status(ReprovisioningDelivery)),
    ?assertEqual(4, command_revision(ReprovisioningDelivery)),
    {ok, NewClientSession} = wait_for_session_established(
                               VpnNode, NewRuntimePeerId, 10000),
    {ok, NewGatewaySession} = wait_for_session_established(
                                VpnNode, NewGatewayPeerId, 10000),
    ?assertEqual(established,
                 maps:get(handshake_status, NewClientSession)),
    ?assertEqual(established,
                 maps:get(handshake_status, NewGatewaySession)),
    ?assert(lists:member(NewRuntimePeerId, running_peers(VpnNode))),
    ?assert(lists:member(NewGatewayPeerId, running_peers(VpnNode))),

    {ok, ReprovisionedDevice} = ias_demo_store:get(DeviceId),
    ?assertEqual(NewRuntimePeerId,
                 maps:get(runtime_peer_id, ReprovisionedDevice)),
    ?assertEqual(NewGatewayPeerId,
                 maps:get(vpn_gateway_peer_id, ReprovisionedDevice)),
    ?assertEqual(DecommissionAudit,
                 maps:get(vpn_last_decommission, ReprovisionedDevice)),
    {ok, ReallocatedDraft} = ias_provisioning_wizard_store:get(WizardId),
    ?assertEqual(NewAllocationId,
                 maps:get(vpn_allocation_id, ReallocatedDraft)),
    ?assertEqual(NewRuntimePeerId,
                 maps:get(vpn_client_peer_id, ReallocatedDraft)),
    ?assertEqual(NewGatewayPeerId,
                 maps:get(vpn_gateway_peer_id, ReallocatedDraft)),
    FinalHistory = ias_vpn_provisioning_delivery:history(DeviceId),
    ?assertEqual(4, length(FinalHistory)),
    ?assertEqual(false,
                 history_contains(FinalHistory, <<"private_key">>)),
    ?assertEqual(false, history_contains(FinalHistory, <<"ovpn">>)),
    ?assertEqual(false,
                 history_contains(FinalHistory, <<"session_key">>)),
    ok.

prepare_wizard_vpn_objects(DeviceId,
                           ServiceId,
                           CaCertificateId,
                           ClientCertificateId,
                           Fingerprint) ->
    [Profile] = [Candidate || Candidate <- ias_demo_data:profiles(),
                              maps:get(id, Candidate) =:= administrator],
    Claims = ias_policy:certificate_claims(Profile),
    Device = ias_demo_store:put_runtime_object(
        #{id => DeviceId,
          kind => device,
          peer_id => DeviceId,
          source => manual_device,
          name => <<"CT Wizard Device">>,
          type => <<"vpn-client">>,
          private_key_provider => <<"device_file">>,
          private_key_ref => <<"client.key">>}),
    Service = ias_demo_store:put_runtime_object(
        #{id => ServiceId,
          kind => vpn_service,
          source => manual_vpn_service,
          name => <<"CT OpenVPN Service">>,
          service => openvpn,
          remote => <<"127.0.0.1:5556">>,
          remote_host => <<"127.0.0.1">>,
          remote_port => <<"5556">>,
          protocol => <<"udp">>,
          tls_auth => not_configured}),
    CaCertificate = ias_demo_store:put_runtime_object(
        #{id => CaCertificateId,
          kind => certificate,
          source => ca_certificate,
          material_type => ca_certificate,
          certificate_role => ca_certificate,
          certificate_status => trusted,
          name => <<"CT VPN CA">>,
          subject => <<"CN=Zencrypted Dev CA">>}),
    ClientCertificate = ias_demo_store:add_certificate(
        #{id => ClientCertificateId,
          source => certificate_issue_demo,
          certificate_role => client_certificate,
          certificate_status => trusted,
          profile_id => administrator,
          profile => Profile,
          subject_cn => <<"ct-wizard-vpn-client">>,
          fingerprint_sha256 => Fingerprint,
          private_key_stored => false,
          certificate_body_stored => false}),
    {ok, _} = ias_certificate_verification:verify(
        ClientCertificate#{certificate_id => ClientCertificateId,
                           issuer_cn => <<"Zencrypted Dev CA">>,
                           profile => Profile,
                           profile_id => administrator,
                           claims => Claims,
                           trusted => true,
                           key_match => true}),
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    {ok, _} = ias_certificate_material:put(CaCertificateId,
                                           ca_certificate,
                                           Pem,
                                           operator_load),
    {ok, _} = ias_certificate_material:put(ClientCertificateId,
                                           client_certificate,
                                           Pem,
                                           operator_load),
    {Device, Service, CaCertificate, ClientCertificate}.

ensure_wizard_relationships(WizardId, Draft) ->
    case ias_provisioning_wizard_store:relationships_ready(Draft) of
        true -> {ok, Draft};
        false -> ias_provisioning_wizard_store:apply_relationships(WizardId)
    end.

vpn_test_api_ready(Node) ->
    RequiredExports = [{debug_session_state, 1},
                       {debug_wait_for_epoch, 3},
                       {debug_peer_pid, 1},
                       {debug_restart_peer, 1},
                       {debug_wait_for_peer_restart, 3},
                       {debug_send_payload, 2},
                       {debug_send_payloads, 3},
                       {debug_received_payloads, 1},
                       {debug_clear_received_payloads, 1},
                       {debug_replay_frame, 3},
                       {peer_stats, 1}],
    case rpc:call(Node,
                  vpn_manager,
                  module_info,
                  [exports],
                  ?RPC_TIMEOUT_MS) of
        Exports when is_list(Exports) ->
            Missing = [Export || Export <- RequiredExports,
                                 not lists:member(Export, Exports)],
            case Missing of
                [] -> ok;
                _ -> {error, {vpn_test_api_missing, Missing}}
            end;
        {badrpc, Reason} ->
            {error, {vpn_test_api_probe_failed, Reason}}
    end.

wait_for_node_down(Node, TimeoutMs) ->
    wait_for_node_down(Node, TimeoutMs, erlang:monotonic_time(millisecond)).

wait_for_node_down(Node, TimeoutMs, StartedAt) ->
    case net_adm:ping(Node) of
        pang -> ok;
        pong ->
            Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
            case Elapsed >= TimeoutMs of
                true -> {error, timeout};
                false -> timer:sleep(100), wait_for_node_down(Node, TimeoutMs, StartedAt)
            end
    end.

wait_for_node(Node, TimeoutMs) ->
    wait_for_node(Node, TimeoutMs, erlang:monotonic_time(millisecond)).

wait_for_node(Node, TimeoutMs, StartedAt) ->
    case net_adm:ping(Node) of
        pong -> ok;
        pang ->
            Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
            case Elapsed >= TimeoutMs of
                true -> {error, timeout};
                false -> timer:sleep(250), wait_for_node(Node, TimeoutMs, StartedAt)
            end
    end.

run_command(Command, Timeout) ->
    Port = open_port({spawn_executable, "/bin/bash"},
                     [{args, ["-lc", Command]},
                      binary,
                      exit_status,
                      stderr_to_stdout,
                      use_stdio]),
    collect_command(Port, Timeout, []).

collect_command(Port, Timeout, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_command(Port, Timeout, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, binary_to_list(iolist_to_binary(lists:reverse(Acc)))};
        {Port, {exit_status, Status}} ->
            {error, Status, binary_to_list(iolist_to_binary(lists:reverse(Acc)))}
    after Timeout ->
        port_close(Port),
        {error, timeout, binary_to_list(iolist_to_binary(lists:reverse(Acc)))}
    end.

stop_vpn_process(Process) when is_pid(Process) ->
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
    end.

read_log(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> Binary;
        {error, Reason} -> {log_unavailable, Reason}
    end.

reset_ias_state() ->
    ok = ias_demo_store:clear(),
    ok = ias_vpn_provisioning_state:reset(),
    ok = ias_vpn_provisioning_delivery:reset(),
    ok.

prepare_authorized_device(DeviceId, Fingerprint) ->
    prepare_authorized_peer(DeviceId, DeviceId, Fingerprint).

prepare_authorized_peer(DeviceId, PeerId, Fingerprint) ->
    [Profile] = [Candidate || Candidate <- ias_demo_data:profiles(),
                              maps:get(id, Candidate) =:= default_user],
    Claims = ias_policy:certificate_claims(Profile),
    CertificateId = unique_id(<<"ias_ct_certificate_">>),
    ServiceId = unique_id(<<"ias_ct_service_">>),
    Device = ias_demo_store:add_device(#{id => DeviceId,
                                           peer_id => PeerId,
                                           source => manual_device}),
    Certificate = ias_demo_store:add_certificate(#{id => CertificateId,
                                                   profile_id => default_user,
                                                   profile => Profile,
                                                   fingerprint_sha256 => Fingerprint,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),
    Service = ias_demo_store:add_service(#{id => ServiceId, service => openvpn}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                            maps:get(id, Device),
                                            maps:get(id, Certificate)),
    {ok, _} = ias_relationship_link:create(uses_service,
                                            maps:get(id, Device),
                                            maps:get(id, Service)),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                            maps:get(id, Device),
                                            <<"high_security">>),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                            maps:get(id, Certificate),
                                            <<"high_security">>),
    {ok, _} = ias_certificate_verification:verify(
                Certificate#{certificate_id => maps:get(id, Certificate),
                             subject_cn => maps:get(id, Certificate),
                             issuer_cn => <<"Zencrypted Dev CA">>,
                             profile => Profile,
                             profile_id => default_user,
                             claims => Claims,
                             trusted => true,
                             key_match => true}),
    Decision = ias_authorization_decision:device_decision(DeviceId, access_vpn),
    maps:get(decision, Decision).

actual_vpn_fingerprint(VpnNode) ->
    {ok, ClientAEntry} = rpc:call(VpnNode,
                                  vpn_peer_registry,
                                  get,
                                  [client_a],
                                  ?RPC_TIMEOUT_MS),
    maps:get(certificate_fingerprint, ClientAEntry).

running_peers(VpnNode) ->
    rpc:call(VpnNode, vpn_manager, running_peers, [], ?RPC_TIMEOUT_MS).

delivery_status(Result) ->
    maps:get(delivery_status, maps:get(delivery, Result)).

command_revision(Result) ->
    maps:get(revision, maps:get(command, Result)).

history_contains(History, Needle) ->
    Binary = iolist_to_binary(io_lib:format("~p", [History])),
    binary:match(Binary, Needle) =/= nomatch.

unique_id(Prefix) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    iolist_to_binary([Prefix, Suffix]).

cwd() ->
    {ok, Cwd} = file:get_cwd(),
    Cwd.

shell_quote(Value) ->
    Flat = lists:flatten(Value),
    "'" ++ lists:flatten(string:replace(Flat, "'", "'\"'\"'", all)) ++ "'".
