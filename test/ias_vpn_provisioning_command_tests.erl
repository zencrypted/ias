-module(ias_vpn_provisioning_command_tests).
-include_lib("eunit/include/eunit.hrl").

canonical_command_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device := Device, certificate := Certificate}) ->
         DeviceId = maps:get(id, Device),
         {ok, Command1} = ias_vpn_provisioning_command:build(DeviceId, upsert),
         {ok, Command2} = ias_vpn_provisioning_command:build(DeviceId, upsert),
         Desired = maps:get(desired_state, Command1),
         [?_assertEqual(1, maps:get(revision, Command1)),
          ?_assertEqual(Command1, Command2),
          ?_assertEqual(ias, maps:get(source, Command1)),
          ?_assertEqual(upsert, maps:get(operation, Command1)),
          ?_assertEqual(DeviceId, maps:get(peer_id, Command1)),
          ?_assertEqual(DeviceId, maps:get(device_id, Desired)),
          ?_assertEqual(true, maps:get(authorized, Desired)),
          ?_assertEqual(true, maps:get(enabled, Desired)),
          ?_assertEqual(policy, maps:get(authorization_mode, Desired)),
          ?_assertEqual(default_user, maps:get(profile_id, Desired)),
          ?_assertEqual(maps:get(fingerprint_sha256, Certificate),
                        maps:get(certificate_fingerprint, Desired)),
          ?_assertEqual(false, maps:is_key(private_key, Desired)),
          ?_assertEqual(false, maps:is_key(ovpn, Desired))]
     end}.


runtime_peer_id_overrides_device_peer_id_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device := Device}) ->
         DeviceId = maps:get(id, Device),
         RuntimePeerId = client_a,
         _ = ias_demo_store:put_runtime_object(
               Device#{peer_id => DeviceId,
                       runtime_peer_id => RuntimePeerId,
                       vpn_peer => RuntimePeerId}),
         {ok, Command} = ias_vpn_provisioning_command:build(DeviceId, upsert),
         Desired = maps:get(desired_state, Command),
         [?_assertEqual(RuntimePeerId, maps:get(peer_id, Command)),
          ?_assertEqual(DeviceId, maps:get(device_id, Desired))]
     end}.

revision_floor_is_advanced_before_rebinding_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device := Device}) ->
         DeviceId = maps:get(id, Device),
         ok = ias_vpn_provisioning_state:ensure_minimum_revision(DeviceId, 6),
         {ok, Command} = ias_vpn_provisioning_command:build(DeviceId, upsert),
         [?_assertEqual(7, maps:get(revision, Command)),
          ?_assertEqual(7, ias_vpn_provisioning_state:current_revision(DeviceId))]
     end}.

revision_changes_only_when_projection_changes_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device := Device}) ->
         DeviceId = maps:get(id, Device),
         {ok, First} = ias_vpn_provisioning_command:build(DeviceId, upsert),
         {ok, Same} = ias_vpn_provisioning_command:build(DeviceId, upsert),
         {ok, Disabled} = ias_vpn_provisioning_command:build(DeviceId, disable),
         [?_assertEqual(1, maps:get(revision, First)),
          ?_assertEqual(1, maps:get(revision, Same)),
          ?_assertEqual(2, maps:get(revision, Disabled)),
          ?_assertEqual(false, maps:get(enabled, maps:get(desired_state, Disabled)))]
     end}.

revoke_and_remove_commands_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device := Device}) ->
         DeviceId = maps:get(id, Device),
         {ok, Revoke} = ias_vpn_provisioning_command:build(DeviceId, revoke),
         {ok, Remove} = ias_vpn_provisioning_command:build(DeviceId, remove),
         RevokeDesired = maps:get(desired_state, Revoke),
         RemoveDesired = maps:get(desired_state, Remove),
         [?_assertEqual(revoke, maps:get(operation, Revoke)),
          ?_assertEqual(false, maps:get(authorized, RevokeDesired)),
          ?_assertEqual(certificate_revoked, maps:get(authorization_reason, RevokeDesired)),
          ?_assertEqual(remove, maps:get(operation, Remove)),
          ?_assertEqual(device_decommissioned, maps:get(authorization_reason, RemoveDesired))]
     end}.

summary_is_sanitized_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device := Device}) ->
         {ok, Command} = ias_vpn_provisioning_command:build(maps:get(id, Device), upsert),
         Summary = ias_vpn_provisioning_command:summary(Command),
         [?_assertEqual(upsert, maps:get(operation, Summary)),
          ?_assertEqual(default_user, maps:get(profile_id, Summary)),
          ?_assertEqual(false, maps:is_key(desired_state, Summary)),
          ?_assertEqual(false, maps:is_key(runtime_config, Summary)),
          ?_assertEqual(false, maps:is_key(private_key, Summary))]
     end}.

normalizes_binary_authorization_reason_test_() ->
    {setup,
     fun() ->
         ias_demo_store:clear(),
         ias_vpn_provisioning_state:reset(),
         ias_demo_store:add_device(#{id => <<"vpn_unverified_device">>,
                                     source => manual_device})
     end,
     fun(_Device) ->
         ias_demo_store:clear(),
         ias_vpn_provisioning_state:reset()
     end,
     fun(Device) ->
         {ok, Command} = ias_vpn_provisioning_command:build(
                           maps:get(id, Device), disable),
         Desired = maps:get(desired_state, Command),
         Reason = maps:get(authorization_reason, Desired),
         [?_assertEqual(<<"no_vpn_service">>, Reason)]
     end}.

setup() ->
    ias_demo_store:clear(),
    ias_vpn_provisioning_state:reset(),
    Device = ias_demo_store:add_device(#{id => <<"vpn_command_device">>,
                                         source => manual_device}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"vpn_command_certificate">>,
                                                   profile_id => default_user,
                                                   fingerprint_sha256 => <<"CERT-FINGERPRINT">>}),
    Service = ias_demo_store:add_service(#{id => <<"vpn_command_service">>}),
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
    [Profile0] = [Candidate || Candidate <- ias_demo_data:profiles(),
                                maps:get(id, Candidate) =:= default_user],
    Profile = ias_demo_store:put_runtime_object(
                Profile0#{kind => security_profile}),
    {ok, _} = ias_relationship_link:create(uses_security_profile,
                                            maps:get(id, Device),
                                            maps:get(id, Profile)),
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
    #{device => Device, certificate => Certificate}.

cleanup(_Context) ->
    ias_demo_store:clear(),
    ias_vpn_provisioning_state:reset().
