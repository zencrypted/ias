-module(ias_vpn_recovery_manifest_tests).
-include_lib("eunit/include/eunit.hrl").

recovery_manifest_is_stable_and_secret_free_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device_id := DeviceId,
           certificate_id := CertificateId,
           service_id := ServiceId}) ->
         Context = #{provisioning_transaction_id => <<"ovpn_provisioning_manifest_1">>,
                     wizard_id => <<"wizard_manifest_1">>},
         {ok, Manifest1} = ias_vpn_recovery_manifest:build(DeviceId, Context),
         {ok, Manifest2} = ias_vpn_recovery_manifest:build(DeviceId, Context),
         Preview = ias_vpn_recovery_manifest:preview(Manifest1),
         Device = maps:get(device, Manifest1),
         Certificate = maps:get(certificate, Manifest1),
         Service = maps:get(vpn_service, Manifest1),
         [?_assertEqual(Manifest1, Manifest2),
          ?_assertEqual(ok, ias_vpn_recovery_manifest:validate(Manifest1)),
          ?_assertEqual(DeviceId, maps:get(id, Device)),
          ?_assertEqual(CertificateId, maps:get(id, Certificate)),
          ?_assertEqual(ServiceId, maps:get(id, Service)),
          ?_assertEqual(true, maps:get(recoverable, Preview)),
          ?_assertEqual(metadata_only, maps:get(mode, Preview)),
          ?_assertEqual(false, contains_key(Manifest1, private_key)),
          ?_assertEqual(false, contains_key(Manifest1, private_key_reference)),
          ?_assertEqual(false, contains_key(Manifest1, ovpn_body))]
     end}.

canonical_command_retains_context_manifest_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device_id := DeviceId}) ->
         Context = #{provisioning_transaction_id => <<"ovpn_provisioning_manifest_2">>,
                     wizard_id => <<"wizard_manifest_2">>},
         {ok, Command1} = ias_vpn_provisioning_command:build(
                            DeviceId, upsert, Context),
         {ok, Command2} = ias_vpn_provisioning_command:build(
                            DeviceId, upsert, Context),
         {ok, Command3} = ias_vpn_provisioning_command:build(DeviceId, upsert),
         Manifest = maps:get(recovery_manifest,
                             maps:get(desired_state, Command1)),
         [?_assertEqual(Command1, Command2),
          ?_assertEqual(Command1, Command3),
          ?_assertEqual(<<"ovpn_provisioning_manifest_2">>,
                        maps:get(provisioning_transaction_id, Manifest)),
          ?_assertEqual(<<"wizard_manifest_2">>, maps:get(wizard_id, Manifest))]
     end}.

runtime_binding_does_not_change_recovery_manifest_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{device_id := DeviceId}) ->
         Context = #{provisioning_transaction_id =>
                         <<"ovpn_provisioning_manifest_runtime">>,
                     wizard_id => <<"wizard_manifest_runtime">>},
         {ok, Manifest1} = ias_vpn_recovery_manifest:build(DeviceId, Context),
         {ok, Device0} = ias_demo_store:get(DeviceId),
         _ = ias_demo_store:put_runtime_object(
               Device0#{runtime_peer_id => <<"runtime-peer">>,
                        vpn_peer => <<"runtime-peer">>}),
         {ok, Manifest2} = ias_vpn_recovery_manifest:build(DeviceId, Context),
         ManifestDevice = maps:get(device, Manifest2),
         [?_assertEqual(Manifest1, Manifest2),
          ?_assertEqual(false, maps:is_key(runtime_peer_id, ManifestDevice)),
          ?_assertEqual(false, maps:is_key(vpn_peer, ManifestDevice))]
     end}.

secret_material_is_rejected_test() ->
    Manifest = (base_manifest())#{ovpn_body => <<"client\n<key>secret</key>">>},
    ?assertEqual({error, invalid_recovery_manifest},
                 ias_vpn_recovery_manifest:validate(Manifest)).

setup() ->
    ok = ias_demo_store:clear(),
    ok = ias_vpn_provisioning_state:reset(),
    DeviceId = <<"recovery-manifest-device">>,
    CertificateId = <<"recovery-manifest-certificate">>,
    ServiceId = <<"recovery-manifest-service">>,
    _ = ias_demo_store:add_device(#{id => DeviceId,
                                    name => <<"Recovery Device">>,
                                    owner => alice,
                                    source => manual_device}),
    _ = ias_demo_store:add_certificate(
          #{id => CertificateId,
            name => <<"Recovery Certificate">>,
            fingerprint_sha256 => <<"RECOVERY-CERT-FINGERPRINT">>,
            private_key_reference => <<"external:key:1">>,
            source => manual_certificate}),
    _ = ias_demo_store:add_service(#{id => ServiceId,
                                     name => <<"Recovery VPN">>,
                                     remote_host => <<"vpn.example.test">>,
                                     remote_port => 1194,
                                     protocol => udp,
                                     source => manual_vpn_service}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                            DeviceId,
                                            CertificateId),
    {ok, _} = ias_relationship_link:create(uses_service,
                                            DeviceId,
                                            ServiceId),
    #{device_id => DeviceId,
      certificate_id => CertificateId,
      service_id => ServiceId}.

cleanup(_Context) ->
    ok = ias_demo_store:clear(),
    ok = ias_vpn_provisioning_state:reset().

base_manifest() ->
    #{schema_version => 1,
      device => #{kind => device, id => <<"device">>},
      certificate => #{kind => certificate, id => <<"certificate">>},
      vpn_service => #{kind => vpn_service, id => <<"service">>},
      objects => [#{kind => device, id => <<"device">>},
                  #{kind => certificate, id => <<"certificate">>},
                  #{kind => vpn_service, id => <<"service">>}],
      relationships => [#{relation_type => uses_certificate,
                          source_kind => device,
                          source_id => <<"device">>,
                          target_kind => certificate,
                          target_id => <<"certificate">>},
                        #{relation_type => uses_service,
                          source_kind => device,
                          source_id => <<"device">>,
                          target_kind => vpn_service,
                          target_id => <<"service">>}]}.

contains_key(Map, Key) when is_map(Map) ->
    maps:is_key(Key, Map) orelse
    lists:any(fun(Value) -> contains_key(Value, Key) end, maps:values(Map));
contains_key(List, Key) when is_list(List) ->
    lists:any(fun(Value) -> contains_key(Value, Key) end, List);
contains_key(Tuple, Key) when is_tuple(Tuple) ->
    contains_key(tuple_to_list(Tuple), Key);
contains_key(_Value, _Key) -> false.
