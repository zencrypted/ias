-module(ias_vpn_access_lifecycle_tests).
-include_lib("eunit/include/eunit.hrl").

vpn_access_lifecycle_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Context) ->
         [?_assertEqual({error, not_found},
                        ias_vpn_access_lifecycle:disable(<<"missing-device">>)),
          ?_assertMatch(#{runtime_peer_id := client_b,
                          runtime := {ok, #{id := client_b, revision := 4}}},
                        ias_vpn_access_lifecycle:status(maps:get(device_id, Context))),
          ?_assert(disable_advances_runtime_revision(Context)),
          ?_assert(enable_advances_revision(Context)),
          ?_assert(revoke_advances_revision(Context)),
          ?_assert(status_reports_latest_delivery(Context)),
          ?_assert(history_contains_no_runtime_secrets(Context))]
     end}.

setup() ->
    PreviousTransport = application:get_env(ias, vpn_provisioning_transport),
    PreviousNode = application:get_env(ias, vpn_provisioning_vpn_node),
    PreviousTimeout = application:get_env(ias, vpn_provisioning_rpc_timeout),
    PreviousRpcFun = application:get_env(ias, vpn_provisioning_rpc_fun),
    ias_demo_store:clear(),
    ias_vpn_provisioning_state:reset(),
    ias_vpn_provisioning_delivery:reset(),
    Device = ias_demo_store:add_device(#{id => <<"bob-device">>,
                                         owner => bob,
                                         runtime_peer_id => client_b,
                                         vpn_peer => client_b,
                                         source => manual_device}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"bob-certificate">>,
                                                   profile_id => default_user,
                                                   fingerprint_sha256 => <<"BOB-FINGERPRINT">>}),
    Service = ias_demo_store:add_service(#{id => <<"bob-vpn-service">>}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, Device),
                                           maps:get(id, Certificate)),
    {ok, _} = ias_relationship_link:create(uses_service,
                                           maps:get(id, Device),
                                           maps:get(id, Service)),
    [Profile0] = [Candidate || Candidate <- ias_demo_data:profiles(),
                               maps:get(id, Candidate) =:= default_user],
    Profile = ias_demo_store:put_runtime_object(
                Profile0#{kind => security_profile}),
    {ok, _} = ias_relationship_link:create(uses_security_profile,
                                           maps:get(id, Device),
                                           maps:get(id, Profile)),
    {ok, _} = ias_certificate_verification:verify(
        Certificate#{certificate_id => maps:get(id, Certificate),
                     subject_cn => maps:get(id, Certificate),
                     issuer_cn => <<"VPN Local Development CA">>,
                     profile => Profile,
                     profile_id => default_user,
                     claims => ias_policy:certificate_claims(Profile),
                     trusted => true,
                     key_match => true}),
    RuntimeRevision = 4,
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(ias, vpn_provisioning_vpn_node, 'vpn-test@127.0.0.1'),
    application:set_env(ias, vpn_provisioning_rpc_timeout, 1234),
    application:set_env(ias, vpn_provisioning_rpc_fun,
                        rpc_fun(RuntimeRevision)),
    #{device_id => maps:get(id, Device),
      initial_runtime_revision => RuntimeRevision,
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

rpc_fun(RuntimeRevision) ->
    fun(_Node, vpn_peer_registry, get, [client_b], _Timeout) ->
            {ok, #{id => client_b,
                   device_id => <<"bob-device">>,
                   profile_id => default_user,
                   enabled => true,
                   authorized => true,
                   authorization_reason => profile_allows_vpn,
                   revision => RuntimeRevision,
                   revoked => false,
                   last_provisioning_operation => upsert,
                   private_key_path => <<"must-not-leak">>}};
       (_Node, vpn_provisioning, apply, [Command], _Timeout) ->
            Desired = maps:get(desired_state, Command),
            Operation = maps:get(operation, Command),
            Revision = maps:get(revision, Command),
            {ok, #{operation => Operation,
                   peer => Desired#{id => maps:get(peer_id, Command),
                                    revision => Revision,
                                    revoked => Operation =:= revoke,
                                    last_provisioning_operation => Operation,
                                    private_key_path => <<"must-not-leak">>,
                                    session_key => <<"must-not-leak">>}}}
    end.

disable_advances_runtime_revision(Context) ->
    ExpectedRevision = maps:get(initial_runtime_revision, Context) + 1,
    {ok, Result} = ias_vpn_access_lifecycle:disable(maps:get(device_id, Context)),
    {ok, RuntimePeer} = maps:get(runtime, Result),
    maps:get(runtime_peer_id, Result) =:= client_b andalso
    maps:get(operation, Result) =:= disable andalso
    maps:get(revision, Result) =:= ExpectedRevision andalso
    maps:get(delivery_status, Result) =:= applied andalso
    maps:get(id, RuntimePeer) =:= client_b andalso
    maps:get(device_id, RuntimePeer) =:= <<"bob-device">> andalso
    maps:get(profile_id, RuntimePeer) =:= default_user andalso
    maps:get(enabled, RuntimePeer) =:= false andalso
    maps:get(authorized, RuntimePeer) =:= true andalso
    maps:get(authorization_reason, RuntimePeer) =:= profile_allows_vpn andalso
    maps:get(revision, RuntimePeer) =:= ExpectedRevision andalso
    maps:get(revoked, RuntimePeer) =:= false andalso
    maps:get(last_provisioning_operation, RuntimePeer) =:= disable andalso
    not maps:is_key(private_key_path, RuntimePeer) andalso
    not maps:is_key(session_key, RuntimePeer).

enable_advances_revision(Context) ->
    {ok, Result} = ias_vpn_access_lifecycle:enable(maps:get(device_id, Context)),
    maps:get(operation, Result) =:= enable andalso
    maps:get(revision, Result) =:= maps:get(initial_runtime_revision, Context) + 2 andalso
    maps:get(delivery_status, Result) =:= applied.

revoke_advances_revision(Context) ->
    {ok, Result} = ias_vpn_access_lifecycle:revoke(maps:get(device_id, Context)),
    maps:get(operation, Result) =:= revoke andalso
    maps:get(revision, Result) =:= maps:get(initial_runtime_revision, Context) + 3 andalso
    maps:get(delivery_status, Result) =:= applied.

status_reports_latest_delivery(Context) ->
    Status = ias_vpn_access_lifecycle:status(maps:get(device_id, Context)),
    Provisioning = maps:get(provisioning, Status),
    maps:get(last_operation, Provisioning) =:= revoke andalso
    maps:get(last_delivery_status, Provisioning) =:= applied andalso
    maps:get(current_revision, Provisioning) =:= maps:get(initial_runtime_revision, Context) + 3.

history_contains_no_runtime_secrets(Context) ->
    History = ias_vpn_provisioning_delivery:history(maps:get(device_id, Context)),
    Text = iolist_to_binary(io_lib:format("~p", [History])),
    binary:match(Text, <<"must-not-leak">>) =:= nomatch andalso
    binary:match(Text, <<"session_key">>) =:= nomatch andalso
    length(History) =:= 3.

restore_env(Key, {ok, Value}) ->
    application:set_env(ias, Key, Value);
restore_env(Key, undefined) ->
    application:unset_env(ias, Key).
