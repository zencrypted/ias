-module(ias_ovpn_export_tests).
-include_lib("eunit/include/eunit.hrl").

device_ovpn_export_preview_allows_ready_device_test() ->
    ias_demo_store:clear(),
    #{device := Device} = setup_ready_device(administrator),

    Preview = ias_ovpn_export:device_preview(maps:get(id, Device)),

    ?assertEqual(allow, maps:get(authorization, Preview)),
    ?assertEqual(enabled, maps:get(device_lock, Preview)),
    ?assertEqual(required, maps:get(two_factor, Preview)),
    ?assertEqual(<<"vpn.example.com">>, maps:get(remote_host, Preview)),
    ?assertEqual(<<"1194">>, maps:get(remote_port, Preview)),
    ?assertEqual(<<"udp">>, maps:get(protocol, Preview)),
    ?assertEqual(trusted, maps:get(certificate_status, Preview)).

certificate_ovpn_export_preview_uses_bound_device_context_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(default_user),

    Preview = ias_ovpn_export:certificate_preview(maps:get(id, Certificate)),

    ?assertEqual(allow, maps:get(authorization, Preview)),
    ?assertEqual(disabled, maps:get(device_lock, Preview)),
    ?assertEqual(optional, maps:get(two_factor, Preview)),
    ?assertEqual(<<"vpn.example.com">>, maps:get(remote_host, Preview)).

ovpn_export_preview_skeleton_does_not_include_private_material_test() ->
    ias_demo_store:clear(),
    #{device := Device} = setup_ready_device(administrator),

    Preview = ias_ovpn_export:device_preview(maps:get(id, Device)),
    Profile = maps:get(preview, Preview),

    ?assertMatch({_, _}, binary:match(Profile, <<"client">>)),
    ?assertMatch({_, _}, binary:match(Profile, <<"<ca>\n...\n</ca>">>)),
    ?assertMatch({_, _}, binary:match(Profile, <<"<cert>\n...\n</cert>">>)),
    ?assertMatch({_, _}, binary:match(Profile, <<"# device-owned private key">>)),
    ?assertMatch({_, _}, binary:match(Profile, <<"# not exported by IAS">>)),
    ?assertEqual(nomatch, binary:match(Profile, <<"PRIVATE KEY-----">>)),
    ?assertEqual(nomatch, binary:match(Profile, <<"BEGIN CERTIFICATE">>)).

revoked_certificate_denies_ovpn_export_preview_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(administrator),
    {ok, _Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),

    Preview = ias_ovpn_export:device_preview(maps:get(id, Device)),

    ?assertEqual(deny, maps:get(authorization, Preview)),
    ?assertMatch({_, _}, binary:match(maps:get(authorization_reason, Preview),
                                      <<"current certificate revoked">>)).

certificate_without_device_binding_denies_ovpn_export_preview_test() ->
    ias_demo_store:clear(),
    Certificate = ias_demo_store:add_certificate(#{id => <<"ovpn_export_unbound_certificate">>,
                                                   source => certificate_issue_demo,
                                                   profile_id => administrator,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),

    Preview = ias_ovpn_export:certificate_preview(maps:get(id, Certificate)),

    ?assertEqual(deny, maps:get(authorization, Preview)),
    ?assertEqual(<<"no device binding">>, maps:get(authorization_reason, Preview)).

demo_pages_render_ovpn_export_preview_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(administrator),

    DeviceHtml = iolist_to_binary(nitro:render(ias_demo:ovpn_export_preview(Device))),
    CertificateHtml = iolist_to_binary(nitro:render(ias_demo:ovpn_export_preview(Certificate))),

    ?assertMatch({_, _}, binary:match(DeviceHtml, <<"OVPN EXPORT PREVIEW">>)),
    ?assertMatch({_, _}, binary:match(DeviceHtml, <<"remote vpn.example.com 1194">>)),
    ?assertMatch({_, _}, binary:match(CertificateHtml, <<"OVPN EXPORT PREVIEW">>)),
    ?assertMatch({_, _}, binary:match(CertificateHtml, <<"# not exported by IAS">>)).

denied_ovpn_export_preview_renders_warning_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(administrator),
    {ok, _Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),

    Html = iolist_to_binary(nitro:render(ias_demo:ovpn_export_preview(Device))),

    ?assertMatch({_, _}, binary:match(Html,
        <<"OVPN profile would not be provisioned because authorization is denied.">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Profile Generation Blocked">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"remote vpn.example.com 1194">>)).

graph_analysis_report_includes_ovpn_export_summary_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(administrator),
    DeniedDevice = ias_demo_store:add_device(#{id => <<"ovpn_export_denied_device">>,
                                               source => ovpn_demo_import}),

    Report = ias_graph_analysis:report(),

    ?assert(lists:any(export_for(maps:get(id, Device), device, allow),
                      maps:get(ovpn_export_allowed, Report))),
    ?assert(lists:any(export_for(maps:get(id, Certificate), certificate, allow),
                      maps:get(ovpn_export_allowed, Report))),
    ?assert(lists:any(export_for(maps:get(id, DeniedDevice), device, deny),
                      maps:get(ovpn_export_denied, Report))).

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
                                           remote => <<"vpn.example.com:1194">>,
                                           protocol => udp}),
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

profile(ProfileId) ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile, undefined) =:= ProfileId],
    Profile.

policy_id(administrator) ->
    <<"high_security">>;
policy_id(default_user) ->
    <<"standard">>.

test_id(ProfileId, Suffix) ->
    ias_html:join([<<"ovpn_export_">>, ias_html:text(ProfileId), <<"_">>, Suffix]).

export_for(Id, Kind, Authorization) ->
    fun(Preview) ->
        maps:get(subject_id, Preview, undefined) =:= Id andalso
            maps:get(subject_kind, Preview, undefined) =:= Kind andalso
            maps:get(authorization, Preview, undefined) =:= Authorization
    end.
