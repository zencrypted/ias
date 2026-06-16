-module(ias_trust_status_tests).
-include_lib("eunit/include/eunit.hrl").

trusted_certificate_status_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(),

    Status = ias_trust_status:effective_certificate_status(maps:get(id, Certificate)),

    ?assertEqual(trusted, maps:get(trust, Status)),
    ?assertEqual([], maps:get(reasons, Status)).

certificate_without_security_policy_is_degraded_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device_without_certificate_policy(),

    Status = ias_trust_status:effective_certificate_status(maps:get(id, Certificate)),
    Reasons = reason_texts(Status),

    ?assertEqual(degraded, maps:get(trust, Status)),
    ?assert(lists:member(<<"no security policy">>, Reasons)).

revoked_certificate_status_is_blocked_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(),

    {ok, _Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),
    Status = ias_trust_status:effective_certificate_status(maps:get(id, Certificate)),

    ?assertEqual(blocked, maps:get(trust, Status)),
    ?assert(lists:member(<<"certificate revoked">>, reason_texts(Status))).

ready_device_status_test() ->
    ias_demo_store:clear(),
    #{device := Device} = setup_ready_device(),

    Status = ias_trust_status:effective_device_status(maps:get(id, Device)),

    ?assertEqual(ready, maps:get(status, Status)),
    ?assertEqual([], maps:get(reasons, Status)).

revoked_current_certificate_blocks_device_status_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(),

    {ok, _Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),
    Status = ias_trust_status:effective_device_status(maps:get(id, Device)),

    ?assertEqual(blocked, maps:get(status, Status)),
    ?assert(lists:member(<<"current certificate revoked">>, reason_texts(Status))).

incomplete_device_status_reports_missing_vpn_service_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"trust_incomplete_device">>,
                                         source => ovpn_demo_import}),

    Status = ias_trust_status:effective_device_status(maps:get(id, Device)),

    ?assertEqual(incomplete, maps:get(status, Status)),
    ?assert(lists:member(<<"no vpn service">>, reason_texts(Status))).

graph_analysis_report_includes_effective_statuses_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(),

    Report = ias_graph_analysis:report(),

    ?assert(lists:any(fun(Status) ->
        maps:get(id, Status, undefined) =:= maps:get(id, Certificate)
    end, maps:get(effective_certificate_statuses, Report))),
    ?assert(lists:any(fun(Status) ->
        maps:get(id, Status, undefined) =:= maps:get(id, Device)
    end, maps:get(effective_device_statuses, Report))).

demo_pages_render_effective_status_sections_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(),

    DeviceHtml = iolist_to_binary(nitro:render(ias_demo:operational_readiness_preview(Device))),
    FullDeviceHtml = iolist_to_binary(nitro:render(ias_demo:effective_status_preview(Device))),
    FullCertificateHtml = iolist_to_binary(nitro:render(ias_demo:effective_status_preview(Certificate))),

    ?assertMatch({_, _}, binary:match(DeviceHtml, <<"OPERATIONAL READINESS">>)),
    ?assertMatch({_, _}, binary:match(FullDeviceHtml, <<"EFFECTIVE AUTHORIZATION STATUS">>)),
    ?assertMatch({_, _}, binary:match(FullDeviceHtml, <<"ready">>)),
    ?assertMatch({_, _}, binary:match(FullCertificateHtml, <<"EFFECTIVE TRUST STATUS">>)),
    ?assertMatch({_, _}, binary:match(FullCertificateHtml, <<"trusted">>)).

effective_status_reasons_render_multiple_items_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"trust_multi_reason_device">>,
                                         source => ovpn_demo_import}),

    Html = iolist_to_binary(nitro:render(ias_demo:effective_status_preview(Device))),

    ?assertMatch({_, _}, binary:match(Html, <<"EFFECTIVE AUTHORIZATION STATUS">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"no vpn service">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"no security policy">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"no current certificate">>)).

setup_ready_device() ->
    setup_device(true).

setup_ready_device_without_certificate_policy() ->
    setup_device(false).

setup_device(LinkCertificatePolicy) ->
    Device = ias_demo_store:add_device(#{id => test_id(<<"device">>),
                                         source => ovpn_demo_import,
                                         import_id => <<"trust_status_import">>,
                                         type => <<"vpn-client">>}),
    Certificate = ias_demo_store:add_certificate(#{id => test_id(<<"certificate">>),
                                                   source => ovpn_demo_import,
                                                   import_id => <<"trust_status_import">>,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),
    Service = ias_demo_store:add_service(#{id => test_id(<<"service">>),
                                           source => ovpn_demo_import,
                                           import_id => <<"trust_status_import">>,
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
    maybe_link_certificate_policy(LinkCertificatePolicy, Certificate),
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

maybe_link_certificate_policy(true, Certificate) ->
    {ok, _CertificatePolicy} = ias_relationship_link:create(uses_security_policy,
                                                            maps:get(id, Certificate),
                                                            <<"high_security">>),
    ok;
maybe_link_certificate_policy(false, _Certificate) ->
    ok.

administrator_profile() ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile, undefined) =:= administrator],
    Profile.

reason_texts(Status) ->
    [maps:get(text, Reason, undefined) || Reason <- maps:get(reasons, Status, [])].

test_id(Suffix) ->
    ias_html:join([<<"trust_status_">>, Suffix]).
