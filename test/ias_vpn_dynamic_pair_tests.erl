-module(ias_vpn_dynamic_pair_tests).
-include_lib("eunit/include/eunit.hrl").

dynamic_pair_delivery_cutover_test() ->
    Previous = save_env(),
    try
        prepare_env(),
        Context = prepare_authorized_device(),
        DeviceId = maps:get(device_id, Context),
        ClientPeerId = maps:get(client_peer_id, Context),
        GatewayPeerId = maps:get(gateway_peer_id, Context),
        DynamicFingerprint = <<"DYNAMIC-CERT-FINGERPRINT">>,
        application:set_env(
          ias,
          vpn_provisioning_rpc_fun,
          rpc_fun(DeviceId,
                  ClientPeerId,
                  GatewayPeerId,
                  DynamicFingerprint)),

        {ok, Result} = ias_vpn_provisioning_delivery:build_and_deliver(
                         DeviceId, upsert),
        Command = maps:get(command, Result),
        Desired = maps:get(desired_state, Command),
        DynamicPair = maps:get(dynamic_pair, Result),

        ?assertEqual(ClientPeerId, maps:get(peer_id, Command)),
        ?assertEqual(DynamicFingerprint,
                     maps:get(certificate_fingerprint, Desired)),
        ?assertEqual(maps:get(allocation_id, Context),
                     maps:get(allocation_id, DynamicPair)),
        ?assertEqual(established, maps:get(state, DynamicPair)),
        ?assertEqual(applied,
                     maps:get(delivery_status, maps:get(delivery, Result))),

        {ok, StoredDevice} = ias_demo_store:get(DeviceId),
        ?assertEqual(ClientPeerId, maps:get(runtime_peer_id, StoredDevice)),
        ?assertEqual(ClientPeerId, maps:get(vpn_peer, StoredDevice)),
        ?assertEqual(DynamicFingerprint,
                     maps:get(vpn_runtime_certificate_fingerprint,
                              StoredDevice)),
        ?assertEqual(established,
                     maps:get(vpn_dynamic_pair_state, StoredDevice)),
        ?assertEqual(false, contains_secret(Result))
    after
        cleanup_env(Previous)
    end.

dynamic_pair_status_mismatch_is_rejected_test() ->
    Previous = save_env(),
    try
        prepare_env(),
        Context = prepare_authorized_device(),
        DeviceId = maps:get(device_id, Context),
        ClientPeerId = maps:get(client_peer_id, Context),
        GatewayPeerId = maps:get(gateway_peer_id, Context),
        application:set_env(
          ias,
          vpn_provisioning_rpc_fun,
          fun(_Node, vpn_dynamic_pair, ensure, [_RequestedDeviceId, _Desired], _Timeout) ->
                  {ok, pair_status(<<"other-device">>,
                                   maps:get(allocation_id, Context),
                                   maps:get(allocator_instance_id, Context),
                                   ClientPeerId,
                                   GatewayPeerId,
                                   <<"DYNAMIC-CERT-FINGERPRINT">>)};
             (_Node, _Module, _Function, _Args, _Timeout) ->
                  {error, unexpected_rpc_call}
          end),

        ?assertEqual({error, invalid_vpn_dynamic_pair_status},
                     ias_vpn_provisioning_delivery:build_and_deliver(
                       DeviceId, upsert)),
        {ok, StoredDevice} = ias_demo_store:get(DeviceId),
        ?assertEqual(undefined,
                     maps:get(vpn_runtime_certificate_fingerprint,
                              StoredDevice,
                              undefined))
    after
        cleanup_env(Previous)
    end.

prepare_authorized_device() ->
    DeviceId = <<"dynamic-cutover-device">>,
    ClientPeerId = <<"client_dyn_3_instance123456_9">>,
    GatewayPeerId = <<"gateway_dyn_3_instance123456_9">>,
    AllocationId = <<"dynamic-vpn-3-instance123456-9">>,
    AllocatorInstanceId = <<"instance123456">>,
    Device = ias_demo_store:add_device(
               #{id => DeviceId,
                 source => manual_device,
                 owner => alice,
                 vpn_allocation_id => AllocationId,
                 vpn_allocator_instance_id => AllocatorInstanceId,
                 vpn_client_peer_id => ClientPeerId,
                 vpn_gateway_peer_id => GatewayPeerId,
                 vpn_allocation_slot => 3,
                 vpn_allocation_generation => 9,
                 vpn_allocation_state => reserved,
                 vpn_allocation_persistence => volatile}),
    Certificate = ias_demo_store:add_certificate(
                    #{id => <<"dynamic-cutover-certificate">>,
                      profile_id => default_user,
                      fingerprint_sha256 => <<"IAS-CERT-FINGERPRINT">>}),
    Service = ias_demo_store:add_service(
                #{id => <<"dynamic-cutover-service">>}),
    [Profile0] = [Candidate || Candidate <- ias_demo_data:profiles(),
                               maps:get(id, Candidate) =:= default_user],
    Profile = ias_demo_store:put_runtime_object(Profile0#{kind => security_profile}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                            DeviceId,
                                            maps:get(id, Certificate)),
    {ok, _} = ias_relationship_link:create(uses_service,
                                            DeviceId,
                                            maps:get(id, Service)),
    {ok, _} = ias_relationship_link:create(uses_security_profile,
                                            DeviceId,
                                            maps:get(id, Profile)),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                            DeviceId,
                                            <<"high_security">>),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                            maps:get(id, Certificate),
                                            <<"high_security">>),
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
      allocation_id => AllocationId,
      allocator_instance_id => AllocatorInstanceId,
      client_peer_id => ClientPeerId,
      gateway_peer_id => GatewayPeerId}.

rpc_fun(DeviceId, ClientPeerId, GatewayPeerId, Fingerprint) ->
    fun(_Node, vpn_dynamic_pair, ensure, [RequestedDeviceId, Desired], _Timeout) ->
            ?assertEqual(DeviceId, RequestedDeviceId),
            ?assertEqual(DeviceId, maps:get(device_id, Desired)),
            ?assertEqual(false, maps:is_key(certificate_fingerprint, Desired)),
            {ok, pair_status(DeviceId,
                             <<"dynamic-vpn-3-instance123456-9">>,
                             <<"instance123456">>,
                             ClientPeerId,
                             GatewayPeerId,
                             Fingerprint)};
       (_Node, vpn_provisioning, apply, [Command], _Timeout) ->
            Desired = maps:get(desired_state, Command),
            ?assertEqual(ClientPeerId, maps:get(peer_id, Command)),
            ?assertEqual(Fingerprint,
                         maps:get(certificate_fingerprint, Desired)),
            {ok, #{operation => maps:get(operation, Command),
                   peer => #{id => ClientPeerId,
                             device_id => DeviceId,
                             enabled => maps:get(enabled, Desired),
                             authorized => maps:get(authorized, Desired),
                             authorization_mode => maps:get(authorization_mode, Desired),
                             authorization_reason => maps:get(authorization_reason, Desired),
                             profile_id => maps:get(profile_id, Desired),
                             certificate_fingerprint => Fingerprint,
                             revision => maps:get(revision, Command),
                             revoked => maps:get(revoked, Desired, false),
                             provisioning_source => ias,
                             last_provisioning_operation => maps:get(operation, Command)}}};
       (_Node, _Module, _Function, _Args, _Timeout) ->
            {error, unexpected_rpc_call}
    end.

pair_status(DeviceId,
            AllocationId,
            AllocatorInstanceId,
            ClientPeerId,
            GatewayPeerId,
            Fingerprint) ->
    #{allocation_id => AllocationId,
      allocator_instance_id => AllocatorInstanceId,
      device_id => DeviceId,
      client_peer_id => ClientPeerId,
      gateway_peer_id => GatewayPeerId,
      state => reserved,
      client => #{peer_id => ClientPeerId,
                  running => true,
                  handshake_status => established,
                  private_key_path => <<"must-not-cross-boundary">>,
                  registry => #{id => ClientPeerId,
                                device_id => DeviceId,
                                allocation_id => AllocationId,
                                allocator_instance_id => AllocatorInstanceId,
                                allocation_slot => 3,
                                allocation_generation => 9,
                                allocation_role => client,
                                profile_id => default_user,
                                enabled => true,
                                authorized => true,
                                authorization_mode => policy,
                                authorization_reason => profile_allows_vpn,
                                certificate_fingerprint => Fingerprint,
                                revision => 0,
                                revoked => false,
                                provisioning_source => dynamic_pair}},
      gateway => #{peer_id => GatewayPeerId,
                   running => true,
                   handshake_status => established,
                   ovpn_identity => <<"must-not-cross-boundary">>,
                   registry => #{id => GatewayPeerId,
                                 device_id => DeviceId,
                                 allocation_id => AllocationId,
                                 allocator_instance_id => AllocatorInstanceId,
                                 allocation_slot => 3,
                                 allocation_generation => 9,
                                 allocation_role => gateway,
                                 enabled => true,
                                 authorized => true,
                                 authorization_mode => development_bypass,
                                 authorization_reason => dynamic_development_identity,
                                 revision => 0,
                                 revoked => false,
                                 provisioning_source => dynamic_pair}}}.

prepare_env() ->
    ias_demo_store:clear(),
    ias_vpn_provisioning_state:reset(),
    ias_vpn_provisioning_delivery:reset(),
    application:set_env(ias, vpn_dynamic_pair_delivery, true),
    application:set_env(ias, vpn_provisioning_transport, erlang_rpc),
    application:set_env(ias, vpn_provisioning_vpn_node,
                        'vpn-dynamic-pair-test@127.0.0.1'),
    application:set_env(ias, vpn_provisioning_rpc_timeout, 1234),
    application:set_env(ias, vpn_dynamic_pair_rpc_timeout, 4321).

save_env() ->
    #{dynamic_pair => application:get_env(ias, vpn_dynamic_pair_delivery),
      transport => application:get_env(ias, vpn_provisioning_transport),
      node => application:get_env(ias, vpn_provisioning_vpn_node),
      timeout => application:get_env(ias, vpn_provisioning_rpc_timeout),
      pair_timeout => application:get_env(ias, vpn_dynamic_pair_rpc_timeout),
      rpc_fun => application:get_env(ias, vpn_provisioning_rpc_fun)}.

cleanup_env(Previous) ->
    restore_env(vpn_dynamic_pair_delivery, maps:get(dynamic_pair, Previous)),
    restore_env(vpn_provisioning_transport, maps:get(transport, Previous)),
    restore_env(vpn_provisioning_vpn_node, maps:get(node, Previous)),
    restore_env(vpn_provisioning_rpc_timeout, maps:get(timeout, Previous)),
    restore_env(vpn_dynamic_pair_rpc_timeout, maps:get(pair_timeout, Previous)),
    restore_env(vpn_provisioning_rpc_fun, maps:get(rpc_fun, Previous)),
    ias_demo_store:clear(),
    ias_vpn_provisioning_state:reset(),
    ias_vpn_provisioning_delivery:reset().

contains_secret(Value) ->
    Binary = iolist_to_binary(io_lib:format("~p", [Value])),
    binary:match(Binary, <<"must-not-cross-boundary">>) =/= nomatch
        orelse binary:match(Binary, <<"private_key">>) =/= nomatch
        orelse binary:match(Binary, <<"ovpn_identity">>) =/= nomatch.

restore_env(Key, {ok, Value}) -> application:set_env(ias, Key, Value);
restore_env(Key, undefined) -> application:unset_env(ias, Key).
