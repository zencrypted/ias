-module(ias_authorization_decision_tests).
-include_lib("eunit/include/eunit.hrl").

device_access_vpn_allows_ready_device_test() ->
    ias_demo_store:clear(),
    #{device := Device} = setup_ready_device(true),

    Decision = ias_authorization_decision:device_decision(maps:get(id, Device), access_vpn),

    ?assertEqual(allow, maps:get(decision, Decision)),
    ?assertEqual([], maps:get(reasons, Decision)).

device_access_vpn_denies_incomplete_device_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"auth_incomplete_device">>,
                                         source => ovpn_demo_import}),

    Decision = ias_authorization_decision:device_decision(maps:get(id, Device), access_vpn),
    Reasons = maps:get(reasons, Decision),

    ?assertEqual(deny, maps:get(decision, Decision)),
    ?assert(lists:member(<<"no vpn service">>, Reasons)),
    ?assert(lists:member(<<"no security policy">>, Reasons)),
    ?assert(lists:member(<<"device not ready">>, Reasons)).

device_access_vpn_denies_revoked_current_certificate_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(true),
    {ok, _Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),

    Decision = ias_authorization_decision:device_decision(maps:get(id, Device), access_vpn),

    ?assertEqual(deny, maps:get(decision, Decision)),
    ?assert(lists:member(<<"current certificate revoked">>, maps:get(reasons, Decision))).

certificate_use_ias_allows_trusted_certificate_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(true),

    Decision = ias_authorization_decision:certificate_decision(maps:get(id, Certificate),
                                                               use_ias),

    ?assertEqual(allow, maps:get(decision, Decision)),
    ?assertEqual([], maps:get(reasons, Decision)).

certificate_use_ias_denies_certificate_without_security_policy_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(false),

    Decision = ias_authorization_decision:certificate_decision(maps:get(id, Certificate),
                                                               use_ias),

    ?assertEqual(deny, maps:get(decision, Decision)),
    ?assert(lists:member(<<"no security policy">>, maps:get(reasons, Decision))).

certificate_use_ias_denies_revoked_certificate_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(true),
    {ok, _Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),

    Decision = ias_authorization_decision:certificate_decision(maps:get(id, Certificate),
                                                               use_ias),

    ?assertEqual(deny, maps:get(decision, Decision)),
    ?assert(lists:member(<<"certificate revoked">>, maps:get(reasons, Decision))).

authorization_decision_preview_does_not_write_runtime_state_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(true),
    Before = length(ias_demo_store:runtime_objects()),

    _DeviceDecision = ias_authorization_decision:device_decision(maps:get(id, Device),
                                                                 access_vpn),
    _CertificateDecision = ias_authorization_decision:certificate_decision(
        maps:get(id, Certificate), use_ias),
    After = length(ias_demo_store:runtime_objects()),

    ?assertEqual(Before, After).

demo_pages_render_authorization_decision_preview_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"auth_preview_device">>,
                                         source => ovpn_demo_import}),

    Html = iolist_to_binary(nitro:render(ias_demo:authorization_decision_preview(Device))),

    ?assertMatch({_, _}, binary:match(Html, <<"AUTHORIZATION DECISION PREVIEW">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"access_vpn">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"deny">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"no vpn service">>)).

graph_analysis_report_includes_authorization_summary_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(true),
    _DeniedDevice = ias_demo_store:add_device(#{id => <<"auth_report_denied_device">>,
                                                source => ovpn_demo_import}),

    Report = ias_graph_analysis:report(),

    ?assert(lists:any(decision_for(maps:get(id, Device), allow),
                      maps:get(authorization_allowed_devices, Report))),
    ?assert(lists:any(decision_for(<<"auth_report_denied_device">>, deny),
                      maps:get(authorization_denied_devices, Report))),
    ?assert(lists:any(decision_for(maps:get(id, Certificate), allow),
                      maps:get(authorization_allowed_certificates, Report))).

setup_ready_device(LinkCertificatePolicy) ->
    Device = ias_demo_store:add_device(#{id => test_id(<<"device">>),
                                         source => ovpn_demo_import,
                                         import_id => <<"authorization_import">>,
                                         type => <<"vpn-client">>}),
    Certificate = ias_demo_store:add_certificate(#{id => test_id(<<"certificate">>),
                                                   source => ovpn_demo_import,
                                                   import_id => <<"authorization_import">>,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),
    Service = ias_demo_store:add_service(#{id => test_id(<<"service">>),
                                           source => ovpn_demo_import,
                                           import_id => <<"authorization_import">>,
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

test_id(Suffix) ->
    ias_html:join([<<"authorization_">>, Suffix]).

decision_for(Id, Decision) ->
    fun(Item) ->
        maps:get(subject_id, Item, undefined) =:= Id andalso
            maps:get(decision, Item, undefined) =:= Decision
    end.
