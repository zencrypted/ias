-module(ias_demo).
-export([event/1]).
-include_lib("n2o/include/n2o.hrl").
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event({link_relationship, RelationType, SourceId, TargetId}) ->
    _ = ias_relationship_link:create(RelationType, SourceId, TargetId),
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
        relationship_preview(Object)
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
    common_rows(Object) ++ [
        {"Issued User", user_ref(maps:get(user, Object, undefined))},
        {"Source Security Profile", profile_ref(maps:get(profile_id, Object,
                                                         maps:get(profile, Object, undefined)))},
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
        {"Role", maps:get(role, Object, undefined)},
        {"Services", ias_html:join_csv(maps:get(services, Object, []))},
        {"Attributes", ias_html:join_csv(maps:get(attributes, Object, []))},
        {"Trust Level", maps:get(trust_level, Object, undefined)},
        {"Device Lock", maps:get(device_lock, Object, undefined)},
        {"2FA", maps:get(two_factor, Object, undefined)}
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
rows(#{kind := relationship} = Object) ->
    [
        {"Relationship ID", maps:get(relationship_id, Object, undefined)},
        {"Relationship Type", maps:get(relation_type, Object, undefined)},
        {"Source", object_ref(maps:get(source_kind, Object, undefined),
                              maps:get(source_id, Object, undefined))},
        {"Target", object_ref(maps:get(target_kind, Object, undefined),
                              maps:get(target_id, Object, undefined))},
        {"Score", maps:get(score, Object, 0)}
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
                ]),
                #h3{body = ias_html:text("Available Objects")},
                candidate_table([
                    {"Available Certificates", ias_relationship_preview:available_candidates(maps:get(suggested_certificates, Preview, [])),
                     uses_certificate, SourceId},
                    {"Available VPN Services", ias_relationship_preview:available_candidates(maps:get(suggested_services, Preview, [])),
                     uses_service, SourceId}
                ]),
                #h3{body = ias_html:text("Suggested Security Policies")},
                candidate_table([
                    {"Security Policy", maps:get(suggested_security_policies, Preview, []),
                     uses_security_policy, SourceId}
                ])
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
                ]),
                #h3{body = ias_html:text("Available Objects")},
                candidate_table([
                    {"Available Devices", ias_relationship_preview:available_candidates(maps:get(suggested_devices, Preview, [])),
                     uses_certificate, SourceId}
                ]),
                #h3{body = ias_html:text("Suggested Security Policies")},
                candidate_table([
                    {"Security Policy", maps:get(suggested_security_policies, Preview, []),
                     uses_security_policy, SourceId}
                ])
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
                ]),
                #h3{body = ias_html:text("Available Objects")},
                candidate_table([
                    {"Available Devices", ias_relationship_preview:available_candidates(maps:get(suggested_devices, Preview, [])),
                     uses_service, SourceId}
                ]),
                #h3{body = ias_html:text("Suggested Security Policies")},
                candidate_table([
                    {"Security Policy", maps:get(suggested_security_policies, Preview, []),
                    uses_security_policy, SourceId}
                ])
            ]};
        #{kind := security_policy} ->
            Relationships = ias_relationship_link:relationships_for(Object),
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("Relationship Preview")},
                relationships_table(Object),
                key_value_table([
                    {"Applied To", linked_sources(uses_security_policy, Relationships)}
                ])
            ]};
        _ ->
            []
    end.

certificate_lifecycle_preview(#{kind := device} = Object) ->
    Status = ias_certificate_role:device_status(Object),
    Transition = ias_certificate_role:replacement_preview(Object),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("CERTIFICATE STATUS")},
        key_value_table([
            {"Current Certificate", certificate_ref(maps:get(current_certificate, Status, not_found))},
            {"Candidate Certificate", certificate_ref(maps:get(candidate_certificate, Status, not_found))},
            {"State", lifecycle_text(maps:get(state, Status, undefined))}
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
            {"Used By Device", device_ref(maps:get(used_by_device, Role, not_found))}
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
    Policy = ias_security_profile:applied_policy(Object),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text(Title)},
        key_value_table(security_profile_rows(Policy)),
        security_policy_effects_table(Policy)
    ]}.

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

candidate_table(Groups) ->
    Header = #tr{cells = [
        #th{body = ias_html:text("Type")},
        #th{body = ias_html:text("Object")},
        #th{body = ias_html:text("Action")}
    ]},
    Rows = candidate_rows(Groups),
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [Header | Rows]}}
    ]}.

candidate_rows(Groups) ->
    Rows = [candidate_row(Type, Candidate, RelationType, SourceId)
            || {Type, Candidates, RelationType, SourceId} <- Groups,
               Candidate <- Candidates],
    case Rows of
        [] -> [#tr{cells = [#td{body = ias_html:text("not found"), colspan = 3}]}];
        _ -> Rows
    end.

candidate_row(Type, Candidate, RelationType, SourceId) ->
    #tr{cells = [
        #td{style = <<"width:24%;">>, body = ias_html:text(Type)},
        #td{style = <<"word-break:break-all;white-space:normal;">>,
            body = candidate_link(Candidate)},
        #td{style = <<"width:90px;white-space:nowrap;">>,
            body = candidate_action(Candidate, RelationType, SourceId)}
    ]}.

candidate_action(Candidate, RelationType, SourceId) ->
    TargetId = maps:get(id, Candidate, undefined),
    case ias_relationship_link:exists(RelationType, SourceId, TargetId) of
        not_found ->
            #link{class = [button, sgreen],
                  style = <<"display:inline-block;">>,
                  body = ias_html:text("Link"),
                  postback = {link_relationship, RelationType, SourceId, TargetId}};
        _Relationship ->
            ias_html:text("Linked")
    end.

candidate_link(Candidate) ->
    Id = maps:get(id, Candidate, undefined),
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
          body = ias_html:join([candidate_label(Candidate), <<" #">>, TextId,
                                <<" (score ">>, maps:get(relationship_score, Candidate, 0),
                                <<")">>])}.

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
relationship_rows(_Object, _Relationships) ->
    [].

linked_targets(RelationType, Relationships) ->
    Links = [object_ref(maps:get(target_kind, Relationship, undefined),
                        maps:get(target_id, Relationship, undefined))
             || Relationship <- Relationships,
                maps:get(relation_type, Relationship, undefined) =:= RelationType],
    links_or_not_found(Links).

linked_sources(RelationType, Relationships) ->
    Links = [object_ref(maps:get(source_kind, Relationship, undefined),
                        maps:get(source_id, Relationship, undefined))
             || Relationship <- Relationships,
                maps:get(relation_type, Relationship, undefined) =:= RelationType],
    links_or_not_found(Links).

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

object_ref(user, Id) ->
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/user.htm?id=">>, TextId]),
          body = ias_html:join([object_label(user), <<" #">>, TextId])};
object_ref(security_profile, Id) ->
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/profile.htm?id=">>, TextId]),
          body = ias_html:join([object_label(security_profile), <<" #">>, TextId])};
object_ref(Kind, Id) ->
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
          body = ias_html:join([object_label(Kind), <<" #">>, TextId])}.

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
object_label(Kind) ->
    ias_html:text(Kind).

certificate_ref(not_found) ->
    <<"not found">>;
certificate_ref(Certificate) ->
    object_ref(certificate, maps:get(id, Certificate, undefined)).

device_ref(not_found) ->
    <<"not found">>;
device_ref(Device) ->
    object_ref(device, maps:get(id, Device, undefined)).

user_ref(undefined) ->
    <<"not found">>;
user_ref(UserId) ->
    TextId = ias_html:text(UserId),
    #link{url = ias_html:join([<<"/app/user.htm?id=">>, TextId]),
          body = TextId}.

profile_ref(undefined) ->
    <<"not found">>;
profile_ref(ProfileId) ->
    TextId = ias_html:text(ProfileId),
    #link{url = ias_html:join([<<"/app/profile.htm?id=">>, TextId]),
          body = TextId}.

transition_certificate(_Origin, not_found) ->
    <<"not found">>;
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
