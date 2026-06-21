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

device_bound_ovpn_provisioning_preview_allows_ready_device_test() ->
    ias_demo_store:clear(),
    #{device := Device, service := Service} = setup_ready_device(administrator),
    _CaCertificate = link_ca_certificate(Service, <<"ovpn_export_device_ca_certificate">>),

    Preview = ias_ovpn_export:device_provisioning_preview(maps:get(id, Device)),

    ?assertEqual(allow, maps:get(provisioning, Preview)),
    ?assertEqual(ready, maps:get(provisioning_status, Preview)),
    ?assertEqual(satisfied, maps:get(device_lock_status, Preview)),
    ?assertEqual(available, maps:get(vpn_endpoint_status, Preview)),
    ?assertEqual(available, maps:get(export_artifact, Preview)),
    ?assertEqual(maps:get(id, Service), maps:get(vpn_service_id, Preview)).

device_bound_ovpn_provisioning_preview_requires_ca_certificate_test() ->
    ias_demo_store:clear(),
    #{device := Device} = setup_ready_device(administrator),

    Preview = ias_ovpn_export:device_provisioning_preview(maps:get(id, Device)),

    ?assertEqual(deny, maps:get(provisioning, Preview)),
    ?assertEqual(blocked, maps:get(provisioning_status, Preview)),
    ?assertMatch({_, _}, binary:match(maps:get(provisioning_reason, Preview), <<"no CA certificate">>)),
    ?assertEqual(unavailable, maps:get(export_artifact, Preview)).

demo_pages_render_ovpn_export_preview_test() ->
    ias_demo_store:clear(),
    #{device := Device, service := DeviceService} = setup_ready_device(administrator),
    _DeviceCaCertificate = link_ca_certificate(
        DeviceService, <<"ovpn_export_demo_device_ca_certificate">>),
    #{certificate := Certificate, service := CertificateService} = setup_ready_device(default_user),
    _CertificateCaCertificate = link_ca_certificate(
        CertificateService, <<"ovpn_export_demo_certificate_ca_certificate">>),

    DeviceHtml = iolist_to_binary(nitro:render(ias_demo:ovpn_export_preview(Device))),
    CertificateHtml = iolist_to_binary(nitro:render(ias_demo:ovpn_export_preview(Certificate))),

    ?assertMatch({_, _}, binary:match(DeviceHtml, <<"DEVICE OVPN PROVISIONING">>)),
    ?assertMatch({_, _}, binary:match(DeviceHtml, <<"DIRECT OVPN EXPORT PREVIEW">>)),
    ?assertMatch({_, _}, binary:match(DeviceHtml, <<"remote vpn.example.com 1194">>)),
    ?assertMatch({_, _}, binary:match(CertificateHtml, <<"DIRECT OVPN EXPORT PREVIEW">>)),
    ?assertMatch({_, _}, binary:match(CertificateHtml, <<"# not exported by IAS">>)),
    ?assertMatch({_, _}, binary:match(CertificateHtml, <<"Download OVPN Skeleton">>)),
    ?assertMatch({_, _}, binary:match(CertificateHtml, <<"Create Portable Provisioning">>)),
    ?assertMatch({_, _}, binary:match(DeviceHtml, <<"Create Device-bound Provisioning">>)).

denied_ovpn_export_preview_renders_warning_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(administrator),
    {ok, _Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),

    Html = iolist_to_binary(nitro:render(ias_demo:ovpn_export_preview(Device))),

    ?assertMatch({_, _}, binary:match(Html,
        <<"A direct OVPN profile cannot be exported for this subject under the current policy.">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Direct Export Blocked">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"remote vpn.example.com 1194">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Download OVPN Skeleton">>)).

allowed_certificate_generates_demo_ovpn_artifact_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(default_user),

    {ok, Filename, Content} = ias_ovpn_export:certificate_artifact(maps:get(id, Certificate)),

    ?assertMatch({_, _}, binary:match(Filename, <<".ovpn">>)),
    ?assertMatch({_, _}, binary:match(Content, <<"remote vpn.example.com 1194">>)),
    ?assertMatch({_, _}, binary:match(Content, <<"# device-owned private key">>)),
    ?assertEqual(nomatch, binary:match(Content, <<"PRIVATE KEY-----">>)),
    ?assertEqual(nomatch, binary:match(Content, <<"BEGIN CERTIFICATE">>)).

denied_certificate_rejects_demo_ovpn_artifact_test() ->
    ias_demo_store:clear(),
    Certificate = ias_demo_store:add_certificate(#{id => <<"ovpn_export_denied_artifact_certificate">>,
                                                   source => certificate_issue_demo,
                                                   profile_id => administrator,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),

    {error, Reason} = ias_ovpn_export:certificate_artifact(maps:get(id, Certificate)),

    ?assertEqual(<<"no device binding">>, Reason).

linked_vpn_service_ca_certificate_appears_in_ovpn_export_preview_test() ->
    ias_demo_store:clear(),
    #{device := Device, service := Service} = setup_ready_device(default_user),
    CaCertificate = ias_demo_store:add_certificate(#{id => <<"ovpn_export_ca_certificate">>,
                                                     source => ca_certificate,
                                                     subject => <<"CN=CA">>}),
    {ok, _CaLink} = ias_relationship_link:create(uses_ca_certificate,
                                                 maps:get(id, Service),
                                                 maps:get(id, CaCertificate)),

    Preview = ias_ovpn_export:device_preview(maps:get(id, Device)),

    ?assertEqual(maps:get(id, CaCertificate), maps:get(ca_certificate_id, Preview)),
    ?assertEqual(maps:get(trust,
                          ias_trust_status:effective_certificate_status(maps:get(id, CaCertificate))),
                 maps:get(ca_certificate_status, Preview)).

allowed_device_generates_demo_ovpn_artifact_test() ->
    ias_demo_store:clear(),
    #{device := Device, service := Service} = setup_ready_device(administrator),
    _CaCertificate = link_ca_certificate(Service, <<"ovpn_export_device_artifact_ca_certificate">>),

    {ok, Filename, Content} = ias_ovpn_export:device_artifact(maps:get(id, Device)),

    ?assertMatch({_, _}, binary:match(Filename, <<".ovpn">>)),
    ?assertMatch({_, _}, binary:match(Content, <<"client">>)),
    ?assertMatch({_, _}, binary:match(Content, <<"remote vpn.example.com 1194">>)).

portable_ovpn_provisioning_transaction_is_stored_without_secret_material_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate, service := Service} = setup_ready_device(default_user),
    CaCertificate = link_ca_certificate(Service, <<"ovpn_portable_transaction_ca">>),

    {ok, Transaction} = ias_ovpn_provisioning:create(
        portable, certificate, maps:get(id, Certificate)),
    ProvisioningId = maps:get(provisioning_id, Transaction),

    ?assertEqual(ovpn_provisioning, maps:get(kind, Transaction)),
    ?assertEqual(portable, maps:get(mode, Transaction)),
    ?assertEqual(awaiting_material, maps:get(status, Transaction)),
    ?assertEqual(pending_real_material, maps:get(material_status, Transaction)),
    ?assertEqual(skeleton_only, maps:get(artifact_status, Transaction)),
    ?assertEqual(not_ready, maps:get(delivery_status, Transaction)),
    ?assertEqual(one_time_in_memory, maps:get(private_key_policy, Transaction)),
    ?assertEqual(required, maps:get(ca_certificate, maps:get(material_requirements, Transaction))),
    ?assertEqual(required, maps:get(client_certificate, maps:get(material_requirements, Transaction))),
    ?assertEqual(pending_one_time_generation,
                 maps:get(private_key, maps:get(material_requirements, Transaction))),
    ?assertEqual(ca_certificate_store,
                 maps:get(ca_certificate, maps:get(material_sources, Transaction))),
    ?assertEqual(missing_body,
                 maps:get(ca_certificate, maps:get(material_components, Transaction))),
    ?assertEqual(missing_body,
                 maps:get(client_certificate, maps:get(material_components, Transaction))),
    ?assertEqual(pending_one_time_generation,
                 maps:get(private_key, maps:get(material_components, Transaction))),
    ?assertEqual(blocked, maps:get(assembly_status, Transaction)),
    ?assertMatch({_, _}, binary:match(maps:get(assembly_reason, Transaction),
                                     <<"CA certificate PEM is unavailable">>)),
    ?assertMatch({_, _}, binary:match(maps:get(assembly_reason, Transaction),
                                     <<"client certificate PEM is unavailable">>)),
    ?assertMatch({_, _}, binary:match(maps:get(next_step, Transaction),
                                     <<"CA/CMP response">>)),
    ?assertEqual(maps:get(id, Certificate), maps:get(certificate_id, Transaction)),
    ?assertEqual(maps:get(id, Service), maps:get(vpn_service_id, Transaction)),
    ?assertEqual(maps:get(id, CaCertificate), maps:get(ca_certificate_id, Transaction)),
    ?assertEqual(false, maps:get(downloaded, Transaction)),
    ?assertEqual(false, maps:get(private_key_stored, Transaction)),
    ?assertEqual(false, maps:get(certificate_body_stored, Transaction)),
    ?assertEqual(false, maps:get(ca_body_stored, Transaction)),
    ?assertEqual(false, maps:is_key(private_key, Transaction)),
    ?assertEqual(false, maps:is_key(private_key_body, Transaction)),
    ?assertEqual(false, maps:is_key(certificate_body, Transaction)),
    ?assertEqual(false, maps:is_key(ca_body, Transaction)),
    ?assertMatch({ok, #{kind := ovpn_provisioning}},
                 ias_ovpn_provisioning:get(ProvisioningId)).

portable_ovpn_provisioning_rejects_device_bound_profile_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate, service := Service} = setup_ready_device(administrator),
    _CaCertificate = link_ca_certificate(Service, <<"ovpn_portable_device_bound_ca">>),

    Preview = ias_ovpn_provisioning:preview(
        portable, certificate, maps:get(id, Certificate)),
    {error, Reason} = ias_ovpn_provisioning:create(
        portable, certificate, maps:get(id, Certificate)),
    {error, ArtifactReason} = ias_ovpn_export:certificate_artifact(
        maps:get(id, Certificate)),
    Html = iolist_to_binary(nitro:render(ias_demo:ovpn_export_preview(Certificate))),

    ?assertEqual(deny, maps:get(authorization, Preview)),
    ?assertEqual(blocked, maps:get(status, Preview)),
    ?assertEqual(
        <<"device-bound security profile requires device-bound provisioning">>,
        maps:get(authorization_reason, Preview)),
    ?assertEqual(maps:get(authorization_reason, Preview), Reason),
    ?assertEqual(Reason, ArtifactReason),
    ?assertMatch({_, _}, binary:match(Html,
        <<"device-bound security profile requires device-bound provisioning">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Use Device-bound Provisioning">>)),
    ?assertMatch({_, _}, binary:match(Html,
        <<"Open the linked Device and use Create Device-bound Provisioning">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Create Portable Provisioning">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Download OVPN Skeleton">>)),
    ?assertEqual([], [Object || Object <- ias_demo_store:runtime_objects(),
                               maps:get(kind, Object, undefined) =:= ovpn_provisioning]).

portable_ovpn_provisioning_transaction_requires_ca_certificate_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(default_user),

    {error, Reason} = ias_ovpn_provisioning:create(
        portable, certificate, maps:get(id, Certificate)),

    ?assertMatch({_, _}, binary:match(Reason, <<"no CA certificate">>)),
    ?assertEqual([], [Object || Object <- ias_demo_store:runtime_objects(),
                               maps:get(kind, Object, undefined) =:= ovpn_provisioning]).

device_bound_ovpn_provisioning_transaction_records_device_owned_key_policy_test() ->
    ias_demo_store:clear(),
    #{device := Device, service := Service} = setup_ready_device(administrator),
    _CaCertificate = link_ca_certificate(Service, <<"ovpn_device_transaction_ca">>),

    {ok, Transaction} = ias_ovpn_provisioning:create(
        device_bound, device, maps:get(id, Device)),

    ?assertEqual(device_bound, maps:get(mode, Transaction)),
    ?assertEqual(device_owned, maps:get(private_key_policy, Transaction)),
    ?assertEqual(device_owned,
                 maps:get(private_key, maps:get(material_requirements, Transaction))),
    ?assertEqual(device,
                 maps:get(private_key, maps:get(material_sources, Transaction))),
    ?assertEqual(available_on_device,
                 maps:get(private_key, maps:get(material_components, Transaction))),
    ?assertEqual(blocked, maps:get(assembly_status, Transaction)),
    ?assertEqual(maps:get(id, Device), maps:get(device_id, Transaction)),
    ?assertEqual(awaiting_material, maps:get(status, Transaction)),

    Html = iolist_to_binary(nitro:render(ias_demo:ovpn_material_preview(Transaction))),
    ?assertMatch({_, _}, binary:match(Html, <<"Material Requirements">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"CA Certificate PEM">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"available_on_device">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Assembly Readiness">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"client certificate PEM is unavailable">>)).

vpn_service_demo_page_renders_export_readiness_test() ->
    ias_demo_store:clear(),
    #{service := Service} = setup_ready_device(default_user),
    CaCertificate = ias_demo_store:add_certificate(#{id => <<"ovpn_export_service_ca_certificate">>,
                                                     source => ca_certificate,
                                                     subject => <<"CN=CA">>}),
    {ok, _CaLink} = ias_relationship_link:create(uses_ca_certificate,
                                                 maps:get(id, Service),
                                                 maps:get(id, CaCertificate)),

    Html = iolist_to_binary(nitro:render(ias_demo:ovpn_export_preview(Service))),

    ?assertMatch({_, _}, binary:match(Html, <<"OVPN EXPORT READINESS">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"VPN service is ready for OVPN export preview">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"selected during user/device provisioning">>)).

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

link_ca_certificate(Service, CertificateId) ->
    CaCertificate = ias_demo_store:add_certificate(#{id => CertificateId,
                                                     source => ca_certificate,
                                                     subject => <<"CN=CA">>}),
    {ok, _CaLink} = ias_relationship_link:create(uses_ca_certificate,
                                                 maps:get(id, Service),
                                                 maps:get(id, CaCertificate)),
    CaCertificate.

export_for(Id, Kind, Authorization) ->
    fun(Preview) ->
        maps:get(subject_id, Preview, undefined) =:= Id andalso
            maps:get(subject_kind, Preview, undefined) =:= Kind andalso
            maps:get(authorization, Preview, undefined) =:= Authorization
    end.
