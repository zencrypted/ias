-module(ias_vpn_rpc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0,
         init_per_suite/1,
         end_per_suite/1,
         provisioning_lifecycle/1]).

-define(VPN_NODE, 'vpn_ct@127.0.0.1').
-define(COOKIE, ias_vpn_ct_cookie).
-define(STARTUP_TIMEOUT_MS, 30000).
-define(RPC_TIMEOUT_MS, 5000).

all() ->
    [provisioning_lifecycle].

init_per_suite(Config) ->
    ok = ensure_distributed_controller(),
    true = erlang:set_cookie(node(), ?COOKIE),
    ok = ensure_ias_test_runtime(),
    VpnRepo = vpn_repo(Config),
    ok = validate_vpn_repo(VpnRepo),
    ok = ensure_no_conflicting_vpn_node(),
    LogPath = filename:join([cwd(), "_build", "test", "logs", "ias_vpn_rpc", "vpn.log"]),
    ok = filelib:ensure_dir(LogPath),
    ok = prepare_vpn(VpnRepo),
    {ok, VpnOsPid} = start_vpn(VpnRepo, LogPath),
    case wait_for_node(?VPN_NODE, ?STARTUP_TIMEOUT_MS) of
        ok ->
            application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
            application:set_env(ias, vpn_provisioning_vpn_node, ?VPN_NODE),
            application:set_env(ias, vpn_provisioning_rpc_timeout, ?RPC_TIMEOUT_MS),
            [{vpn_repo, VpnRepo},
             {vpn_node, ?VPN_NODE},
             {vpn_os_pid, VpnOsPid},
             {vpn_log, LogPath} | Config];
        {error, Reason} ->
            _ = stop_os_process(VpnOsPid),
            ct:fail({vpn_startup_failed, Reason, read_log(LogPath)})
    end.

end_per_suite(Config) ->
    VpnNode = proplists:get_value(vpn_node, Config, ?VPN_NODE),
    _ = rpc:call(VpnNode, init, stop, [], ?RPC_TIMEOUT_MS),
    timer:sleep(500),
    case proplists:get_value(vpn_os_pid, Config) of
        undefined -> ok;
        Pid -> _ = stop_os_process(Pid)
    end,
    application:unset_env(ias, vpn_provisioning_transport),
    application:unset_env(ias, vpn_provisioning_vpn_node),
    application:unset_env(ias, vpn_provisioning_rpc_timeout),
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
    _ = rpc:call(?VPN_NODE, init, stop, [], 1000),
    ok.

prepare_vpn(VpnRepo) ->
    Command = "cd " ++ shell_quote(VpnRepo) ++
              " && ./tools/ensure-debug-ovpn.sh" ++
              " && rebar3 as debug compile",
    case run_command(Command, 120000) of
        {ok, Output} ->
            ct:pal("VPN preparation output:~n~s", [Output]),
            ok;
        {error, Status, Output} ->
            ct:fail({vpn_prepare_failed, Status, Output})
    end.

start_vpn(VpnRepo, LogPath) ->
    Command = "cd " ++ shell_quote(VpnRepo) ++
              " && nohup env ERL_FLAGS=\"-name vpn_ct@127.0.0.1 -setcookie ias_vpn_ct_cookie\"" ++
              " rebar3 as debug shell --eval 'timer:sleep(infinity).'" ++
              " > " ++ shell_quote(LogPath) ++ " 2>&1 < /dev/null & echo $!",
    case run_command(Command, 10000) of
        {ok, Output} ->
            case string:to_integer(string:trim(Output)) of
                {Pid, _Rest} when Pid > 0 -> {ok, Pid};
                _ -> {error, {invalid_vpn_pid, Output}}
            end;
        {error, Status, Output} ->
            {error, {vpn_spawn_failed, Status, Output}}
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

stop_os_process(Pid) when is_integer(Pid), Pid > 0 ->
    _ = os:cmd("kill " ++ integer_to_list(Pid) ++ " 2>/dev/null || true"),
    ok.

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
    [Profile] = [Candidate || Candidate <- ias_demo_data:profiles(),
                              maps:get(id, Candidate) =:= default_user],
    Claims = ias_policy:certificate_claims(Profile),
    CertificateId = unique_id(<<"ias_ct_certificate_">>),
    ServiceId = unique_id(<<"ias_ct_service_">>),
    Device = ias_demo_store:add_device(#{id => DeviceId, source => manual_device}),
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
