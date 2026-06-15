-module(ias_demo).
-export([event/1, relationship_rows/2]).
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
        {"Profile", maps:get(profile, Object, undefined)},
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
        {"Authorization Decision", maps:get(authorization_status, Object, undefined)},
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
        {"Profile", maps:get(profile, Object, undefined)},
        {"CMP Server", maps:get(cmp_server, Object, undefined)},
        {"Issued Certificate", certificate_ref(issued_certificate_id(Object))}
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
                    {"Used By Device", linked_sources(uses_certificate, Relationships)}
                ]),
                #h3{body = ias_html:text("Suggested Relationships")},
                candidate_table([
                    {"Suggested Devices", ias_relationship_preview:suggested_candidates(maps:get(suggested_devices, Preview, [])),
                     uses_certificate, SourceId}
                ], <<"no candidates">>),
                #h3{body = ias_html:text("Available Objects")},
                candidate_table([
                    {"Available Devices", ias_relationship_preview:available_candidates(maps:get(suggested_devices, Preview, [])),
                     uses_certificate, SourceId}
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
                    {"Used By Device", linked_sources(uses_service, Relationships)}
                ]),
                #h3{body = ias_html:text("Suggested Relationships")},
                candidate_table([
                    {"Suggested Devices", ias_relationship_preview:suggested_candidates(maps:get(suggested_devices, Preview, [])),
                     uses_service, SourceId}
                ], <<"no candidates">>),
                #h3{body = ias_html:text("Available Objects")},
                candidate_table([
                    {"Available Devices", ias_relationship_preview:available_candidates(maps:get(suggested_devices, Preview, [])),
                     uses_service, SourceId}
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
            {"Action", maps:get(action, Transition, <<"not available">>)}
        ])
    ]};
certificate_lifecycle_preview(#{kind := certificate} = Object) ->
    Role = ias_certificate_role:certificate_role(Object),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("CERTIFICATE ROLE")},
        key_value_table([
            {"Origin", lifecycle_text(maps:get(origin, Role, unknown))},
            {"Role", lifecycle_text(maps:get(role, Role, unassigned))},
            {"Used By Device", device_ref(maps:get(used_by_device, Role, not_found))},
            {"Verification History", verification_history(Object)}
        ])
    ]};
certificate_lifecycle_preview(_Object) ->
    [].

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
                  style = <<"display:inline-block;">>,
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
                unlink_link(maps:get(id, Relationship, undefined))
            ]};
        false ->
            ias_html:text("Linked")
    end.

relationship_detail_action(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            unlink_link(maps:get(id, Relationship, undefined));
        false ->
            ias_html:text("Protected lifecycle relationship")
    end.

unlink_link(RelationshipId) ->
    #link{class = [button],
          style = <<"display:inline-block;">>,
          body = ias_html:text("Unlink"),
          postback = {unlink_relationship, RelationshipId}}.

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
        {"Used By Device", linked_sources(uses_certificate, Relationships)},
        {"Security Policy", linked_targets(uses_security_policy, Relationships)}
    ]);
relationship_rows(#{kind := vpn_service}, Relationships) ->
    key_value_table([
        {"Used By Device", linked_sources(uses_service, Relationships)},
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
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            #panel{body = [
                object_ref(Kind, Id),
                ias_html:text(" "),
                unlink_link(maps:get(id, Relationship, undefined))
            ]};
        false ->
            object_ref(Kind, Id)
    end.

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
