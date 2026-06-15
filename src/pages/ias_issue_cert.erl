-module(ias_issue_cert).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event({issue_cert_demo, UserId}) ->
    SubjectCN = field_value(nitro:q(issue_subject), <<"peer_new">>),
    SourceCertificateId = optional_field(nitro:q(issue_source_certificate)),
    Result = issue_certificate(UserId, SubjectCN, SourceCertificateId),
    nitro:update(issue_result_id(UserId), issue_result(Result));
event(_) ->
    ok.

content() ->
    Users = ias_demo_data:users(),
    Profiles = ias_demo_data:profiles(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Certificate Issuance Preview")},
        #p{body = ias_html:text("Preview the certificate claims that a future CA workflow would issue for a user's assigned Security Profile.")},
        selector(Users),
        previews(Users, Profiles)
    ]}.

selector(Users) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Issue Certificate")},
        #panel{body = [
            #span{body = ias_html:text("Subject CN: ")},
            #input{id = <<"issue_subject">>,
                   type = <<"text">>,
                   value = <<"peer_new">>,
                   onkeyup = update_subject_js(),
                   onchange = update_subject_js()}
        ]},
        #panel{body = [
            #span{body = ias_html:text("Enrollment Certificate: ")},
            #select{id = <<"issue_source_certificate">>,
                    body = source_certificate_options()}
        ]},
        #panel{body = [
            #span{body = ias_html:text("Selected User: ")},
            #select{id = <<"issue_user">>,
                    onchange = toggle_preview_js(),
                    body = [option(User) || User <- Users]}
        ]}
    ]}.

option(User) ->
    UserId = maps:get(id, User),
    #option{value = ias_html:text(UserId),
            selected = UserId =:= alice,
            body = ias_html:text(maps:get(name, User, UserId))}.

previews(Users, Profiles) ->
    #panel{id = <<"issue_previews">>,
           body = [preview(User, Profiles) || User <- Users]}.

preview(User, Profiles) ->
    UserId = maps:get(id, User),
    UserName = maps:get(name, User, UserId),
    Profile = profile_for_user(User, Profiles),
    ProfileId = maps:get(id, Profile),
    Claims = ias_policy:certificate_claims(Profile),
    DeviceLock = ias_policy:device_lock(Profile),
    TwoFactor = ias_policy:two_factor(Profile),
    Request = ias_policy:certificate_request(User, Profile, <<"peer_new">>),
    Validation = ias_policy:validate_certificate_request(Request, Profile),
    Signing = ias_policy:ca_signing_preview(Validation),
    #panel{id = preview_id(UserId),
           class = <<"ias-status-card ias-issue-preview">>,
           style = preview_style(UserId),
           body = [
               #h3{body = ias_html:join(["User: ", UserName])},
               subject_field(),
               field("Selected User", UserName),
               field("Resolved Profile", ProfileId),
               #h3{body = ias_html:text("Resolved Security Policy")},
               security_policy_table(DeviceLock, TwoFactor),
               #h3{body = ias_html:text("Certificate Request")},
               certificate_request_table(Request),
               #h3{body = ias_html:text("Request Validation")},
               validation_table(Validation),
               #h3{body = ias_html:text("CA Signing Preview")},
               signing_table(Signing, Profile),
               #h3{body = ias_html:text("Generated Claims")},
               key_value_table([
                   {"Role", maps:get(role, Claims, undefined)},
                   {"Services", ias_html:join_csv(maps:get(services, Claims, []))},
                   {"Attributes", ias_html:join_csv(maps:get(attributes, Claims, []))},
                   {"Trust Level", maps:get(trust_level, Claims, undefined)}
               ]),
               #h3{body = ias_html:text("Certificate Preview")},
               key_value_table([
                   {"Subject CN", subject_output()},
                   {"Issued To User", UserName},
                   {"Issuer CN", <<"Zencrypted Dev CA">>},
                   {"Role", maps:get(role, Claims, undefined)},
                   {"Services", ias_html:join_csv(maps:get(services, Claims, []))},
                   {"Attributes", ias_html:join_csv(maps:get(attributes, Claims, []))},
                   {"Trust Level", maps:get(trust_level, Claims, undefined)},
                   {"Trusted", true},
                   {"Key Match", true}
               ]),
               #h3{body = ias_html:text("Security Policy")},
               security_policy_table(DeviceLock, TwoFactor),
               #h3{body = ias_html:text("Policy Evaluation")},
               policy_table(Profile),
               issue_controls(UserId)
           ]}.

field(Label, Value) ->
    #p{body = ias_html:join([Label, ": ", Value])}.

subject_field() ->
    #p{body = [ias_html:text("Subject CN: "), subject_output()]}.

subject_output() ->
    #span{class = <<"ias-issue-subject">>, body = ias_html:text("peer_new")}.

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

cell_body(#span{} = Span) ->
    Span;
cell_body(Value) ->
    ias_html:text(Value).

certificate_request_table(Request) ->
    #panel{body = [
        key_value_table([
            {"User", maps:get(user_name, Request, undefined)},
            {"Subject CN", subject_output()},
            {"Resolved Profile", maps:get(profile_id, Request, undefined)},
            {"Requested Role", maps:get(requested_role, Request, undefined)},
            {"Requested Services", ias_html:join_csv(maps:get(requested_services, Request, []))},
            {"Requested Attributes", ias_html:join_csv(maps:get(requested_attributes, Request, []))},
            {"Requested Trust Level", maps:get(requested_trust_level, Request, undefined)}
        ]),
        #h3{body = ias_html:text("SECURITY POLICY")},
        security_policy_table(maps:get(device_lock, Request, undefined),
                              maps:get(two_factor, Request, undefined))
    ]}.

validation_table(Validation) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               header = [#tr{cells = [
                   #th{body = ias_html:text("Check")},
                   #th{body = ias_html:text("Result")},
                   #th{body = ias_html:text("Reason")}
               ]}],
               body = #tbody{body = [validation_row(Check) || Check <- Validation]}}
    ]}.

validation_row(#{check := subject_cn_present} = Check) ->
    #tr{cells = [
        #td{body = ias_html:text("Subject CN present")},
        #td{body = #span{class = <<"ias-issue-subject-valid">>,
                         body = result_text(maps:get(result, Check, false))}},
        #td{body = #span{class = <<"ias-issue-subject-reason">>,
                         body = ias_html:text(maps:get(reason, Check, undefined))}}
    ]};
validation_row(Check) ->
    #tr{cells = [
        #td{body = ias_html:text(check_label(maps:get(check, Check, undefined)))},
        #td{body = result_text(maps:get(result, Check, false))},
        #td{body = ias_html:text(maps:get(reason, Check, undefined))}
    ]}.

signing_table(Signing, Profile) ->
    #panel{body = [
        key_value_table([
            {"CA", maps:get(ca, Signing, undefined)},
            {"Decision", #span{class = <<"ias-issue-ca-decision">>,
                               body = ias_html:text(maps:get(decision, Signing, undefined))}},
            {"Reason", #span{class = <<"ias-issue-ca-reason">>,
                             body = ias_html:text(maps:get(reason, Signing, undefined))}}
        ]),
        #h3{body = ias_html:text("Security Requirements")},
        security_policy_table(ias_policy:device_lock(Profile), ias_policy:two_factor(Profile))
    ]}.

security_policy_table(DeviceLock, TwoFactor) ->
    key_value_table([
        {"Device Lock", DeviceLock},
        {"2FA", TwoFactor}
    ]).

policy_table(Profile) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               header = [#tr{cells = [
                   #th{body = ias_html:text("Service")},
                   #th{body = ias_html:text("Result")},
                   #th{body = ias_html:text("Reason")}
               ]}],
               body = #tbody{body = policy_rows(Profile)}}
    ]}.

policy_rows(Profile) ->
    [policy_row(Profile, Service) || Service <- [vpn, ias]] ++
        [security_policy_row("Device Lock Policy", ias_policy:device_lock(Profile)),
         security_policy_row("2FA Policy", ias_policy:two_factor(Profile))].

policy_row(Profile, Service) ->
    Decision = ias_policy:evaluate_service(Profile, Service),
    #tr{cells = [
        #td{body = ias_html:text(Service)},
        #td{body = ias_html:text(maps:get(decision, Decision, deny))},
        #td{body = ias_html:text(maps:get(reason, Decision, undefined))}
    ]}.

security_policy_row(Label, Result) ->
    #tr{cells = [
        #td{body = ias_html:text(Label)},
        #td{body = ias_html:text(Result)},
        #td{body = ias_html:text("preview only")}
    ]}.

issue_controls(UserId) ->
    #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
           body = [
               #link{class = [button, sgreen],
                     body = ias_html:text("Issue Certificate"),
                     source = [issue_subject, issue_source_certificate],
                     postback = {issue_cert_demo, UserId}},
               #panel{id = issue_result_id(UserId)}
           ]}.

issue_result({ok, Certificate}) ->
    Id = maps:get(id, Certificate, undefined),
    #panel{style = <<"padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Demo certificate issued")},
               key_value_table([
                   {"Certificate ID", Id},
                   {"User", maps:get(user_name, Certificate, undefined)},
                   {"Profile", maps:get(profile_id, Certificate, undefined)},
                   {"Subject CN", maps:get(subject_cn, Certificate, undefined)},
                   {"Device Lock", maps:get(device_lock, Certificate, undefined)},
                   {"2FA", maps:get(two_factor, Certificate, undefined)}
               ]),
               #link{url = ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]),
                     style = <<"display:inline-block;margin-top:8px;padding:7px 10px;border:1px solid #93c5fd;border-radius:5px;background:#ffffff;color:#1d4ed8;text-decoration:none;font-size:12px;font-weight:600;">>,
                     body = ias_html:text("View Certificate")}
           ]};
issue_result({error, user_not_found}) ->
    issue_error("User not found");
issue_result({error, profile_not_found}) ->
    issue_error("Security profile not found");
issue_result({error, source_certificate_not_found}) ->
    issue_error("Enrollment certificate not found");
issue_result({error, Reason}) ->
    issue_error(Reason).

issue_error(Reason) ->
    #panel{style = <<"padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("Demo certificate issue failed")},
               #p{body = ias_html:text(Reason)}
           ]}.

check_label(profile_exists) ->
    <<"Profile exists">>;
check_label(user_exists) ->
    <<"User exists">>;
check_label(subject_cn_present) ->
    <<"Subject CN present">>;
check_label(requested_services_allowed) ->
    <<"Requested services allowed">>;
check_label(requested_attributes_allowed) ->
    <<"Requested attributes allowed">>;
check_label(certificate_role_allowed) ->
    <<"Certificate role allowed">>;
check_label(Check) ->
    Check.

result_text(true) ->
    <<"yes">>;
result_text(false) ->
    <<"no">>.

profile_for_user(User, Profiles) ->
    ProfileId = maps:get(profile_id, User, undefined),
    case [Profile || #{id := Id} = Profile <- Profiles, Id =:= ProfileId] of
        [Profile | _] -> Profile;
        [] -> #{}
    end.

preview_id(UserId) ->
    ias_html:join(["issue_preview_", UserId]).

issue_result_id(UserId) ->
    ias_html:join(["issue_result_", UserId]).

preview_style(alice) ->
    <<"display:block;">>;
preview_style(_UserId) ->
    <<"display:none;">>.

toggle_preview_js() ->
    <<
        "var user=this.value;",
        "var panels = document.querySelectorAll('.ias-issue-preview');",
        "for (var i = 0; i < panels.length; i++) { panels[i].style.display = 'none'; }",
        "var selected = document.getElementById('issue_preview_' + user);",
        "if (selected) { selected.style.display = 'block'; }",
        "return false;"
    >>.

update_subject_js() ->
    <<
        "var raw=this.value;",
        "var subject=raw || 'peer_new';",
        "var valid=raw.trim().length > 0;",
        "var outputs=document.querySelectorAll('.ias-issue-subject');",
        "for (var i=0; i<outputs.length; i++) { outputs[i].textContent = subject; }",
        "var validOutputs=document.querySelectorAll('.ias-issue-subject-valid');",
        "for (var j=0; j<validOutputs.length; j++) { validOutputs[j].textContent = valid ? 'yes' : 'no'; }",
        "var reasonOutputs=document.querySelectorAll('.ias-issue-subject-reason');",
        "for (var k=0; k<reasonOutputs.length; k++) { reasonOutputs[k].textContent = valid ? 'subject is set' : 'subject is required'; }",
        "var decisionOutputs=document.querySelectorAll('.ias-issue-ca-decision');",
        "for (var l=0; l<decisionOutputs.length; l++) { decisionOutputs[l].textContent = valid ? 'would sign' : 'would reject'; }",
        "var caReasonOutputs=document.querySelectorAll('.ias-issue-ca-reason');",
        "for (var m=0; m<caReasonOutputs.length; m++) { caReasonOutputs[m].textContent = valid ? 'request matches selected profile' : 'validation failed'; }",
        "return false;"
    >>.

field_value(undefined, Default) ->
    Default;
field_value(<<>>, Default) ->
    Default;
field_value(Value, Default) ->
    Text = ias_html:text(Value),
    case Text of
        <<>> -> Default;
        _ -> Text
    end.

optional_field(undefined) ->
    undefined;
optional_field(<<>>) ->
    undefined;
optional_field(Value) ->
    Text = ias_html:text(Value),
    case Text of
        <<>> -> undefined;
        _ -> Text
    end.

issue_certificate(UserId, SubjectCN, undefined) ->
    ias_certificate_issue_demo:issue(UserId, SubjectCN, ias_demo_data:profiles());
issue_certificate(UserId, SubjectCN, SourceCertificateId) ->
    ias_certificate_issue_demo:issue_from_certificate(SourceCertificateId, UserId,
                                                      SubjectCN, ias_demo_data:profiles()).

source_certificate_options() ->
    [#option{value = <<>>,
             selected = true,
             body = ias_html:text("none")} |
     [source_certificate_option(Certificate)
      || Certificate <- enrollment_certificates()]].

source_certificate_option(Certificate) ->
    Id = maps:get(id, Certificate, undefined),
    #option{value = ias_html:text(Id),
            body = ias_html:join([<<"Certificate #">>, Id])}.

enrollment_certificates() ->
    [Certificate || Certificate <- ias_demo_store:certificates(),
                    maps:get(source, Certificate, undefined) =:= cmp_demo_enrollment].
