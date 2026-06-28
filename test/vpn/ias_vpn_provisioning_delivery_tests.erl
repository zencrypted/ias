-module(ias_vpn_provisioning_delivery_tests).
-include_lib("eunit/include/eunit.hrl").

delivery_flow_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Context) ->
         DeviceId = maps:get(device_id, Context),
         [?_assertEqual(disabled, maps:get(delivery_status, deliver_disabled(Context))),
          ?_assertEqual(applied, maps:get(delivery_status, deliver_with(Context, {ok, applied_result()}))),
          ?_assertEqual(unchanged, maps:get(delivery_status, deliver_with(Context, {ok, unchanged}))),
          ?_assertEqual(rejected, maps:get(delivery_status, deliver_with(Context, {error, revoked}))),
          ?_assertEqual(rejected, maps:get(delivery_status, deliver_with(Context, {error, stale_revision}))),
          ?_assertEqual(timeout, maps:get(delivery_status, deliver_with(Context, {badrpc, timeout}))),
          ?_assertEqual(node_unavailable,
                        maps:get(delivery_status, deliver_with(Context, {badrpc, nodedown}))),
          ?_assertEqual(transport_error,
                        maps:get(delivery_status, deliver_with(Context, {badrpc, einval}))),
          ?_assertEqual(unexpected_result, maps:get(delivery_status, deliver_with(Context, weird))),
          ?_assert(sanitized_history(Context)),
          ?_assert(history_is_newest_first(Context)),
          ?_assert(retry_preserves_same_revision(Context)),
          ?_assert(delivery_failure_does_not_change_revision(Context)),
          ?_assert(build_and_deliver_uses_builder(Context)),
          ?_assert(reset_clears_history(Context)),
          ?_assertMatch(#{device_id := DeviceId, current_revision := _,
                          last_delivery_status := undefined},
                        ias_vpn_provisioning_delivery:status(DeviceId))]
     end}.

setup() ->
    PreviousTransport = application:get_env(ias, vpn_provisioning_transport),
    PreviousNode = application:get_env(ias, vpn_provisioning_vpn_node),
    PreviousTimeout = application:get_env(ias, vpn_provisioning_rpc_timeout),
    PreviousRpcFun = application:get_env(ias, vpn_provisioning_rpc_fun),
    ias_demo_store:clear(),
    ias_vpn_provisioning_state:reset(),
    ias_vpn_provisioning_delivery:reset(),
    Device = ias_demo_store:add_device(#{id => <<"vpn_delivery_device">>,
                                         source => manual_device}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"vpn_delivery_certificate">>,
                                                   profile_id => default_user,
                                                   fingerprint_sha256 => <<"CERT-FINGERPRINT">>}),
    Service = ias_demo_store:add_service(#{id => <<"vpn_delivery_service">>}),
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
    [Profile] = [Candidate || Candidate <- ias_demo_data:profiles(),
                              maps:get(id, Candidate) =:= default_user],
    Claims = ias_policy:certificate_claims(Profile),
    {ok, _} = ias_certificate_verification:verify(
        Certificate#{certificate_id => maps:get(id, Certificate),
                     subject_cn => maps:get(id, Certificate),
                     issuer_cn => <<"Zencrypted Dev CA">>,
                     profile => Profile,
                     profile_id => default_user,
                     claims => Claims,
                     trusted => true,
                     key_match => true}),
    #{device_id => maps:get(id, Device),
      previous_transport => PreviousTransport,
      previous_node => PreviousNode,
      previous_timeout => PreviousTimeout,
      previous_rpc_fun => PreviousRpcFun}.

cleanup(Context) ->
    restore_env(vpn_provisioning_transport, maps:get(previous_transport, Context)),
    restore_env(vpn_provisioning_vpn_node, maps:get(previous_node, Context)),
    restore_env(vpn_provisioning_rpc_timeout, maps:get(previous_timeout, Context)),
    restore_env(vpn_provisioning_rpc_fun, maps:get(previous_rpc_fun, Context)),
    ias_demo_store:clear(),
    ias_vpn_provisioning_state:reset(),
    ias_vpn_provisioning_delivery:reset().

deliver_disabled(Context) ->
    application:set_env(ias, vpn_provisioning_transport, disabled),
    {ok, Command} = ias_vpn_provisioning_command:build(maps:get(device_id, Context), upsert),
    {ok, Record} = ias_vpn_provisioning_delivery:deliver(Command),
    Record.

deliver_with(Context, Result) ->
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(ias, vpn_provisioning_rpc_fun,
                        fun(_Node, _Module, _Function, [_Command], _Timeout) ->
                                Result
                        end),
    {ok, Command} = ias_vpn_provisioning_command:build(maps:get(device_id, Context), upsert),
    {ok, Record} = ias_vpn_provisioning_delivery:deliver(Command),
    Record.

applied_result() ->
    #{operation => upsert,
      peer => #{id => <<"vpn_delivery_device">>,
                enabled => true,
                authorized => true,
                authorization_mode => policy,
                authorization_reason => profile_allows_vpn,
                certificate_fingerprint => <<"CERT-FINGERPRINT">>,
                revision => 1,
                revoked => false,
                private_key_path => <<"secret">>,
                ovpn_body => <<"secret">>}}.

sanitized_history(Context) ->
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(ias, vpn_provisioning_rpc_fun,
                        fun(_Node, _Module, _Function, [_Command], _Timeout) ->
                                {ok, applied_result()}
                        end),
    {ok, Command} = ias_vpn_provisioning_command:build(maps:get(device_id, Context), upsert),
    {ok, _} = ias_vpn_provisioning_delivery:deliver(Command),
    [Entry | _] = ias_vpn_provisioning_delivery:history(maps:get(device_id, Context)),
    {ok, Peer} = extract_peer(Entry),
    false = maps:is_key(private_key_path, Peer),
    false = maps:is_key(ovpn_body, Peer),
    false = maps:is_key(private_key, Entry),
    true.

history_is_newest_first(Context) ->
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(ias, vpn_provisioning_rpc_fun,
                        fun(_Node, _Module, _Function, [_Command], _Timeout) ->
                                {ok, unchanged}
                        end),
    {ok, Command1} = ias_vpn_provisioning_command:build(maps:get(device_id, Context), upsert),
    {ok, _} = ias_vpn_provisioning_delivery:deliver(Command1),
    {ok, Command2} = ias_vpn_provisioning_command:build(maps:get(device_id, Context), disable),
    {ok, _} = ias_vpn_provisioning_delivery:deliver(Command2),
    [Latest, Earlier | _] = ias_vpn_provisioning_delivery:history(maps:get(device_id, Context)),
    maps:get(revision, Latest) >= maps:get(revision, Earlier).

retry_preserves_same_revision(Context) ->
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(ias, vpn_provisioning_rpc_fun,
                        fun(_Node, _Module, _Function, [_Command], _Timeout) ->
                                {badrpc, timeout}
                        end),
    {ok, FirstCommand} = ias_vpn_provisioning_command:build(maps:get(device_id, Context), upsert),
    {ok, _} = ias_vpn_provisioning_delivery:deliver(FirstCommand),
    {ok, RetryCommand} = ias_vpn_provisioning_command:build(maps:get(device_id, Context), upsert),
    {ok, _} = ias_vpn_provisioning_delivery:deliver(RetryCommand),
    maps:get(revision, FirstCommand) =:= maps:get(revision, RetryCommand).

delivery_failure_does_not_change_revision(Context) ->
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(ias, vpn_provisioning_rpc_fun,
                        fun(_Node, _Module, _Function, [_Command], _Timeout) ->
                                {error, stale_revision}
                        end),
    {ok, Command1} = ias_vpn_provisioning_command:build(maps:get(device_id, Context), upsert),
    {ok, _} = ias_vpn_provisioning_delivery:deliver(Command1),
    {ok, Command2} = ias_vpn_provisioning_command:build(maps:get(device_id, Context), upsert),
    maps:get(revision, Command1) =:= maps:get(revision, Command2).

build_and_deliver_uses_builder(Context) ->
    ias_vpn_provisioning_state:reset(),
    ias_vpn_provisioning_delivery:reset(),
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(ias, vpn_provisioning_rpc_fun,
                        fun(_Node, _Module, _Function, [Command], _Timeout) ->
                                case maps:get(revision, Command) of
                                    1 -> {ok, unchanged};
                                    _ -> {error, unexpected_revision}
                                end
                        end),
    {ok, Result} = ias_vpn_provisioning_delivery:build_and_deliver(
                     maps:get(device_id, Context), upsert),
    maps:get(revision, maps:get(command, Result)) =:= 1.

reset_clears_history(Context) ->
    application:set_env(ias, vpn_provisioning_transport, disabled),
    {ok, Command} = ias_vpn_provisioning_command:build(maps:get(device_id, Context), upsert),
    {ok, _} = ias_vpn_provisioning_delivery:deliver(Command),
    ok = ias_vpn_provisioning_delivery:reset(),
    [] =:= ias_vpn_provisioning_delivery:history(maps:get(device_id, Context)).

extract_peer(#{vpn_result := {ok, #{peer := Peer}}}) ->
    {ok, Peer};
extract_peer(_) ->
    error.

restore_env(Key, {ok, Value}) ->
    application:set_env(ias, Key, Value);
restore_env(Key, undefined) ->
    application:unset_env(ias, Key).
