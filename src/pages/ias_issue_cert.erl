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
        #p{body = ias_html:text("Subject CN: peer_new")},
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
               field("Subject CN", <<"peer_new">>),
               field("Selected Profile", ProfileId),
               #h3{body = ias_html:text("Generated Claims")},
               claim_field("role", maps:get(role, Claims, undefined)),
               claim_field("services", ias_html:join_csv(maps:get(services, Claims, []))),
               claim_field("attrs", ias_html:join_csv(maps:get(attributes, Claims, []))),
               claim_field("trust", maps:get(trust_level, Claims, undefined)),
               #h3{body = ias_html:text("Authorization Result")},
               field("VPN", authorization(Decision))
           ]}.

field(Label, Value) ->
    #p{body = ias_html:join([Label, ": ", Value])}.

claim_field(Label, Value) ->
    #p{body = ias_html:join([Label, "=", Value])}.

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
