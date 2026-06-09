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
    Decision = ias_policy:evaluate_vpn(Profile),
    #panel{id = preview_id(ProfileId),
           class = <<"ias-status-card ias-issue-preview">>,
           style = preview_style(ProfileId),
           body = [
               #h3{body = ias_html:join(["Profile: ", ProfileId])},
               subject_field(),
               field("Selected Profile", ProfileId),
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
               #h3{body = ias_html:text("Authorization Result")},
               field("VPN", authorization(Decision))
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

authorization(#{authorized := true}) ->
    <<"allowed">>;
authorization(_Decision) ->
    <<"denied">>.

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
        "var subject=this.value || 'peer_new';",
        "var outputs=document.querySelectorAll('.ias-issue-subject');",
        "for (var i=0; i<outputs.length; i++) { outputs[i].textContent = subject; }",
        "return false;"
    >>.
