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
    ?assert(lists:member(<<"profile administrator allows use_ias">>,
                         maps:get(reasons, Decision))).

administrator_certificate_allows_issue_and_revoke_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(true),

    Issue = ias_authorization_decision:certificate_decision(maps:get(id, Certificate),
                                                            issue_certificate),
    Revoke = ias_authorization_decision:certificate_decision(maps:get(id, Certificate),
                                                             revoke_certificate),

    ?assertEqual(allow, maps:get(decision, Issue)),
    ?assert(lists:member(<<"profile administrator allows issue_certificate">>,
                         maps:get(reasons, Issue))),
    ?assertEqual(allow, maps:get(decision, Revoke)),
    ?assert(lists:member(<<"profile administrator allows revoke_certificate">>,
                         maps:get(reasons, Revoke))).

default_user_certificate_denies_issue_and_revoke_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device_for_profile(default_user, true),

    UseIas = ias_authorization_decision:certificate_decision(maps:get(id, Certificate),
                                                             use_ias),
    Issue = ias_authorization_decision:certificate_decision(maps:get(id, Certificate),
                                                            issue_certificate),
    Revoke = ias_authorization_decision:certificate_decision(maps:get(id, Certificate),
                                                             revoke_certificate),

    ?assertEqual(allow, maps:get(decision, UseIas)),
    ?assert(lists:member(<<"profile default_user allows use_ias">>,
                         maps:get(reasons, UseIas))),
    ?assertEqual(deny, maps:get(decision, Issue)),
    ?assert(lists:member(<<"profile default_user does not allow issue_certificate">>,
                         maps:get(reasons, Issue))),
    ?assertEqual(deny, maps:get(decision, Revoke)),
    ?assert(lists:member(<<"profile default_user does not allow revoke_certificate">>,
                         maps:get(reasons, Revoke))).

certificate_without_profile_is_denied_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(true),
    CertificateWithoutProfile = Certificate#{id => <<"auth_no_profile_certificate">>},
    Stored = ias_demo_store:add_certificate(maps:without([profile, profile_id],
                                                         CertificateWithoutProfile)),
    DeviceWithoutProfileCertificate = ias_demo_store:add_device(#{
        id => <<"authorization_no_profile_device">>,
        source => manual_device
    }),
    {ok, _DeviceLink} = ias_relationship_link:create(uses_certificate,
                                                     maps:get(id, DeviceWithoutProfileCertificate),
                                                     maps:get(id, Stored)),
    {ok, _Policy} = ias_relationship_link:create(uses_security_policy,
                                                 maps:get(id, Stored),
                                                 <<"high_security">>),
    {ok, _Verification} = ias_certificate_verification:verify(
        Stored#{certificate_id => maps:get(id, Stored),
                subject_cn => maps:get(id, Stored),
                issuer_cn => <<"Zencrypted Dev CA">>,
                profile => administrator_profile(),
                profile_id => administrator,
                claims => administrator_claims(),
                trusted => true,
                key_match => true}),

    Decision = ias_authorization_decision:certificate_decision(maps:get(id, Stored),
                                                               use_ias),

    ?assertEqual(deny, maps:get(decision, Decision)),
    ?assert(lists:member(<<"profile not found">>, maps:get(reasons, Decision))).

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

    ?assertMatch({_, _}, binary:match(Html, <<"ACTION AUTHORIZATION PREVIEW">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"access_vpn">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"deny">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"no vpn service">>)).

certificate_page_renders_authorization_matrix_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(true),

    Html = iolist_to_binary(nitro:render(ias_demo:authorization_matrix_preview(Certificate))),

    ?assertMatch({_, _}, binary:match(Html, <<"AUTHORIZATION MATRIX">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"use_ias">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"issue_certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"revoke_certificate">>)),
    ?assertMatch({_, _}, binary:match(Html,
                                      <<"profile administrator allows issue_certificate">>)).

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

graph_analysis_report_groups_certificates_by_authorization_profile_test() ->
    ias_demo_store:clear(),
    #{certificate := AdministratorCertificate} = setup_ready_device(true),
    #{certificate := UserCertificate} = setup_ready_device_for_profile(default_user, true),

    Report = ias_graph_analysis:report(),

    ?assert(lists:any(profile_certificate(maps:get(id, AdministratorCertificate), administrator),
                      maps:get(authorization_administrators, Report))),
    ?assert(lists:any(profile_certificate(maps:get(id, UserCertificate), default_user),
                      maps:get(authorization_users, Report))).

setup_ready_device(LinkCertificatePolicy) ->
    setup_ready_device_for_profile(administrator, LinkCertificatePolicy).

setup_ready_device_for_profile(ProfileId, LinkCertificatePolicy) ->
    Profile = profile(ProfileId),
    Claims = ias_policy:certificate_claims(Profile),
    PolicyId = policy_id(ProfileId),
    Device = ias_demo_store:add_device(#{id => test_id(ProfileId, <<"device">>),
                                         source => ovpn_demo_import,
                                         import_id => test_id(ProfileId, <<"import">>),
                                         type => <<"vpn-client">>}),
    Certificate = ias_demo_store:add_certificate(#{id => test_id(ProfileId, <<"certificate">>),
                                                   source => ovpn_demo_import,
                                                   import_id => test_id(ProfileId, <<"import">>),
                                                   profile_id => ProfileId,
                                                   profile => ProfileId,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),
    Service = ias_demo_store:add_service(#{id => test_id(ProfileId, <<"service">>),
                                           source => ovpn_demo_import,
                                           import_id => test_id(ProfileId, <<"import">>),
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
                                                       PolicyId),
    maybe_link_certificate_policy(LinkCertificatePolicy, Certificate, PolicyId),
    {ok, _Verification} = ias_certificate_verification:verify(
        Certificate#{certificate_id => maps:get(id, Certificate),
                     subject_cn => maps:get(id, Certificate),
                     issuer_cn => <<"Zencrypted Dev CA">>,
                     profile => Profile,
                     profile_id => ProfileId,
                     claims => Claims,
                     trusted => true,
                     key_match => true}),
    #{device => Device,
      certificate => Certificate,
      service => Service}.

maybe_link_certificate_policy(true, Certificate, PolicyId) ->
    {ok, _CertificatePolicy} = ias_relationship_link:create(uses_security_policy,
                                                            maps:get(id, Certificate),
                                                            PolicyId),
    ok;
maybe_link_certificate_policy(false, _Certificate, _PolicyId) ->
    ok.

administrator_profile() ->
    profile(administrator).

administrator_claims() ->
    ias_policy:certificate_claims(administrator_profile()).

profile(ProfileId) ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile, undefined) =:= ProfileId],
    Profile.

policy_id(administrator) ->
    <<"high_security">>;
policy_id(default_user) ->
    <<"standard">>.

test_id(ProfileId, Suffix) ->
    ias_html:join([<<"authorization_">>, ias_html:text(ProfileId), <<"_">>, Suffix]).

decision_for(Id, Decision) ->
    fun(Item) ->
        maps:get(subject_id, Item, undefined) =:= Id andalso
            maps:get(decision, Item, undefined) =:= Decision
    end.

profile_certificate(Id, ProfileId) ->
    fun(Item) ->
        maps:get(id, Item, undefined) =:= Id andalso
            maps:get(profile, Item, undefined) =:= ProfileId
    end.
