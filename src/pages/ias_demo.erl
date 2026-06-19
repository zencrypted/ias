-module(ias_demo).
-export([event/1, relationship_rows/2, certificate_lifecycle_preview/1,
         operational_readiness_preview/1, effective_status_preview/1,
         authorization_decision_preview/1, authorization_matrix_preview/1,
         authorization_enforcement_preview/1, ovpn_export_preview/1]).
-include_lib("n2o/include/n2o.hrl").
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event({link_relationship, RelationType, SourceId, TargetId}) ->
    _ = ias_relationship_link:create(RelationType, SourceId, TargetId),
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event({unlink_relationship, RelationshipId}) ->
    _ = ias_relationship_link:unlink(RelationshipId),
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event({replace_certificate, DeviceId}) ->
    _ = ias_certificate_replacement:replace(DeviceId),
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event({revoke_certificate, CertificateId}) ->
    _ = ias_certificate_revocation:revoke(CertificateId),
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event({download_ovpn_artifact, device, DeviceId}) ->
    download_ovpn_artifact(ias_ovpn_export:device_artifact(DeviceId));
event({download_ovpn_artifact, certificate, CertificateId}) ->
    download_ovpn_artifact(ias_ovpn_export:certificate_artifact(CertificateId));
event(_) ->
    ok.

content() ->
    case ias_demo_store:get(query_id()) of
        {ok, Object} -> detail(Object);
        not_found -> not_found()
    end.

query_id() ->
    Cx = get(context),
    Req = Cx#cx.req,
    case Req of
        #{qs := QS} ->
            proplists:get_value(<<"id">>, uri_string:dissect_query(nitro:to_binary(QS)));
        #{query_string := QS} ->
            proplists:get_value(<<"id">>, uri_string:dissect_query(nitro:to_binary(QS)));
        _ ->
            nitro:qc(id)
    end.

detail(Object) ->
    #panel{class = <<"ias-placeholder">>, body = [
        breadcrumb(),
        #h2{body = ias_html:text("Demo Object")},
        #p{body = ias_html:text("Read-only metadata stored in ETS demo runtime state.")},
        #h3{body = title(Object)},
        key_value_table(rows(Object)),
        certificate_lifecycle_preview(Object),
        operational_readiness_preview(Object),
        effective_status_preview(Object),
        identity_authorization_status(Object),
        authorization_decision_preview(Object),
        authorization_matrix_preview(Object),
        authorization_enforcement_preview(Object),
        ovpn_export_preview(Object),
        security_profile_preview(Object),
        relationship_preview(Object),
        policy_consistency_preview(Object)
    ]}.

not_found() ->
    #panel{class = <<"ias-placeholder">>, body = [
        breadcrumb(),
        #h2{body = ias_html:text("Demo Object Not Found")},
        #p{body = ias_html:text("The requested demo object is not available in ETS runtime state.")}
    ]}.

breadcrumb() ->
    #p{style = <<"font-size:12px;color:#64748b;">>,
       body = [#link{url = <<"/app/index.htm">>, body = ias_html:text("IAS")},
               ias_html:text(" -> Demo Object")]}.

title(#{kind := device}) ->
    <<"Device Metadata">>;
title(#{kind := certificate}) ->
    <<"Certificate Metadata">>;
title(#{kind := vpn_service}) ->
    <<"VPN Service Metadata">>;
title(#{kind := security_policy}) ->
    <<"Security Policy Metadata">>;
title(#{kind := relationship}) ->
    <<"Relationship Metadata">>;
title(#{kind := verification}) ->
    <<"Verification Metadata">>;
title(#{kind := cmp_enrollment_result}) ->
    <<"Certificate Enrollment Metadata">>;
title(#{kind := certificate_replacement}) ->
    <<"Certificate Replacement Metadata">>;
title(#{kind := certificate_revocation}) ->
    <<"Certificate Revocation Metadata">>;
title(_) ->
    <<"Demo Metadata">>.

rows(#{kind := device} = Object) ->
    common_rows(Object) ++ [
        {"Type", maps:get(type, Object, undefined)},
        {"Endpoint", maps:get(endpoint, Object, undefined)},
        {"Transport", maps:get(transport, Object, undefined)},
        {"Tunnel Device", maps:get(tunnel_device, Object, undefined)}
    ] ++ created_row(Object);
rows(#{kind := certificate} = Object) ->
    Metadata = ias_certificate_detail:metadata(Object),
    common_rows(Object) ++ [
        {"Certificate Type", ias_certificate_detail:certificate_class(Object)},
        {"Certificate Type Note", ias_certificate_detail:certificate_class_note(Object)},
        {"Issued User", user_ref(maps:get(issued_user_id, Metadata, undefined))},
        {"Source Security Profile", profile_ref(maps:get(source_security_profile, Metadata, undefined))},
        {"Issued From Enrollment", enrollment_ref(issued_from_enrollment_id(Object))},
        {"Issued From Enrollment Certificate", certificate_ref(issued_from_certificate_id(Object))},
        {"Issued Certificate", certificate_ref(issued_certificate_id(Object))},
        {"Subject", maps:get(subject, Object, undefined)},
        {"Subject CN", maps:get(subject_cn, Object, undefined)},
        {"Issuer", maps:get(issuer, Object, undefined)},
        {"Not Before", maps:get(not_before, Object, undefined)},
        {"Not After", maps:get(not_after, Object, undefined)},
        {"Requested CN", maps:get(requested_cn, Object, undefined)},
        {"Enrollment CN", maps:get(enrollment_cn, Object, undefined)},
        {"Key Profile", maps:get(profile, Object, undefined)},
        {"CMP Server", maps:get(cmp_server, Object, undefined)},
        {"CA Present", maps:get(ca_present, Object, false)},
        {"Client Certificate Present", maps:get(client_certificate_present, Object, false)},
        {"Private Key Present", maps:get(private_key_present, Object, false)},
        {"Private Key Stored", maps:get(private_key_stored, Object, false)},
        {"Certificate Body Stored", maps:get(certificate_body_stored, Object, false)},
        {"TLS Auth Present", maps:get(tls_auth_present, Object, false)},
        {"Role", maps:get(role, Metadata, undefined)},
        {"Services", ias_html:join_csv(maps:get(services, Metadata, []))},
        {"Attributes", ias_html:join_csv(maps:get(attributes, Metadata, []))},
        {"Trust Level", maps:get(trust_level, Metadata, undefined)},
        {"Device Lock", maps:get(device_lock, Metadata, undefined)},
        {"2FA", maps:get(two_factor, Metadata, undefined)}
    ] ++ created_row(Object);
rows(#{kind := vpn_service} = Object) ->
    common_rows(Object) ++ [
        {"Service", maps:get(service, Object, undefined)},
        {"Remote", maps:get(remote, Object, undefined)},
        {"Protocol", maps:get(protocol, Object, undefined)},
        {"Cipher", maps:get(cipher, Object, undefined)},
        {"Compression", maps:get(compression, Object, false)},
        {"Routes", maps:get(routes, Object, 0)}
    ] ++ created_row(Object);
rows(#{kind := security_policy} = Object) ->
    [
        {"Policy ID", maps:get(policy_id, Object, undefined)},
        {"Profile", ias_security_profile:profile_label(Object)},
        {"Device Lock", ias_security_profile:device_lock_label(Object)},
        {"2FA", ias_security_profile:two_factor_label(Object)},
        {"Enforcement", ias_security_profile:enforcement_label(Object)}
    ];
rows(#{kind := verification} = Object) ->
    common_rows(Object) ++ [
        {"Certificate", object_ref(certificate, maps:get(certificate_id, Object, undefined))},
        {"Certificate Subject", maps:get(certificate_subject, Object, undefined)},
        {"Status", maps:get(verification_status, Object, undefined)},
        {"Service Authorization Result", maps:get(authorization_status, Object, undefined)},
        {"Resolved Profile", maps:get(resolved_profile, Object, undefined)},
        {"Resolved Policy", policy_ref(maps:get(resolved_policy, Object, undefined))},
        {"Trusted", maps:get(trusted, Object, false)},
        {"Key Match", maps:get(key_match, Object, false)}
    ] ++ created_row(Object);
rows(#{kind := relationship} = Object) ->
    [
        {"Relationship ID", maps:get(relationship_id, Object, undefined)},
        {"Relationship Type", maps:get(relation_type, Object, undefined)},
        {"Source", object_ref(maps:get(source_kind, Object, undefined),
                              maps:get(source_id, Object, undefined))},
        {"Target", object_ref(maps:get(target_kind, Object, undefined),
                              maps:get(target_id, Object, undefined))},
        {"Score", maps:get(score, Object, 0)},
        {"Action", relationship_detail_action(Object)}
    ] ++ created_row(Object);
rows(#{kind := cmp_enrollment_result} = Object) ->
    common_rows(Object) ++ [
        {"Enrollment ID", maps:get(enrollment_id, Object, undefined)},
        {"Subject", maps:get(subject, Object, undefined)},
        {"Issuer", maps:get(issuer, Object, undefined)},
        {"Not Before", maps:get(not_before, Object, undefined)},
        {"Not After", maps:get(not_after, Object, undefined)},
        {"Requested CN", maps:get(requested_cn, Object, undefined)},
        {"Enrollment CN", maps:get(enrollment_cn, Object, undefined)},
        {"Key Profile", maps:get(profile, Object, undefined)},
        {"CMP Server", maps:get(cmp_server, Object, undefined)},
        {"Issued Certificate", certificate_ref(issued_certificate_id(Object))}
    ] ++ created_row(Object);
rows(#{kind := certificate_replacement} = Object) ->
    common_rows(Object) ++ [
        {"Device", object_ref(device, maps:get(device_id, Object, undefined))},
        {"Old Certificate", object_ref(certificate, maps:get(old_certificate_id, Object, undefined))},
        {"New Certificate", object_ref(certificate, maps:get(new_certificate_id, Object, undefined))},
        {"Status", maps:get(status, Object, undefined)}
    ] ++ created_row(Object);
rows(#{kind := certificate_revocation} = Object) ->
    common_rows(Object) ++ [
        {"Certificate", object_ref(certificate, maps:get(certificate_id, Object, undefined))},
        {"Reason", maps:get(reason, Object, undefined)},
        {"Status", maps:get(status, Object, undefined)}
    ] ++ created_row(Object);
rows(Object) ->
    common_rows(Object) ++ created_row(Object).

common_rows(Object) ->
    [{"ID", maps:get(id, Object, undefined)},
     {"Import ID", maps:get(import_id, Object, undefined)}].

created_row(Object) ->
    [{"Created At", maps:get(created_at, Object, undefined)}].

key_value_table(Rows) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [key_value_row(Label, Value) || {Label, Value} <- Rows]}}
    ]}.

key_value_row(Label, Value) ->
    #tr{cells = [
        #th{body = ias_html:text(Label)},
        #td{body = cell_body(Value)}
    ]}.

cell_body(#panel{} = Panel) ->
    Panel;
cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

relationship_preview(Object) ->
    case ias_relationship_preview:preview(Object) of
        #{kind := device} = Preview ->
            SourceId = maps:get(id, Object, undefined),
            Relationships = ias_relationship_link:relationships_for(Object),
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("Relationship Preview")},
                relationships_table(Object),
                key_value_table([
                    {"Related Certificate", linked_targets(uses_certificate, Relationships)},
                    {"Related VPN Service", linked_targets(uses_service, Relationships)}
                ]),
                #h3{body = ias_html:text("Suggested Relationships")},
                candidate_table([
                    {"Suggested Certificate", ias_relationship_preview:suggested_candidates(maps:get(suggested_certificates, Preview, [])),
                     uses_certificate, SourceId},
                    {"Suggested VPN Service", ias_relationship_preview:suggested_candidates(maps:get(suggested_services, Preview, [])),
                     uses_service, SourceId}
                ], <<"no candidates">>),
                #h3{body = ias_html:text("Available Objects")},
                candidate_table([
                    {"Available Certificates", ias_relationship_preview:available_candidates(maps:get(suggested_certificates, Preview, [])),
                     uses_certificate, SourceId},
                    {"Available VPN Services", ias_relationship_preview:available_candidates(maps:get(suggested_services, Preview, [])),
                     uses_service, SourceId}
                ], <<"no available objects">>),
                #h3{body = ias_html:text("Suggested Security Policies")},
                candidate_table([
                    {"Security Policy", maps:get(suggested_security_policies, Preview, []),
                     uses_security_policy, SourceId}
                ], <<"no candidates">>)
            ]};
        #{kind := certificate} = Preview ->
            SourceId = maps:get(id, Object, undefined),
            Relationships = ias_relationship_link:relationships_for(Object),
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("Relationship Preview")},
                relationships_table(Object),
                key_value_table([
                    {"Used By Device", linked_sources(uses_certificate, Relationships)},
                    {"Used As CA By", linked_sources(uses_ca_certificate, Relationships)}
                ]),
                #h3{body = ias_html:text("Suggested Relationships")},
                candidate_table([
                    {"Suggested Devices", ias_relationship_preview:suggested_candidates(maps:get(suggested_devices, Preview, [])),
                     uses_certificate, SourceId},
                    {"Suggested VPN Services", ias_relationship_preview:suggested_candidates(maps:get(suggested_ca_services, Preview, [])),
                     uses_ca_certificate, SourceId}
                ], <<"no candidates">>),
                #h3{body = ias_html:text("Available Objects")},
                candidate_table([
                    {"Available Devices", ias_relationship_preview:available_candidates(maps:get(suggested_devices, Preview, [])),
                     uses_certificate, SourceId},
                    {"Available VPN Services", ias_relationship_preview:available_candidates(maps:get(suggested_ca_services, Preview, [])),
                     uses_ca_certificate, SourceId}
                ], <<"no available objects">>),
                #h3{body = ias_html:text("Suggested Security Policies")},
                candidate_table([
                    {"Security Policy", maps:get(suggested_security_policies, Preview, []),
                     uses_security_policy, SourceId}
                ], <<"no candidates">>)
            ]};
        #{kind := vpn_service} = Preview ->
            SourceId = maps:get(id, Object, undefined),
            Relationships = ias_relationship_link:relationships_for(Object),
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("Relationship Preview")},
                relationships_table(Object),
                key_value_table([
                    {"Used By Device", linked_sources(uses_service, Relationships)},
                    {"CA Certificate", linked_targets(uses_ca_certificate, Relationships)},
                    {"Security Policy", linked_targets(uses_security_policy, Relationships)}
                ]),
                #h3{body = ias_html:text("Suggested Relationships")},
                candidate_table([
                    {"Suggested Devices", ias_relationship_preview:suggested_candidates(maps:get(suggested_devices, Preview, [])),
                     uses_service, SourceId},
                    {"Suggested CA Certificates", ias_relationship_preview:suggested_candidates(maps:get(suggested_ca_certificates, Preview, [])),
                     uses_ca_certificate, SourceId}
                ], <<"no candidates">>),
                #h3{body = ias_html:text("Available Objects")},
                candidate_table([
                    {"Available Devices", ias_relationship_preview:available_candidates(maps:get(suggested_devices, Preview, [])),
                     uses_service, SourceId},
                    {"Available CA Certificates", ias_relationship_preview:available_candidates(maps:get(suggested_ca_certificates, Preview, [])),
                     uses_ca_certificate, SourceId}
                ], <<"no available objects">>),
                #h3{body = ias_html:text("Suggested Security Policies")},
                candidate_table([
                    {"Security Policy", maps:get(suggested_security_policies, Preview, []),
                    uses_security_policy, SourceId}
                ], <<"no candidates">>)
            ]};
        #{kind := security_policy} ->
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("Relationship Preview")},
                relationships_table(Object)
            ]};
        _ ->
            case maps:get(kind, Object, undefined) of
                cmp_enrollment_result ->
                    #panel{class = <<"ias-status-card">>, body = [
                        #h3{body = ias_html:text("Relationship Preview")},
                        relationships_table(Object)
                    ]};
                certificate_replacement ->
                    #panel{class = <<"ias-status-card">>, body = [
                        #h3{body = ias_html:text("Relationship Preview")},
                        relationships_table(Object)
                    ]};
                certificate_revocation ->
                    #panel{class = <<"ias-status-card">>, body = [
                        #h3{body = ias_html:text("Relationship Preview")},
                        relationships_table(Object)
                    ]};
                _ ->
                    []
            end
    end.

issued_from_enrollment_id(Object) ->
    case [maps:get(source_id, Relationship, undefined)
          || Relationship <- ias_relationship_link:relationships_for(Object),
             maps:get(relation_type, Relationship, undefined) =:= issues,
             maps:get(source_kind, Relationship, undefined) =:= cmp_enrollment_result] of
        [EnrollmentId | _] -> EnrollmentId;
        [] -> undefined
    end.

issued_from_certificate_id(Object) ->
    case [maps:get(source_id, Relationship, undefined)
          || Relationship <- ias_relationship_link:relationships_for(Object),
             maps:get(relation_type, Relationship, undefined) =:= issues,
             maps:get(source_kind, Relationship, undefined) =:= certificate] of
        [CertificateId | _] -> CertificateId;
        [] -> not_found
    end.

issued_certificate_id(Object) ->
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_relationship_link:relationships_for(Object),
             maps:get(relation_type, Relationship, undefined) =:= issues,
             maps:get(target_kind, Relationship, undefined) =:= certificate] of
        [CertificateId | _] -> CertificateId;
        [] -> not_found
    end.

enrollment_ref(undefined) ->
    <<"not linked yet">>;
enrollment_ref(EnrollmentId) ->
    object_ref(cmp_enrollment_result, EnrollmentId).

policy_consistency_preview(#{kind := device} = Object) ->
    DeviceId = maps:get(id, Object, undefined),
    CertificateId = linked_certificate_id(Object),
    Consistency = ias_policy_consistency:evaluate_policy_consistency(DeviceId, CertificateId),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Policy Consistency")},
        key_value_table([
            {"Device Policy", policy_value(maps:get(device_policy, Consistency, not_found))},
            {"Current Certificate Policy", policy_value(maps:get(certificate_policy, Consistency, not_found))},
            {"Policy Match", policy_match_text(maps:get(match, Consistency, false))},
            {"Reason", policy_reason(Consistency)}
        ])
    ]};
policy_consistency_preview(#{kind := certificate} = Object) ->
    CertificateId = maps:get(id, Object, undefined),
    DeviceId = linked_device_id(Object),
    Consistency = ias_policy_consistency:evaluate_policy_consistency(DeviceId, CertificateId),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Policy Consistency")},
        key_value_table([
            {"Used By Device", linked_object_ref(device, DeviceId)},
            {"Device Policy", policy_value(maps:get(device_policy, Consistency, not_found))},
            {"Certificate Policy", policy_value(maps:get(certificate_policy, Consistency, not_found))},
            {"Policy Match", policy_match_text(maps:get(match, Consistency, false))},
            {"Reason", policy_reason(Consistency)}
        ])
    ]};
policy_consistency_preview(_Object) ->
    [].

linked_certificate_id(Object) ->
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_relationship_link:relationships_for(Object),
             maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
             maps:get(target_kind, Relationship, undefined) =:= certificate] of
        [CertificateId | _] -> CertificateId;
        [] -> undefined
    end.

linked_device_id(Object) ->
    case [maps:get(source_id, Relationship, undefined)
          || Relationship <- ias_relationship_link:relationships_for(Object),
             maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
             maps:get(source_kind, Relationship, undefined) =:= device] of
        [DeviceId | _] -> DeviceId;
        [] -> undefined
    end.

linked_object_ref(_Kind, undefined) ->
    <<"not linked yet">>;
linked_object_ref(Kind, Id) ->
    object_ref(Kind, Id).

policy_match_text(true) ->
    <<"yes">>;
policy_match_text(false) ->
    <<"no">>.

policy_value(not_found) ->
    <<"not linked yet">>;
policy_value(Value) ->
    ias_html:text(Value).

policy_reason(#{reason := <<"no policy available">>}) ->
    <<"no policy available">>;
policy_reason(#{match := true}) ->
    <<"policies match">>;
policy_reason(Consistency) ->
    #panel{body = [
        ias_html:join([<<"device requires ">>,
                       policy_value(maps:get(device_policy, Consistency, not_found))]),
        #br{},
        ias_html:join([<<"certificate provides ">>,
                       policy_value(maps:get(certificate_policy, Consistency, not_found))])
    ]}.

certificate_lifecycle_preview(#{kind := device} = Object) ->
    Status = ias_certificate_role:device_status(Object),
    Transition = ias_certificate_role:replacement_preview(Object),
    CurrentCertificate = maps:get(current_certificate, Status, not_found),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("CERTIFICATE STATUS")},
        key_value_table([
            {"Current Certificate", certificate_ref(CurrentCertificate)},
            {"Candidate Certificate", certificate_ref(maps:get(candidate_certificate, Status, not_found))},
            {"State", lifecycle_text(maps:get(state, Status, undefined))},
            {"Verification Status", ias_certificate_verification:certificate_status(CurrentCertificate)}
        ]),
        #h3{body = ias_html:text("Certificate Transition Preview")},
        key_value_table([
            {"Current", transition_certificate(imported, maps:get(current, Transition, not_found))},
            {"Future", transition_certificate(issued, maps:get(future, Transition, not_found))},
            {"Action", replacement_action(Object)}
        ])
    ] ++ replacement_history_table(Object)};
certificate_lifecycle_preview(#{kind := certificate} = Object) ->
    Role = ias_certificate_role:certificate_role(Object),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("CERTIFICATE ROLE")},
        key_value_table([
            {"Origin", lifecycle_text(maps:get(origin, Role, unknown))},
            {"Role", lifecycle_text(maps:get(role, Role, unassigned))},
            {"Used By Device", device_ref(maps:get(used_by_device, Role, not_found))},
            {"Verification History", verification_history(Object)},
            {"Revocation Status", revocation_status(Object)},
            {"Revocation Record", revocation_record(Object)},
            {"Action", revocation_action(Object)}
        ])
    ]};
certificate_lifecycle_preview(_Object) ->
    [].

operational_readiness_preview(#{kind := device} = Object) ->
    Readiness = device_readiness(Object),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("OPERATIONAL READINESS")},
        key_value_table([
            {"VPN Service", object_or_not_linked(vpn_service,
                                                 maps:get(vpn_service_id, Readiness, not_found))},
            {"Security Policy", object_or_not_linked(security_policy,
                                                     maps:get(security_policy_id, Readiness, not_found))},
            {"Current Certificate", object_or_not_linked(certificate,
                                                         maps:get(current_certificate_id, Readiness, not_found))},
            {"Certificate Verification", readiness_text(
                maps:get(certificate_verification, Readiness, not_verified))},
            {"Certificate Revocation", readiness_text(
                maps:get(certificate_revocation, Readiness, active))},
            {"Overall Status", readiness_status_text(maps:get(status, Readiness, incomplete))}
        ]),
        suggested_actions_panel(Readiness)
    ]};
operational_readiness_preview(_Object) ->
    [].

effective_status_preview(#{kind := certificate} = Object) ->
    Status = ias_trust_status:effective_certificate_status(maps:get(id, Object, undefined)),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("EFFECTIVE TRUST STATUS")},
        key_value_table([
            {"Trust", maps:get(trust, Status, unknown)},
            {"Reasons", status_reasons(maps:get(reasons, Status, []))}
        ])
    ]};
effective_status_preview(#{kind := device} = Object) ->
    Status = ias_trust_status:effective_device_status(maps:get(id, Object, undefined)),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("EFFECTIVE AUTHORIZATION STATUS")},
        key_value_table([
            {"Status", maps:get(status, Status, incomplete)},
            {"Reasons", status_reasons(maps:get(reasons, Status, []))}
        ])
    ]};
effective_status_preview(_Object) ->
    [].

status_reasons([]) ->
    <<"none">>;
status_reasons(Reasons) ->
    #panel{body = [
        #ul{body = [#li{body = ias_html:text(maps:get(text, Reason, undefined))}
                    || Reason <- Reasons]}
    ]}.

authorization_decision_preview(#{kind := device} = Object) ->
    Decision = ias_authorization_decision:device_decision(maps:get(id, Object, undefined),
                                                          access_vpn),
    authorization_decision_card(access_vpn, Decision);
authorization_decision_preview(#{kind := certificate} = Object) ->
    case role_authorization_applicable(Object) of
        true ->
            Decision = ias_authorization_decision:certificate_decision(maps:get(id, Object, undefined),
                                                                       use_ias),
            authorization_decision_card(use_ias, Decision);
        false ->
            []
    end;
authorization_decision_preview(_Object) ->
    [].

identity_authorization_status(#{kind := certificate} = Object) ->
    case role_authorization_applicable(Object) of
        true ->
            [];
        false ->
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("IDENTITY AUTHORIZATION STATUS")},
                #p{body = ias_html:text(role_authorization_intro(Object))},
                key_value_table([
                    {"Status", role_authorization_status(Object)},
                    {"Reason", role_authorization_reason(Object)}
                ]),
                certificate_role_next_step(Object)
            ]}
    end;
identity_authorization_status(_Object) ->
    [].

role_authorization_status(Certificate) ->
    case {ias_certificate_detail:certificate_class(Certificate), issued_certificate_id(Certificate)} of
        {<<"Enrollment Certificate">>, not_found} -> <<"ready for issuance">>;
        {<<"Enrollment Certificate">>, _IssuedCertificateId} -> <<"already issued">>;
        {<<"Imported OVPN Certificate">>, _} -> <<"imported artifact">>;
        _ -> <<"not applicable">>
    end.

authorization_matrix_preview(#{kind := certificate} = Object) ->
    case role_authorization_applicable(Object) of
        true ->
            CertificateId = maps:get(id, Object, undefined),
            Decisions = [ias_authorization_decision:certificate_decision(CertificateId, Action)
                         || Action <- certificate_authorization_actions()],
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("ROLE AUTHORIZATION MATRIX")},
                #p{body = ias_html:text("Checks which administrative actions are allowed by the certificate role or security profile.")},
                authorization_matrix_table(Decisions)
            ]};
        false ->
            []
    end;
authorization_matrix_preview(_Object) ->
    [].


role_authorization_applicable(#{kind := certificate} = Certificate) ->
    case maps:get(profile_id, Certificate, undefined) of
        administrator -> true;
        <<"administrator">> -> true;
        default_user -> true;
        <<"default_user">> -> true;
        _ ->
            case maps:get(profile, Certificate, undefined) of
                administrator -> true;
                <<"administrator">> -> true;
                default_user -> true;
                <<"default_user">> -> true;
                _ -> false
            end
    end;
role_authorization_applicable(_) ->
    false.

certificate_role_authorization_not_applicable(Title, Certificate) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text(Title)},
        #p{body = ias_html:text(role_authorization_intro(Certificate))},
        key_value_table([
            {"Status", <<"not applicable">>},
            {"Reason", role_authorization_reason(Certificate)}
        ]),
        certificate_role_next_step(Certificate)
    ]}.

role_authorization_intro(Certificate) ->
    case {ias_certificate_detail:certificate_class(Certificate), issued_certificate_id(Certificate)} of
        {<<"Enrollment Certificate">>, not_found} ->
            <<"This CA/CMP enrollment certificate is not an IAM identity certificate yet.">>;
        {<<"Enrollment Certificate">>, _IssuedCertificateId} ->
            <<"This CA/CMP enrollment certificate has already produced an issued identity certificate.">>;
        {<<"Imported OVPN Certificate">>, _} ->
            <<"Imported OVPN certificates are migration artifacts; role authorization is evaluated on issued identity certificates.">>;
        _ ->
            <<"Not applicable for this certificate yet.">>
    end.

role_authorization_reason(Certificate) ->
    case {ias_certificate_detail:certificate_class(Certificate), issued_certificate_id(Certificate)} of
        {<<"Enrollment Certificate">>, not_found} ->
            <<"enrollment certificate has no IAM role context; issue it to a user/security profile first">>;
        {<<"Enrollment Certificate">>, _IssuedCertificateId} ->
            <<"role authorization applies to the issued identity certificate, not to the enrollment artifact">>;
        {<<"Imported OVPN Certificate">>, _} ->
            <<"imported OVPN artifact has no IAS user/security profile role context">>;
        _ ->
            <<"this certificate only has a crypto/key profile and has not been issued to a user/security profile">>
    end.

certificate_role_next_step(Certificate) ->
    case {ias_certificate_detail:certificate_class(Certificate), issued_certificate_id(Certificate)} of
        {<<"Enrollment Certificate">>, not_found} ->
            enrollment_issue_next_step();
        {<<"Enrollment Certificate">>, IssuedCertificateId} ->
            already_issued_next_step(IssuedCertificateId);
        {<<"Imported OVPN Certificate">>, _} ->
            imported_certificate_next_step();
        _ ->
            []
    end.

enrollment_issue_next_step() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("NEXT STEP")},
        #p{body = ias_html:text("This CA/CMP enrollment certificate is cryptographically valid, but it has no IAM role context yet.")},
        #ul{body = [
            #li{body = ias_html:text("Issue this certificate to a user.")},
            #li{body = ias_html:text("Select the user's security profile during issuance.")},
            #li{body = ias_html:text("Open the issued certificate to evaluate role authorization and operation enforcement.")}
        ]},
        #link{url = <<"/app/issue.htm">>,
              style = <<"display:inline-block;margin-top:8px;padding:7px 10px;border:1px solid #93c5fd;border-radius:5px;background:#ffffff;color:#1d4ed8;text-decoration:none;font-size:12px;font-weight:600;">>,
              body = ias_html:text("Issue to User")}
    ]}.

already_issued_next_step(IssuedCertificateId) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("ALREADY ISSUED")},
        #p{body = ias_html:text("This enrollment certificate has already been converted into an IAS issued identity certificate.")},
        key_value_table([
            {"Issued Certificate", certificate_ref(IssuedCertificateId)},
            {"Next Step", <<"open the issued certificate to evaluate IAM role authorization">>}
        ])
    ]}.

imported_certificate_next_step() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("IMPORTED OVPN ARTIFACT")},
        #p{body = ias_html:text("This certificate came from an imported OpenVPN profile. Use it for migration, onboarding, endpoint discovery, or OVPN provisioning preview; issue a CA/CMP certificate to a user for IAS role authorization.")}
    ]}.

certificate_authorization_actions() ->
    [use_ias, issue_certificate, revoke_certificate].

authorization_matrix_table(Decisions) ->
    Header = #tr{cells = [
        #th{body = ias_html:text("Action")},
        #th{body = ias_html:text("Decision")},
        #th{body = ias_html:text("Reasons")}
    ]},
    Rows = [authorization_matrix_row(Decision) || Decision <- Decisions],
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [Header | Rows]}}
    ]}.

authorization_matrix_row(Decision) ->
    #tr{cells = [
        #td{body = ias_html:text(maps:get(action, Decision, undefined))},
        #td{body = ias_html:text(maps:get(decision, Decision, deny))},
        #td{body = decision_reasons(maps:get(reasons, Decision, []))}
    ]}.

authorization_decision_card(Action, Decision) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("ACTION AUTHORIZATION PREVIEW")},
        #p{body = ias_html:text("Checks whether this subject may perform the selected action.")},
        key_value_table([
            {"Action", Action},
            {"Decision", maps:get(decision, Decision, deny)},
            {"Reasons", decision_reasons(maps:get(reasons, Decision, []))}
        ])
    ]}.

decision_reasons([]) ->
    <<"none">>;
decision_reasons(Reasons) ->
    #panel{body = [
        #ul{body = [#li{body = ias_html:text(Reason)}
                    || Reason <- Reasons]}
    ]}.

authorization_enforcement_preview(#{kind := device} = Object) ->
    Enforcement = ias_authorization_enforcement:device_enforcement(
                    maps:get(id, Object, undefined)),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("OPERATION ENFORCEMENT PREVIEW")},
        #p{body = ias_html:text("Maps authorization decisions to operation-level allow or deny outcomes.")},
        key_value_table([
            {"Operation", maps:get(operation, Enforcement, undefined)},
            {"Result", maps:get(result, Enforcement, deny)},
            {"Reason", maps:get(reason, Enforcement, undefined)}
        ])
    ]};
authorization_enforcement_preview(#{kind := certificate} = Object) ->
    case role_authorization_applicable(Object) of
        true ->
            Enforcements = ias_authorization_enforcement:certificate_enforcement(
                             maps:get(id, Object, undefined)),
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("OPERATION ENFORCEMENT PREVIEW")},
                #p{body = ias_html:text("Maps authorization decisions to operation-level allow or deny outcomes.")},
                enforcement_table(Enforcements)
            ]};
        false ->
            []
    end;
authorization_enforcement_preview(_Object) ->
    [].

enforcement_table(Enforcements) ->
    Header = #tr{cells = [
        #th{body = ias_html:text("Operation")},
        #th{body = ias_html:text("Result")},
        #th{body = ias_html:text("Reason")}
    ]},
    Rows = [enforcement_row(Enforcement) || Enforcement <- Enforcements],
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [Header | Rows]}}
    ]}.

enforcement_row(Enforcement) ->
    #tr{cells = [
        #td{body = ias_html:text(maps:get(operation, Enforcement, undefined))},
        #td{body = ias_html:text(maps:get(result, Enforcement, deny))},
        #td{body = ias_html:text(maps:get(reason, Enforcement, undefined))}
    ]}.

ovpn_export_preview(#{kind := device} = Object) ->
    ObjectId = maps:get(id, Object, undefined),
    Preview = ias_ovpn_export:device_preview(ObjectId),
    ovpn_export_card(Preview, device, ObjectId);
ovpn_export_preview(#{kind := certificate} = Object) ->
    ObjectId = maps:get(id, Object, undefined),
    Preview = ias_ovpn_export:certificate_preview(ObjectId),
    ovpn_export_card(Preview, certificate, ObjectId);
ovpn_export_preview(#{kind := vpn_service} = Object) ->
    ObjectId = maps:get(id, Object, undefined),
    Preview = ias_ovpn_export:service_preview(ObjectId),
    ovpn_service_export_card(Preview);
ovpn_export_preview(_Object) ->
    [].

ovpn_export_card(Preview, SubjectKind, SubjectId) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("OVPN EXPORT PREVIEW")},
        key_value_table([
            {"OVPN Provisioning", maps:get(authorization, Preview, deny)},
            {"Provisioning Status", ovpn_provisioning_status(Preview)},
            {"Reason", ovpn_authorization_reason(Preview)},
            {"Remote Endpoint", ovpn_remote_endpoint(Preview)}
        ]),
        #h3{body = ias_html:text("Export Readiness")},
        key_value_table([
            {"VPN Endpoint", ovpn_endpoint_status(Preview)},
            {"CA Certificate", maps:get(ca_certificate_status, Preview, missing)},
            {"Certificate", maps:get(certificate_status, Preview, unknown)},
            {"Export Artifact", case maps:get(authorization, Preview, deny) of allow -> <<"available">>; _ -> <<"unavailable">> end}
        ]),
        #h3{body = ias_html:text("Profile Components")},
        ovpn_components_table(Preview),
        ovpn_configuration_section(Preview, SubjectKind, SubjectId),
        #panel{id = ovpn_export_result_id(SubjectKind, SubjectId)}
    ]}.


ovpn_service_export_card(Preview) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("OVPN EXPORT READINESS")},
        #p{body = ias_html:text("Shows whether this VPN service has enough provisioning metadata to be used as an OVPN export source.")},
        key_value_table([
            {"Export Status", ovpn_provisioning_status(Preview)},
            {"Reason", ovpn_authorization_reason(Preview)},
            {"Remote Endpoint", ovpn_remote_endpoint(Preview)}
        ]),
        #h3{body = ias_html:text("Export Readiness")},
        key_value_table([
            {"VPN Endpoint", ovpn_endpoint_status(Preview)},
            {"CA Certificate", maps:get(ca_certificate_status, Preview, missing)},
            {"Client Certificate", <<"selected during user/device provisioning">>},
            {"Export Artifact", service_export_artifact_status(Preview)}
        ]),
        #h3{body = ias_html:text("Profile Components")},
        ovpn_components_table(Preview)
    ]}.

service_export_artifact_status(#{authorization := allow}) ->
    <<"available after certificate selection">>;
service_export_artifact_status(_Preview) ->
    <<"unavailable">>.

ovpn_provisioning_status(#{authorization := allow}) ->
    <<"ready for export preview">>;
ovpn_provisioning_status(_Preview) ->
    <<"blocked">>.

ovpn_authorization_reason(#{authorization := allow} = Preview) ->
    maps:get(authorization_reason, Preview, <<"OVPN provisioning is allowed">>);
ovpn_authorization_reason(Preview) ->
    maps:get(authorization_reason, Preview, <<"authorization denied">>).

ovpn_remote_endpoint(Preview) ->
    Host = maps:get(remote_host, Preview, <<"not found">>),
    Port = maps:get(remote_port, Preview, <<"not found">>),
    ias_html:join([ias_html:text(Host), <<":">>, ias_html:text(Port)]).

ovpn_components_table(Preview) ->
    Header = #tr{cells = [
        #th{body = ias_html:text("Component")},
        #th{body = ias_html:text("Status")},
        #th{body = ias_html:text("Notes")}
    ]},
    Rows = [ovpn_component_row(Component, Status, Notes)
            || {Component, Status, Notes} <- ovpn_components(Preview)],
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [Header | Rows]}}
    ]}.

ovpn_components(Preview) ->
    [
        {"OVPN Provisioning", maps:get(authorization, Preview, deny),
         ovpn_authorization_reason(Preview)},
        {"VPN Endpoint", ovpn_endpoint_status(Preview),
         ovpn_remote_endpoint(Preview)},
        {"CA Certificate", maps:get(ca_certificate_status, Preview, missing),
         ovpn_ca_certificate_note(Preview)},
        {"Certificate", maps:get(certificate_status, Preview, unknown),
         ovpn_certificate_note(Preview)},
        {"Private Key", <<"device-owned">>,
         <<"not exported by IAS">>},
        {"Device Lock", maps:get(device_lock, Preview, disabled),
         ovpn_device_lock_note(Preview)},
        {"2FA", maps:get(two_factor, Preview, optional),
         ovpn_two_factor_note(Preview)}
    ].

ovpn_component_row(Component, Status, Notes) ->
    #tr{cells = [
        #td{body = ias_html:text(Component)},
        #td{body = ias_html:text(Status)},
        #td{body = ias_html:text(Notes)}
    ]}.

ovpn_endpoint_status(Preview) ->
    case {maps:get(remote_host, Preview, <<"not found">>),
          maps:get(remote_port, Preview, <<"not found">>)} of
        {<<"not found">>, _} -> missing;
        {_, <<"not found">>} -> missing;
        _ -> available
    end.

ovpn_ca_certificate_note(Preview) ->
    case maps:get(ca_certificate_id, Preview, not_found) of
        not_found ->
            <<"not linked to VPN service yet">>;
        CertificateId ->
            ias_html:join([<<"trust anchor: Certificate #">>, ias_html:text(CertificateId)])
    end.

ovpn_certificate_note(Preview) ->
    ias_html:join([<<"certificate status: ">>,
                   ias_html:text(maps:get(certificate_status, Preview, unknown))]).

ovpn_device_lock_note(#{device_lock := enabled}) ->
    <<"device binding is required by profile">>;
ovpn_device_lock_note(_Preview) ->
    <<"user may select device">>.

ovpn_two_factor_note(#{two_factor := required}) ->
    <<"VPN login requires 2FA">>;
ovpn_two_factor_note(#{two_factor := optional}) ->
    <<"2FA is optional">>;
ovpn_two_factor_note(_Preview) ->
    <<"2FA is disabled">>.

ovpn_configuration_section(#{authorization := allow} = Preview, SubjectKind, SubjectId) ->
    #panel{body = [
        #h3{body = ias_html:text("Configuration Skeleton")},
        ovpn_profile_block(maps:get(preview, Preview, <<>>)),
        #panel{style = <<"margin-top:12px;">>, body = [
            #link{class = [button, sgreen],
                  body = ias_html:text("Download Demo OVPN"),
                  postback = {download_ovpn_artifact, SubjectKind, SubjectId}}
        ]}
    ]};
ovpn_configuration_section(Preview, _SubjectKind, _SubjectId) ->
    #panel{body = [
        #h3{body = ias_html:text("Profile Generation Blocked")},
        #p{style = <<"color:#b45309;font-weight:600;">>,
           body = ias_html:text("OVPN profile would not be provisioned because OVPN provisioning is denied.")},
        key_value_table([
            {"Blocking Reason", ovpn_authorization_reason(Preview)}
        ])
    ]}.

ovpn_profile_block(Profile) ->
    #panel{style = <<"white-space:pre-wrap;font-family:monospace;font-size:12px;",
                     "background:#0f172a;color:#e5e7eb;padding:12px;border-radius:6px;",
                     "max-width:640px;overflow:auto;">>,
           body = ias_html:text(Profile)}.

download_ovpn_artifact({ok, Filename, Content}) ->
    nitro:update(ovpn_export_result, ovpn_artifact_ready(Filename, Content)),
    nitro:wire(ovpn_download_js(Filename, Content));
download_ovpn_artifact({error, Reason}) ->
    nitro:update(ovpn_export_result, ovpn_artifact_error(Reason)).

ovpn_artifact_ready(Filename, Content) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Demo OVPN artifact ready")},
               key_value_table([
                   {"Filename", Filename},
                   {"Bytes", byte_size(Content)}
               ])
           ]}.

ovpn_artifact_error(Reason) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("Demo OVPN artifact unavailable")},
               key_value_table([
                   {"Reason", Reason}
               ])
           ]}.

ovpn_export_result_id(_SubjectKind, _SubjectId) ->
    ovpn_export_result.

ovpn_download_js(Filename, Content) ->
    Encoded = base64:encode(Content),
    SafeFilename = js_string(Filename),
    [
        <<"var data=atob('">>, Encoded, <<"');">>,
        <<"var blob=new Blob([data],{type:'application/x-openvpn-profile'});">>,
        <<"var url=URL.createObjectURL(blob);">>,
        <<"var a=document.createElement('a');">>,
        <<"a.href=url;">>,
        <<"a.download='">>, SafeFilename, <<"';">>,
        <<"document.body.appendChild(a);">>,
        <<"a.click();">>,
        <<"document.body.removeChild(a);">>,
        <<"URL.revokeObjectURL(url);">>
    ].

js_string(Value) ->
    Text = ias_html:text(Value),
    << <<(js_string_char(Char))/binary>> || <<Char>> <= Text >>.

js_string_char($\\) -> <<"\\\\">>;
js_string_char($') -> <<"\\'">>;
js_string_char($\n) -> <<"\\n">>;
js_string_char($\r) -> <<"\\r">>;
js_string_char(Char) -> <<Char>>.

device_readiness(Device) ->
    DeviceId = maps:get(id, Device, undefined),
    case [Readiness || Readiness <- maps:get(all, ias_graph_analysis:devices_operational_readiness(), []),
                       maps:get(device_id, Readiness, undefined) =:= DeviceId] of
        [Readiness | _] -> Readiness;
        [] -> #{status => incomplete,
                vpn_service_id => not_found,
                security_policy_id => not_found,
                current_certificate_id => not_found,
                certificate_verification => not_verified,
                certificate_revocation => active,
                suggested_actions => []}
    end.

object_or_not_linked(_Kind, not_found) ->
    <<"not linked yet">>;
object_or_not_linked(Kind, Id) ->
    object_ref(Kind, Id).

readiness_text(Value) ->
    ias_html:text(Value).

readiness_status_text(ready) ->
    <<"READY">>;
readiness_status_text(incomplete) ->
    <<"INCOMPLETE">>;
readiness_status_text(Value) ->
    ias_html:text(Value).

suggested_actions_panel(#{suggested_actions := []}) ->
    #panel{body = []};
suggested_actions_panel(Readiness) ->
    Actions = maps:get(suggested_actions, Readiness, []),
    #panel{body = [
        #h3{body = ias_html:text("Suggested Actions")},
        #ul{body = [#li{body = readiness_action_body(Action, Readiness)}
                    || Action <- Actions]}
    ]}.

readiness_action_body(Action, Readiness) ->
    Target = readiness_action_target(Action, Readiness),
    [ias_html:text(Action), ias_html:text(" "), readiness_action_link(Target)].

readiness_action_target(<<"Link Certificate Security Policy">>, Readiness) ->
    {certificate, maps:get(current_certificate_id, Readiness, not_found),
     <<"Open Current Certificate">>};
readiness_action_target(<<"Verify Current Certificate">>, Readiness) ->
    {certificate, maps:get(current_certificate_id, Readiness, not_found),
     <<"Open Current Certificate">>};
readiness_action_target(<<"Replace Certificate">>, Readiness) ->
    {device, maps:get(device_id, Readiness, not_found), <<"Open Device">>};
readiness_action_target(<<"Link New Certificate">>, Readiness) ->
    {device, maps:get(device_id, Readiness, not_found), <<"Open Device">>};
readiness_action_target(_Action, Readiness) ->
    {device, maps:get(device_id, Readiness, not_found), <<"Open Device">>}.

readiness_action_link({_Kind, not_found, Label}) ->
    #span{style = <<"color:#6b7280;font-size:12px;">>, body = ias_html:text(Label)};
readiness_action_link({Kind, Id, Label}) ->
    #link{class = [button, sgreen],
          url = object_url(Kind, Id),
          body = ias_html:text(Label)}.

object_url(device, Id) ->
    ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]);
object_url(certificate, Id) ->
    ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]);
object_url(_Kind, Id) ->
    ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]).

security_profile_preview(#{kind := device} = Object) ->
    security_profile_card("APPLIED SECURITY PROFILE", Object);
security_profile_preview(#{kind := certificate} = Object) ->
    security_profile_card("SECURITY PROFILE", Object);
security_profile_preview(#{kind := vpn_service} = Object) ->
    security_profile_card("SERVICE SECURITY PROFILE", Object);
security_profile_preview(#{kind := security_policy} = Object) ->
    security_policy_effects_card(Object);
security_profile_preview(_Object) ->
    [].

security_profile_card(Title, Object) ->
    Policy = security_profile_policy(Object),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text(Title)},
        key_value_table(security_profile_rows(Policy)),
        security_policy_effects_table(Policy)
    ]}.

security_profile_policy(#{kind := certificate} = Object) ->
    ias_certificate_detail:security_policy(Object);
security_profile_policy(Object) ->
    ias_security_profile:applied_policy(Object).

security_policy_effects_card(Policy) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Security Profile Preview")},
        key_value_table(security_profile_rows(Policy)),
        security_policy_effects_table(Policy)
    ]}.

security_profile_rows(Policy) ->
    [
        {"Profile", ias_security_profile:profile_label(Policy)},
        {"Device Lock", ias_security_profile:device_lock_label(Policy)},
        {"2FA", ias_security_profile:two_factor_label(Policy)},
        {"Enforcement", ias_security_profile:enforcement_label(Policy)}
    ].

security_policy_effects_table(Policy) ->
    key_value_table([
        {"Policy Effects", #panel{body = effect_lines(ias_security_profile:effects(Policy), [])}}
    ]).

effect_lines([], Acc) ->
    lists:reverse(Acc);
effect_lines([Effect | Rest], []) ->
    effect_lines(Rest, [ias_html:text(Effect)]);
effect_lines([Effect | Rest], Acc) ->
    effect_lines(Rest, [ias_html:text(Effect), #br{} | Acc]).

not_linked(not_linked) ->
    <<"not linked yet">>;
not_linked(Value) ->
    Value.

candidate_table(Groups, EmptyLabel) ->
    Header = #tr{cells = [
        #th{body = ias_html:text("Type")},
        #th{body = ias_html:text("Object")},
        #th{body = ias_html:text("Action")}
    ]},
    Rows = candidate_rows(Groups, EmptyLabel),
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [Header | Rows]}}
    ]}.

candidate_rows(Groups, EmptyLabel) ->
    Rows = [candidate_row(Type, Candidate, RelationType, SourceId)
            || {Type, Candidates, RelationType, SourceId} <- Groups,
               Candidate <- Candidates],
    case Rows of
        [] -> [#tr{cells = [#td{body = ias_html:text(EmptyLabel), colspan = 3}]}];
        _ -> Rows
    end.

candidate_row(Type, Candidate, RelationType, SourceId) ->
    #tr{cells = [
        #td{style = <<"width:24%;">>, body = ias_html:text(Type)},
        #td{style = <<"word-break:break-all;white-space:normal;">>,
            body = candidate_body(Candidate, RelationType, SourceId)},
        #td{style = <<"width:90px;white-space:nowrap;">>,
            body = candidate_action(Candidate, RelationType, SourceId)}
    ]}.

candidate_action(Candidate, RelationType, SourceId) ->
    TargetId = maps:get(id, Candidate, undefined),
    case ias_relationship_link:status(RelationType, SourceId, TargetId) of
        link ->
            #link{class = [button, sgreen],
                  body = ias_html:text("Link"),
                  postback = {link_relationship, RelationType, SourceId, TargetId}};
        {linked, _Relationship} ->
            linked_action(_Relationship);
        {already_has_policy, PolicyId, _Relationship} ->
            ias_html:join([<<"Already has policy: ">>, ias_html:text(PolicyId)]);
        _ ->
            ias_html:text("not found")
    end.

candidate_link(Candidate) ->
    Id = maps:get(id, Candidate, undefined),
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
          body = ias_html:join([candidate_label(Candidate), <<" #">>, TextId,
                                <<" (score ">>, maps:get(relationship_score, Candidate, 0),
                                <<")">>])}.

candidate_body(Candidate, RelationType, SourceId) ->
    case candidate_policy_warning(Candidate, RelationType, SourceId) of
        [] ->
            candidate_link(Candidate);
        Warning ->
            #panel{body = [candidate_link(Candidate), #br{} | Warning]}
    end.

candidate_policy_warning(#{kind := certificate} = Candidate, uses_certificate, SourceId) ->
    case ias_demo_store:get(SourceId) of
        {ok, #{kind := device}} ->
            Consistency = ias_policy_consistency:evaluate_policy_consistency(
                SourceId, maps:get(id, Candidate, undefined)),
            case maps:get(match, Consistency, false) of
                true -> [];
                false -> policy_mismatch_lines(Consistency)
            end;
        _ ->
            []
    end;
candidate_policy_warning(_Candidate, _RelationType, _SourceId) ->
    [].

policy_mismatch_lines(#{reason := <<"no policy available">>}) ->
    [];
policy_mismatch_lines(Consistency) ->
    [#span{style = <<"color:#b45309;font-size:12px;">>,
           body = ias_html:text("Policy mismatch:")},
     #br{},
     #span{style = <<"color:#b45309;font-size:12px;">>,
           body = ias_html:join([<<"device=">>,
                                 policy_value(maps:get(device_policy, Consistency, not_found)),
                                 <<" certificate=">>,
                                 policy_value(maps:get(certificate_policy, Consistency, not_found))])}].

candidate_label(#{kind := certificate}) ->
    <<"Certificate">>;
candidate_label(#{kind := vpn_service}) ->
    <<"VPN Service">>;
candidate_label(#{kind := device}) ->
    <<"Device">>;
candidate_label(#{kind := security_policy}) ->
    <<"Security Policy">>;
candidate_label(_Object) ->
    <<"Demo Object">>.

linked_action(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            #panel{body = [
                ias_html:text("Linked "),
                ias_relationship_ui:action(Relationship)
            ]};
        false ->
            ias_html:text("Linked")
    end.

relationship_detail_action(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            ias_relationship_ui:action(Relationship);
        false ->
            ias_html:text("Protected lifecycle relationship")
    end.

relationships_table(Object) ->
    Relationships = ias_relationship_link:relationships_for(Object),
    #panel{body = [
        #h3{body = ias_html:text("Relationships")},
        relationship_rows(Object, Relationships)
    ]}.

relationship_rows(#{kind := device}, Relationships) ->
    key_value_table([
        {"Certificate", linked_targets(uses_certificate, Relationships)},
        {"VPN Service", linked_targets(uses_service, Relationships)},
        {"Security Policy", linked_targets(uses_security_policy, Relationships)}
    ]);
relationship_rows(#{kind := certificate}, Relationships) ->
    key_value_table([
        {"Issued From", linked_sources(issues, Relationships)},
        {"Issued Certificate", linked_targets(issues, Relationships)},
        {"Verification History", linked_targets(verified_by, Relationships)},
        {"Revocation Record", linked_targets(revoked_by, Relationships)},
        {"Used By Device", linked_sources(uses_certificate, Relationships)},
        {"Used As CA By", linked_sources(uses_ca_certificate, Relationships)},
        {"Security Policy", linked_targets(uses_security_policy, Relationships)}
    ]);
relationship_rows(#{kind := vpn_service}, Relationships) ->
    key_value_table([
        {"Used By Device", linked_sources(uses_service, Relationships)},
        {"CA Certificate", linked_targets(uses_ca_certificate, Relationships)},
        {"Security Policy", linked_targets(uses_security_policy, Relationships)}
    ]);
relationship_rows(#{kind := security_policy}, Relationships) ->
    key_value_table([
        {"Applied To", linked_sources(uses_security_policy, Relationships)}
    ]);
relationship_rows(#{kind := verification}, Relationships) ->
    key_value_table([
        {"Certificate", linked_sources(verified_by, Relationships)},
        {"Security Policy", linked_targets(uses_security_policy, Relationships)}
    ]);
relationship_rows(#{kind := cmp_enrollment_result}, Relationships) ->
    key_value_table([
        {"Issued Certificate", linked_targets(issues, Relationships)}
    ]);
relationship_rows(#{kind := certificate_replacement}, Relationships) ->
    key_value_table([
        {"Device", linked_sources(replaced_certificate_by, Relationships)},
        {"Old Certificate", linked_targets(old_certificate, Relationships)},
        {"New Certificate", linked_targets(new_certificate, Relationships)}
    ]);
relationship_rows(#{kind := certificate_revocation}, Relationships) ->
    key_value_table([
        {"Certificate", linked_sources(revoked_by, Relationships)}
    ]);
relationship_rows(_Object, _Relationships) ->
    [].

linked_targets(RelationType, Relationships) ->
    Entries = [relationship_entry(target, Relationship)
               || Relationship <- Relationships,
                  maps:get(relation_type, Relationship, undefined) =:= RelationType],
    links_or_not_found(Entries).

linked_sources(RelationType, Relationships) ->
    Entries = [relationship_entry(source, Relationship)
               || Relationship <- Relationships,
                  maps:get(relation_type, Relationship, undefined) =:= RelationType],
    links_or_not_found(Entries).

relationship_entry(target, Relationship) ->
    relationship_entry(maps:get(target_kind, Relationship, undefined),
                       maps:get(target_id, Relationship, undefined),
                       Relationship);
relationship_entry(source, Relationship) ->
    relationship_entry(maps:get(source_kind, Relationship, undefined),
                       maps:get(source_id, Relationship, undefined),
                       Relationship).

relationship_entry(Kind, Id, Relationship) ->
    ias_relationship_ui:object_entry(Kind, Id, Relationship).

links_or_not_found([]) ->
    <<"not linked yet">>;
links_or_not_found(Links) ->
    #panel{body = join_links(Links, [])}.

join_links([], Acc) ->
    lists:reverse(Acc);
join_links([Link | Rest], []) ->
    join_links(Rest, [Link]);
join_links([Link | Rest], Acc) ->
    join_links(Rest, [Link, #br{} | Acc]).

object_ref(_Kind, undefined) ->
    <<"not found">>;
object_ref(user, Id) ->
    TextId = ias_html:text(Id),
    case ias_demo_store:get(Id) of
        {ok, #{kind := user}} ->
            #link{url = ias_html:join([<<"/app/user.htm?id=">>, TextId]),
                  body = ias_html:join([object_label(user), <<" #">>, TextId])};
        _ ->
            <<"not found">>
    end;
object_ref(security_profile, Id) ->
    TextId = ias_html:text(Id),
    case ias_demo_store:get(Id) of
        {ok, #{kind := security_profile}} ->
            #link{url = ias_html:join([<<"/app/profile.htm?id=">>, TextId]),
                  body = ias_html:join([object_label(security_profile), <<" #">>, TextId])};
        _ ->
            <<"not found">>
    end;
object_ref(Kind, Id) ->
    TextId = ias_html:text(Id),
    case ias_demo_store:get(Id) of
        {ok, #{kind := Kind}} ->
            #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
                  body = ias_html:join([object_label(Kind), <<" #">>, TextId])};
        _ ->
            <<"not found">>
    end.

object_label(device) ->
    <<"Device">>;
object_label(user) ->
    <<"User">>;
object_label(certificate) ->
    <<"Certificate">>;
object_label(vpn_service) ->
    <<"VPN Service">>;
object_label(security_profile) ->
    <<"Security Profile">>;
object_label(security_policy) ->
    <<"Security Policy">>;
object_label(relationship) ->
    <<"Relationship">>;
object_label(verification) ->
    <<"Verification">>;
object_label(cmp_enrollment_result) ->
    <<"Certificate Enrollment">>;
object_label(certificate_replacement) ->
    <<"Certificate Replacement">>;
object_label(certificate_revocation) ->
    <<"Certificate Revocation">>;
object_label(Kind) ->
    ias_html:text(Kind).

certificate_ref(not_found) ->
    <<"not linked yet">>;
certificate_ref(undefined) ->
    <<"not linked yet">>;
certificate_ref(#{id := Id}) ->
    object_ref(certificate, Id);
certificate_ref(Id) when is_binary(Id); is_list(Id) ->
    object_ref(certificate, Id);
certificate_ref(_) ->
    <<"not found">>.

device_ref(not_found) ->
    <<"not linked yet">>;
device_ref(Device) ->
    object_ref(device, maps:get(id, Device, undefined)).

verification_history(Certificate) ->
    Links = [object_ref(verification, maps:get(id, Verification, undefined))
             || Verification <- ias_certificate_verification:verification_history(Certificate)],
    links_or_not_found(Links).

revocation_status(Certificate) ->
    case ias_certificate_revocation:revocation_for_certificate(Certificate) of
        not_found ->
            <<"active">>;
        _Revocation ->
            <<"revoked">>
    end.

revocation_record(Certificate) ->
    case ias_certificate_revocation:revocation_for_certificate(Certificate) of
        not_found -> <<"not linked yet">>;
        Revocation -> object_ref(certificate_revocation, maps:get(id, Revocation, undefined))
    end.

revocation_action(Certificate) ->
    case ias_certificate_revocation:revocation_for_certificate(Certificate) of
        not_found ->
            #link{class = [button, sgreen],
                  body = ias_html:text("Revoke"),
                  postback = {revoke_certificate, maps:get(id, Certificate, undefined)}};
        _Revocation ->
            <<"not available">>
    end.

user_ref(undefined) ->
    <<"not linked yet">>;
user_ref(UserId) ->
    TextId = ias_html:text(UserId),
    case ias_demo_store:get(UserId) of
        {ok, #{kind := user}} ->
            #link{url = ias_html:join([<<"/app/user.htm?id=">>, TextId]),
                  body = TextId};
        _ ->
            <<"not found">>
    end.

profile_ref(undefined) ->
    <<"not linked yet">>;
profile_ref(ProfileId) ->
    TextId = ias_html:text(ProfileId),
    case ias_demo_store:get(ProfileId) of
        {ok, #{kind := security_profile}} ->
            #link{url = ias_html:join([<<"/app/profile.htm?id=">>, TextId]),
                  body = TextId};
        _ ->
            <<"not found">>
    end.

policy_ref(undefined) ->
    <<"not linked yet">>;
policy_ref(PolicyId) ->
    object_ref(security_policy, PolicyId).

transition_certificate(_Origin, not_found) ->
    <<"not linked yet">>;
transition_certificate(Origin, Certificate) ->
    Id = ias_html:text(maps:get(id, Certificate, undefined)),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, Id]),
          body = ias_html:join([transition_origin(Origin), <<" #">>, Id])}.

transition_origin(imported) ->
    <<"Imported Certificate">>;
transition_origin(issued) ->
    <<"Issued Certificate">>;
transition_origin(Origin) ->
    ias_html:text(Origin).

replacement_action(Device) ->
    DeviceId = maps:get(id, Device, undefined),
    case ias_certificate_replacement:action_state(Device) of
        replace ->
            #link{class = [button, sgreen],
                  body = ias_html:text("Replace"),
                  postback = {replace_certificate, DeviceId}};
        {blocked, Reason} ->
            ias_html:join([<<"Replacement blocked: ">>, Reason]);
        not_available ->
            <<"not available">>
    end.

replacement_history_table(Device) ->
    DeviceId = maps:get(id, Device, undefined),
    History = ias_certificate_replacement:history_for_device(DeviceId),
    case History of
        [] ->
            [];
        _ ->
            [
                #h3{body = ias_html:text("Replacement History")},
                key_value_table([
                    {"Replacements", links_or_not_found(
                        [object_ref(certificate_replacement, maps:get(id, Replacement, undefined))
                         || Replacement <- History])}
                ])
            ]
    end.

lifecycle_text(replacement_available) ->
    <<"replacement available">>;
lifecycle_text(current_only) ->
    <<"current only">>;
lifecycle_text(candidate_available) ->
    <<"candidate available">>;
lifecycle_text(no_certificate_available) ->
    <<"no certificate available">>;
lifecycle_text(no_certificate_context) ->
    <<"no certificate context">>;
lifecycle_text(imported) ->
    <<"imported">>;
lifecycle_text(issued) ->
    <<"issued">>;
lifecycle_text(current) ->
    <<"current">>;
lifecycle_text(candidate) ->
    <<"candidate">>;
lifecycle_text(unassigned) ->
    <<"unassigned">>;
lifecycle_text(Value) ->
    ias_html:text(Value).
