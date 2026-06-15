-module(ias_verify_cert).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event({verify_certificate, PeerId}) ->
    Certificate = verification_certificate(PeerId),
    Result = ias_certificate_verification:verify(Certificate),
    nitro:update(verify_result_id(PeerId), verify_result(Result));
event(_) ->
    ok.

content() ->
    Certificates = verification_certificates(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Certificate Verification")},
        #p{body = ias_html:text("Verify a certificate, resolve its authorization claims and evaluate service access.")},
        selector(Certificates),
        #panel{id = <<"verify_previews">>,
               body = [preview(Certificate) || Certificate <- Certificates]}
    ]}.

selector(Certificates) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Certificate Input")},
        #panel{body = [
            #span{body = ias_html:text("Certificate: ")},
            #select{id = <<"verify_certificate">>,
                    onchange = toggle_preview_js(),
                    body = [option(Certificate) || Certificate <- Certificates]}
        ]}
    ]}.

option(Certificate) ->
    PeerId = maps:get(peer_id, Certificate),
    #option{value = ias_html:text(PeerId),
            selected = PeerId =:= <<"peer_a">>,
            body = ias_html:text(PeerId)}.

preview(Certificate) ->
    PeerId = maps:get(peer_id, Certificate),
    User = maps:get(user, Certificate, #{}),
    Profile = maps:get(profile, Certificate, #{}),
    Claims = maps:get(claims, Certificate, #{}),
    ProfileClaims = ias_policy:certificate_claims(Profile),
    #panel{id = preview_id(PeerId),
           class = <<"ias-status-card ias-verify-preview">>,
           style = preview_style(PeerId),
           body = [
               #h3{body = ias_html:join(["Certificate: ", PeerId])},
               #h3{body = ias_html:text("Certificate Details")},
               key_value_table([
                   {"Subject CN", maps:get(subject_cn, Certificate, undefined)},
                   {"Issuer CN", maps:get(issuer_cn, Certificate, undefined)},
                   {"Role", maps:get(role, Claims, undefined)},
                   {"Services", ias_html:join_csv(maps:get(services, Claims, []))},
                   {"Attributes", ias_html:join_csv(maps:get(attributes, Claims, []))},
                   {"Trust Level", maps:get(trust_level, Claims, undefined)},
                   {"Trusted", maps:get(trusted, Certificate, undefined)},
                   {"Key Match", maps:get(key_match, Certificate, undefined)}
               ]),
               #h3{body = ias_html:text("Resolved Identity")},
               key_value_table([
                   {"Certificate Subject", maps:get(subject_cn, Certificate, undefined)},
                   {"Assigned User", maps:get(name, User, undefined)},
                   {"Resolved Security Profile", maps:get(id, Profile, undefined)}
               ]),
               #h3{body = ias_html:text("Extracted Claims")},
               key_value_table([
                   {"Role", maps:get(role, Claims, undefined)},
                   {"Services", ias_html:join_csv(maps:get(services, Claims, []))},
                   {"Attributes", ias_html:join_csv(maps:get(attributes, Claims, []))},
                   {"Trust Level", maps:get(trust_level, Claims, undefined)}
               ]),
               #h3{body = ias_html:text("Authorization Check")},
               authorization_table(Certificate),
               #h3{body = ias_html:text("Consistency Check")},
               key_value_table([
                   {"Profile Claims Match", ias_policy:certificate_claims_match(ProfileClaims, Claims)}
               ]),
               verify_controls(PeerId)
           ]}.

verify_controls(PeerId) ->
    #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
           body = [
               #link{class = [button, sgreen],
                     body = ias_html:text("Verify Certificate"),
                     postback = {verify_certificate, PeerId}},
               #panel{id = verify_result_id(PeerId)}
           ]}.

verify_result({ok, Verification}) ->
    Id = maps:get(id, Verification, undefined),
    CertificateId = maps:get(certificate_id, Verification, undefined),
    #panel{style = <<"padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Certificate verification recorded")},
               key_value_table([
                   {"Verification", object_link(verification, Id)},
                   {"Certificate", object_link(certificate, CertificateId)},
                   {"Status", maps:get(verification_status, Verification, undefined)},
                   {"Authorization Decision", maps:get(authorization_status, Verification, undefined)}
               ])
           ]};
verify_result({error, Reason}) ->
    #panel{style = <<"padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("Certificate verification failed")},
               #p{body = ias_html:text(Reason)}
           ]}.

authorization_table(Certificate) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               header = [#tr{cells = [
                   #th{body = ias_html:text("Service")},
                   #th{body = ias_html:text("Decision")},
                   #th{body = ias_html:text("Reason")}
               ]}],
               body = #tbody{body = [authorization_row(Certificate, Service) || Service <- [vpn, ias]]}}
    ]}.

authorization_row(Certificate, Service) ->
    Decision = ias_policy:evaluate_certificate(Certificate, Service),
    #tr{cells = [
        #td{body = ias_html:text(Service)},
        #td{body = ias_html:text(maps:get(decision, Decision, deny))},
        #td{body = ias_html:text(maps:get(reason, Decision, undefined))}
    ]}.

verification_certificates() ->
    Summary = ias_vpn_runtime:summary(),
    Peers = ias_vpn_runtime:peers(Summary),
    Users = ias_demo_data:users(),
    Profiles = ias_demo_data:profiles(),
    [verification_certificate(PeerId, Peers, Users, Profiles)
     || PeerId <- [<<"peer_a">>, <<"peer_b">>]].

verification_certificate(PeerId) ->
    verification_certificate(PeerId, ias_vpn_runtime:peers(ias_vpn_runtime:summary()),
                             ias_demo_data:users(), ias_demo_data:profiles()).

verification_certificate(PeerId, Peers, Users, Profiles) ->
    User = user_for_peer(PeerId, Users),
    Profile = profile_for_user(User, Profiles),
    Claims = certificate_claims_for_peer(PeerId),
    Peer = ias_vpn_runtime:peer(PeerId, #{<<"peers">> => Peers}),
    #{peer_id => PeerId,
      subject_cn => value_or(ias_vpn_runtime:certificate_field(Peer, [subject_cn]), PeerId),
      issuer_cn => value_or(ias_vpn_runtime:certificate_field(Peer, [issuer_cn]), <<"Zencrypted Dev CA">>),
      trusted => value_or(ias_vpn_runtime:certificate_field(Peer, [trusted]), true),
      key_match => value_or(ias_vpn_runtime:certificate_field(Peer, [key_match]), true),
      user => User,
      profile => Profile,
      claims => Claims}.

user_for_peer(PeerId, Users) ->
    Devices = ias_demo_data:devices(),
    case [Device || Device <- Devices, maps:get(vpn_peer, Device, undefined) =:= PeerId] of
        [#{owner := Owner} | _] -> user(Owner, Users);
        _ -> #{}
    end.

user(UserId, Users) ->
    case [User || User <- Users, maps:get(id, User, undefined) =:= UserId] of
        [User | _] -> User;
        [] -> #{}
    end.

profile_for_user(User, Profiles) ->
    ProfileId = maps:get(profile_id, User, undefined),
    case [Profile || Profile <- Profiles, maps:get(id, Profile, undefined) =:= ProfileId] of
        [Profile | _] -> Profile;
        [] -> #{}
    end.

certificate_claims_for_peer(<<"peer_a">>) ->
    #{role => admin,
      services => [vpn, ias],
      attributes => [admin, issue_certificates, revoke_certificates],
      trust_level => elevated};
certificate_claims_for_peer(<<"peer_b">>) ->
    #{role => peer,
      services => [vpn],
      attributes => [user, device, vpn_peer],
      trust_level => standard};
certificate_claims_for_peer(_PeerId) ->
    #{}.

value_or(undefined, Default) ->
    Default;
value_or(Value, _Default) ->
    Value.

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

cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

preview_id(PeerId) ->
    ias_html:join(["verify_preview_", PeerId]).

verify_result_id(PeerId) ->
    ias_html:join(["verify_result_", PeerId]).

object_link(Kind, Id) ->
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]),
          body = ias_html:join([object_label(Kind), <<" #">>, Id])}.

object_label(certificate) ->
    <<"Certificate">>;
object_label(verification) ->
    <<"Verification">>;
object_label(Kind) ->
    ias_html:text(Kind).

preview_style(<<"peer_a">>) ->
    <<"display:block;">>;
preview_style(_PeerId) ->
    <<"display:none;">>.

toggle_preview_js() ->
    <<
        "var certificate=this.value;",
        "var panels=document.querySelectorAll('.ias-verify-preview');",
        "for (var i=0; i<panels.length; i++) { panels[i].style.display='none'; }",
        "var selected=document.getElementById('verify_preview_' + certificate);",
        "if (selected) { selected.style.display='block'; }",
        "return false;"
    >>.
