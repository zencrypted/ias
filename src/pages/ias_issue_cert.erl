-module(ias_issue_cert).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    Profiles = ias_demo_data:profiles(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Certificate Issuance Preview")},
        #p{body = ias_html:text("Preview the certificate claims that a future CA workflow would issue from a Security Profile.")},
        selector(Profiles),
        previews(Profiles)
    ]}.

selector(Profiles) ->
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
            #span{body = ias_html:text("Selected Profile: ")},
            #select{id = <<"issue_profile">>,
                    onchange = toggle_preview_js(),
                    body = [option(Profile) || Profile <- Profiles]}
        ]}
    ]}.

option(Profile) ->
    ProfileId = maps:get(id, Profile),
    #option{value = ias_html:text(ProfileId),
            selected = ProfileId =:= default_user,
            body = ias_html:text(ProfileId)}.

previews(Profiles) ->
    #panel{id = <<"issue_previews">>,
           body = [preview(Profile) || Profile <- Profiles]}.

preview(Profile) ->
    ProfileId = maps:get(id, Profile),
    Claims = ias_policy:certificate_claims(Profile),
    Request = ias_policy:certificate_request(Profile, <<"peer_new">>),
    Validation = ias_policy:validate_certificate_request(Request, Profile),
    Signing = ias_policy:ca_signing_preview(Validation),
    #panel{id = preview_id(ProfileId),
           class = <<"ias-status-card ias-issue-preview">>,
           style = preview_style(ProfileId),
           body = [
               #h3{body = ias_html:join(["Profile: ", ProfileId])},
               subject_field(),
               field("Selected Profile", ProfileId),
               #h3{body = ias_html:text("Certificate Request")},
               certificate_request_table(Request),
               #h3{body = ias_html:text("Request Validation")},
               validation_table(Validation),
               #h3{body = ias_html:text("CA Signing Preview")},
               signing_table(Signing),
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
                   {"Issuer CN", <<"Zencrypted Dev CA">>},
                   {"Role", maps:get(role, Claims, undefined)},
                   {"Services", ias_html:join_csv(maps:get(services, Claims, []))},
                   {"Attributes", ias_html:join_csv(maps:get(attributes, Claims, []))},
                   {"Trust Level", maps:get(trust_level, Claims, undefined)},
                   {"Trusted", true},
                   {"Key Match", true}
               ]),
               #h3{body = ias_html:text("Policy Evaluation")},
               policy_table(Profile)
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
    key_value_table([
        {"Subject CN", subject_output()},
        {"Selected Profile", maps:get(profile_id, Request, undefined)},
        {"Requested Role", maps:get(requested_role, Request, undefined)},
        {"Requested Services", ias_html:join_csv(maps:get(requested_services, Request, []))},
        {"Requested Attributes", ias_html:join_csv(maps:get(requested_attributes, Request, []))},
        {"Requested Trust Level", maps:get(requested_trust_level, Request, undefined)}
    ]).

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

signing_table(Signing) ->
    key_value_table([
        {"CA", maps:get(ca, Signing, undefined)},
        {"Decision", #span{class = <<"ias-issue-ca-decision">>,
                           body = ias_html:text(maps:get(decision, Signing, undefined))}},
        {"Reason", #span{class = <<"ias-issue-ca-reason">>,
                         body = ias_html:text(maps:get(reason, Signing, undefined))}}
    ]).

policy_table(Profile) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               header = [#tr{cells = [
                   #th{body = ias_html:text("Service")},
                   #th{body = ias_html:text("Decision")},
                   #th{body = ias_html:text("Reason")}
               ]}],
               body = #tbody{body = [policy_row(Profile, Service) || Service <- [vpn, ias]]}}
    ]}.

policy_row(Profile, Service) ->
    Decision = ias_policy:evaluate_service(Profile, Service),
    #tr{cells = [
        #td{body = ias_html:text(Service)},
        #td{body = ias_html:text(maps:get(decision, Decision, deny))},
        #td{body = ias_html:text(maps:get(reason, Decision, undefined))}
    ]}.

check_label(profile_exists) ->
    <<"Profile exists">>;
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

preview_id(ProfileId) ->
    ias_html:join(["issue_preview_", ProfileId]).

preview_style(default_user) ->
    <<"display:block;">>;
preview_style(_ProfileId) ->
    <<"display:none;">>.

toggle_preview_js() ->
    <<
        "var profile=this.value;",
        "var panels = document.querySelectorAll('.ias-issue-preview');",
        "for (var i = 0; i < panels.length; i++) { panels[i].style.display = 'none'; }",
        "var selected = document.getElementById('issue_preview_' + profile);",
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
