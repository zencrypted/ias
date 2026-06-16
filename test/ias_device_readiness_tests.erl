-module(ias_device_readiness_tests).
-include_lib("eunit/include/eunit.hrl").

ready_device_operational_readiness_test() ->
    ias_demo_store:clear(),
    #{device := Device} = setup_ready_device(),

    Readiness = readiness_for(Device),

    ?assertEqual(ready, maps:get(status, Readiness)),
    ?assertEqual([], maps:get(missing, Readiness)),
    ?assertEqual(verified, maps:get(certificate_verification, Readiness)),
    ?assertEqual(true, maps:get(policy_match, Readiness)).

incomplete_device_operational_readiness_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"readiness_incomplete_device">>,
                                         source => ovpn_demo_import}),

    Readiness = readiness_for(Device),
    Missing = maps:get(missing, Readiness),

    ?assertEqual(incomplete, maps:get(status, Readiness)),
    ?assert(lists:member(<<"VPN Service">>, Missing)),
    ?assert(lists:member(<<"Security Policy">>, Missing)),
    ?assert(lists:member(<<"Current Certificate">>, Missing)),
    ?assert(lists:member(<<"Verified Certificate">>, Missing)).

graph_analysis_readiness_section_test() ->
    ias_demo_store:clear(),
    #{device := ReadyDevice} = setup_ready_device(),
    _Incomplete = ias_demo_store:add_device(#{id => <<"readiness_graph_incomplete_device">>,
                                              source => ovpn_demo_import}),

    Html = iolist_to_binary(nitro:render(
        ias_graph_analysis_details:warning_blocks(ias_graph_analysis:report()))),

    ?assertMatch({_, _}, binary:match(Html, <<"DEVICE OPERATIONAL READINESS">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Ready Devices (1)">>)),
    ?assertMatch({_, _}, binary:match(Html, maps:get(id, ReadyDevice))),
    ?assertMatch({_, _}, binary:match(Html, <<"Incomplete Devices (1)">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Missing:">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Link VPN Service">>)).

device_detail_operational_readiness_section_test() ->
    ias_demo_store:clear(),
    #{device := Device} = setup_ready_device(),

    Html = iolist_to_binary(nitro:render(ias_demo:operational_readiness_preview(Device))),

    ?assertMatch({_, _}, binary:match(Html, <<"OPERATIONAL READINESS">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Overall Status">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"READY">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Certificate Verification">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"verified">>)).

incomplete_device_detail_suggests_actions_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"readiness_detail_incomplete_device">>,
                                         source => ovpn_demo_import}),

    Html = iolist_to_binary(nitro:render(ias_demo:operational_readiness_preview(Device))),

    ?assertMatch({_, _}, binary:match(Html, <<"INCOMPLETE">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Suggested Actions">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Link VPN Service">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Link Security Policy">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Verify Current Certificate">>)).

setup_ready_device() ->
    Device = ias_demo_store:add_device(#{id => <<"readiness_ready_device">>,
                                         source => ovpn_demo_import,
                                         import_id => <<"readiness_ready">>,
                                         type => <<"vpn-client">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"readiness_ready_certificate">>,
                                                   source => ovpn_demo_import,
                                                   import_id => <<"readiness_ready">>,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),
    Service = ias_demo_store:add_service(#{id => <<"readiness_ready_service">>,
                                           source => ovpn_demo_import,
                                           import_id => <<"readiness_ready">>,
                                           service => openvpn,
                                           remote => <<"example.com:1194">>}),
    {ok, _CertificateLink} = ias_relationship_link:create(uses_certificate,
                                                          maps:get(id, Device),
                                                          maps:get(id, Certificate)),
    {ok, _ServiceLink} = ias_relationship_link:create(uses_service,
                                                      maps:get(id, Device),
                                                      maps:get(id, Service)),
    {ok, _DevicePolicy} = ias_relationship_link:create(uses_security_policy,
                                                       maps:get(id, Device),
                                                       <<"high_security">>),
    {ok, _CertificatePolicy} = ias_relationship_link:create(uses_security_policy,
                                                            maps:get(id, Certificate),
                                                            <<"high_security">>),
    {ok, _Verification} = ias_certificate_verification:verify(
        Certificate#{certificate_id => maps:get(id, Certificate),
                     subject_cn => maps:get(id, Certificate),
                     issuer_cn => <<"Zencrypted Dev CA">>,
                     profile => administrator_profile(),
                     profile_id => administrator,
                     claims => #{role => admin,
                                 services => [vpn, ias],
                                 attributes => [admin, issue_certificates, revoke_certificates],
                                 trust_level => elevated},
                     trusted => true,
                     key_match => true}),
    #{device => Device,
      certificate => Certificate,
      service => Service}.

readiness_for(Device) ->
    DeviceId = maps:get(id, Device),
    [Readiness] = [Readiness || Readiness <- maps:get(all, ias_graph_analysis:devices_operational_readiness()),
                                maps:get(device_id, Readiness) =:= DeviceId],
    Readiness.

administrator_profile() ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile, undefined) =:= administrator],
    Profile.
