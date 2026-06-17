-module(ias_authorization_enforcement_tests).
-include_lib("eunit/include/eunit.hrl").

device_enforcement_allows_vpn_connection_for_ready_device_test() ->
    ias_demo_store:clear(),
    #{device := Device} = setup_ready_device(administrator),

    Enforcement = ias_authorization_enforcement:device_enforcement(maps:get(id, Device)),

    ?assertEqual(<<"VPN Connection">>, maps:get(operation, Enforcement)),
    ?assertEqual(allow, maps:get(result, Enforcement)),
    ?assertEqual(<<"authorization decision allowed">>, maps:get(reason, Enforcement)).

device_enforcement_denies_vpn_connection_for_incomplete_device_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"enforcement_incomplete_device">>,
                                         source => ovpn_demo_import}),

    Enforcement = ias_authorization_enforcement:device_enforcement(maps:get(id, Device)),

    ?assertEqual(<<"VPN Connection">>, maps:get(operation, Enforcement)),
    ?assertEqual(deny, maps:get(result, Enforcement)),
    ?assertMatch({_, _}, binary:match(maps:get(reason, Enforcement), <<"no vpn service">>)).

certificate_enforcement_maps_profile_decisions_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(administrator),

    Enforcements = ias_authorization_enforcement:certificate_enforcement(
                     maps:get(id, Certificate)),

    ?assertEqual(allow, operation_result(<<"IAS Access">>, Enforcements)),
    ?assertEqual(allow, operation_result(<<"Certificate Issuance">>, Enforcements)),
    ?assertEqual(allow, operation_result(<<"Certificate Revocation">>, Enforcements)).

default_user_certificate_enforcement_denies_admin_operations_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(default_user),

    Enforcements = ias_authorization_enforcement:certificate_enforcement(
                     maps:get(id, Certificate)),

    ?assertEqual(allow, operation_result(<<"IAS Access">>, Enforcements)),
    ?assertEqual(deny, operation_result(<<"Certificate Issuance">>, Enforcements)),
    ?assertEqual(deny, operation_result(<<"Certificate Revocation">>, Enforcements)),
    ?assertMatch({_, _}, binary:match(operation_reason(<<"Certificate Issuance">>,
                                                       Enforcements),
                                      <<"profile default_user does not allow issue_certificate">>)).

authorization_enforcement_preview_does_not_write_runtime_state_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(administrator),
    Before = length(ias_demo_store:runtime_objects()),

    _Device = ias_authorization_enforcement:device_enforcement(maps:get(id, Device)),
    _Certificate = ias_authorization_enforcement:certificate_enforcement(maps:get(id, Certificate)),
    After = length(ias_demo_store:runtime_objects()),

    ?assertEqual(Before, After).

demo_pages_render_authorization_enforcement_preview_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(administrator),

    DeviceHtml = iolist_to_binary(nitro:render(
        ias_demo:authorization_enforcement_preview(Device))),
    CertificateHtml = iolist_to_binary(nitro:render(
        ias_demo:authorization_enforcement_preview(Certificate))),

    ?assertMatch({_, _}, binary:match(DeviceHtml,
                                      <<"AUTHORIZATION ENFORCEMENT PREVIEW">>)),
    ?assertMatch({_, _}, binary:match(DeviceHtml, <<"VPN Connection">>)),
    ?assertMatch({_, _}, binary:match(CertificateHtml, <<"IAS Access">>)),
    ?assertMatch({_, _}, binary:match(CertificateHtml, <<"Certificate Issuance">>)),
    ?assertMatch({_, _}, binary:match(CertificateHtml, <<"Certificate Revocation">>)).

graph_analysis_report_includes_enforcement_summary_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := AdminCertificate} = setup_ready_device(administrator),
    #{certificate := UserCertificate} = setup_ready_device(default_user),
    _DeniedDevice = ias_demo_store:add_device(#{id => <<"enforcement_denied_device">>,
                                                source => ovpn_demo_import}),

    Report = ias_graph_analysis:report(),

    ?assert(lists:any(enforcement_for(maps:get(id, Device), <<"VPN Connection">>, allow),
                      maps:get(vpn_access_allowed, Report))),
    ?assert(lists:any(enforcement_for(<<"enforcement_denied_device">>,
                                      <<"VPN Connection">>, deny),
                      maps:get(vpn_access_denied, Report))),
    ?assert(lists:any(enforcement_for(maps:get(id, AdminCertificate),
                                      <<"Certificate Issuance">>, allow),
                      maps:get(certificate_issuance_allowed, Report))),
    ?assert(lists:any(enforcement_for(maps:get(id, UserCertificate),
                                      <<"Certificate Issuance">>, deny),
                      maps:get(certificate_issuance_denied, Report))),
    ?assert(lists:any(enforcement_for(maps:get(id, AdminCertificate),
                                      <<"Certificate Revocation">>, allow),
                      maps:get(certificate_revocation_allowed, Report))),
    ?assert(lists:any(enforcement_for(maps:get(id, UserCertificate),
                                      <<"Certificate Revocation">>, deny),
                      maps:get(certificate_revocation_denied, Report))).

setup_ready_device(ProfileId) ->
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
    {ok, _CertificatePolicy} = ias_relationship_link:create(uses_security_policy,
                                                            maps:get(id, Certificate),
                                                            PolicyId),
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

operation_result(Operation, Enforcements) ->
    maps:get(result, operation(Operation, Enforcements)).

operation_reason(Operation, Enforcements) ->
    maps:get(reason, operation(Operation, Enforcements)).

operation(Operation, Enforcements) ->
    [Enforcement] = [Enforcement || Enforcement <- Enforcements,
                                    maps:get(operation, Enforcement, undefined) =:= Operation],
    Enforcement.

profile(ProfileId) ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile, undefined) =:= ProfileId],
    Profile.

policy_id(administrator) ->
    <<"high_security">>;
policy_id(default_user) ->
    <<"standard">>.

test_id(ProfileId, Suffix) ->
    ias_html:join([<<"enforcement_">>, ias_html:text(ProfileId), <<"_">>, Suffix]).

enforcement_for(SubjectId, Operation, Result) ->
    fun(Enforcement) ->
        maps:get(subject_id, Enforcement, undefined) =:= SubjectId andalso
            maps:get(operation, Enforcement, undefined) =:= Operation andalso
            maps:get(result, Enforcement, undefined) =:= Result
    end.
