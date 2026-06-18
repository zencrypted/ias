-module(ias_verify_cert).
-export([event/1,
         verification_certificates/0,
         verification_certificate/1,
         bulk_verify_runtime_certificates/0]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event({verify_certificate, CertificateId}) ->
    Result = case verification_certificate(CertificateId) of
                 not_found -> {error, certificate_not_found};
                 Certificate -> ias_certificate_verification:verify(Certificate)
             end,
    nitro:update(verify_result_id(CertificateId), verify_result(Result));
event(verify_all_runtime_certificates) ->
    Result = bulk_verify_runtime_certificates(),
    nitro:update(<<"bulk_verify_result">>, bulk_verify_result(Result));
event(_) ->
    ok.

content() ->
    Certificates = verification_certificates(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Certificate Verification")},
        #p{body = ias_html:text("Verify cryptographic certificate trust, resolve identity claims and evaluate service access separately.")},
        selector(Certificates),
        #panel{id = <<"bulk_verify_result">>},
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
        ]},
        #panel{style = <<"margin-top:14px;">>, body = [
            #link{class = [button, sgreen],
                  body = ias_html:text("Verify All Runtime Certificates"),
                  postback = verify_all_runtime_certificates}
        ]}
    ]}.

option(Certificate) ->
    CertificateId = maps:get(certificate_id, Certificate),
    #option{value = ias_html:text(CertificateId),
            selected = maps:get(selected, Certificate, false),
            body = ias_html:join([certificate_type_label(Certificate), <<": ">>,
                                  CertificateId, <<" - ">>,
                                  maps:get(subject_cn, Certificate, <<"not found">>),
                                  <<" (">>, maps:get(source_label, Certificate, <<"runtime">>), <<")">>])}.

preview(Certificate) ->
    CertificateId = maps:get(certificate_id, Certificate),
    User = maps:get(user, Certificate, #{}),
    Profile = maps:get(profile, Certificate, #{}),
    Claims = maps:get(claims, Certificate, #{}),
    ProfileClaims = ias_policy:certificate_claims(Profile),
    #panel{id = preview_id(CertificateId),
           class = <<"ias-status-card ias-verify-preview">>,
           style = preview_style(Certificate),
           body = [
               #h3{body = ias_html:join([<<"Certificate: ">>, CertificateId])},
               #h3{body = ias_html:text("Certificate Details")},
               key_value_table([
                   {"Certificate ID", CertificateId},
                   {"Source", maps:get(source_label, Certificate, <<"runtime">>)},
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
                   {"Resolved Security Profile", maps:get(id, Profile, maps:get(profile_id, Certificate, undefined))}
               ]),
               #h3{body = ias_html:text("Extracted Claims")},
               key_value_table([
                   {"Role", maps:get(role, Claims, undefined)},
                   {"Services", ias_html:join_csv(maps:get(services, Claims, []))},
                   {"Attributes", ias_html:join_csv(maps:get(attributes, Claims, []))},
                   {"Trust Level", maps:get(trust_level, Claims, undefined)}
               ]),
               #h3{body = ias_html:text("Service Authorization Check")},
               #p{body = ias_html:text("Checks whether the verified certificate is permitted to access each service.")},
               authorization_table(Certificate),
               #h3{body = ias_html:text("Consistency Check")},
               key_value_table([
                   {"Profile Claims Match", ias_policy:certificate_claims_match(ProfileClaims, Claims)}
               ]),
               verify_controls(CertificateId)
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
                   {"Service Authorization Result", maps:get(authorization_status, Verification, undefined)}
               ])
           ]};
verify_result({error, Reason}) ->
    #panel{style = <<"padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("Certificate verification failed")},
               #p{body = ias_html:text(Reason)}
           ]}.

bulk_verify_runtime_certificates() ->
    Results = [bulk_verify_certificate(Certificate) || Certificate <- verification_certificates()],
    #{verified => length([Result || Result <- Results,
                                   maps:get(result, Result, undefined) =:= verified]),
      failed => length([Result || Result <- Results,
                                maps:get(result, Result, undefined) =:= failed]),
      skipped => length([Result || Result <- Results,
                                  maps:get(result, Result, undefined) =:= skipped]),
      results => Results}.

bulk_verify_certificate(Certificate) ->
    CertificateId = maps:get(certificate_id, Certificate, undefined),
    case ias_certificate_verification:verify(Certificate) of
        {ok, Verification} ->
            #{certificate_id => CertificateId,
              result => maps:get(verification_status, Verification, failed),
              verification_id => maps:get(id, Verification, undefined)};
        {error, Reason} ->
            #{certificate_id => CertificateId,
              result => skipped,
              reason => Reason}
    end.

bulk_verify_result(Result) ->
    #panel{style = <<"padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;margin-bottom:14px;">>,
           body = [
               #h3{body = ias_html:text("Bulk Verification Completed")},
               key_value_table([
                   {"Verified", maps:get(verified, Result, 0)},
                   {"Failed", maps:get(failed, Result, 0)},
                   {"Skipped", maps:get(skipped, Result, 0)}
               ]),
               #ul{body = [bulk_verify_item(Item)
                           || Item <- maps:get(results, Result, [])]}
           ]}.

bulk_verify_item(Item) ->
    #li{body = [
        object_link(certificate, maps:get(certificate_id, Item, undefined)),
        #ul{body = [
            #li{body = ias_html:join([<<"result: ">>,
                                      maps:get(result, Item, undefined)])},
            bulk_verify_verification_item(Item)
        ]}
    ]}.

bulk_verify_verification_item(#{result := skipped} = Item) ->
    #li{body = ias_html:join([<<"reason: ">>, maps:get(reason, Item, undefined)])};
bulk_verify_verification_item(Item) ->
    #li{body = [
        ias_html:text("verification: "),
        object_link(verification, maps:get(verification_id, Item, undefined))
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
    mark_selected([normalize_certificate(Certificate)
                   || Certificate <- ias_demo_store:certificates(),
                      runtime_verifiable_certificate(Certificate)]).

verification_certificate(CertificateId) ->
    case ias_demo_store:get(CertificateId) of
        {ok, #{kind := certificate} = Certificate} ->
            normalize_certificate(Certificate);
        _ ->
            not_found
    end.

runtime_verifiable_certificate(#{source := certificate_issue_demo}) ->
    true;
runtime_verifiable_certificate(#{source := ovpn_demo_import}) ->
    true;
runtime_verifiable_certificate(#{source := cmp_demo_enrollment}) ->
    true;
runtime_verifiable_certificate(_Certificate) ->
    false.

normalize_certificate(Certificate) ->
    Profile = profile_for_certificate(Certificate),
    Certificate#{
        certificate_id => maps:get(id, Certificate, undefined),
        subject_cn => certificate_subject(Certificate),
        issuer_cn => certificate_issuer(Certificate),
        trusted => maps:get(trusted, Certificate, true),
        key_match => maps:get(key_match, Certificate, true),
        profile => Profile,
        profile_id => maps:get(id, Profile, maps:get(profile_id, Certificate, undefined)),
        user => user_for_certificate(Certificate),
        claims => certificate_claims(Certificate, Profile),
        source_label => source_label(Certificate)
    }.

profile_for_certificate(Certificate) ->
    ProfileId = maps:get(profile_id, Certificate, maps:get(profile, Certificate, undefined)),
    case [Profile || Profile <- ias_demo_data:profiles(),
                     maps:get(id, Profile, undefined) =:= ProfileId] of
        [Profile | _] -> Profile;
        [] -> #{}
    end.

user_for_certificate(Certificate) ->
    UserId = maps:get(user, Certificate, undefined),
    case [User || User <- ias_demo_data:users(),
                  maps:get(id, User, undefined) =:= UserId] of
        [User | _] -> User;
        [] -> #{}
    end.

certificate_claims(Certificate, Profile) when is_map(Profile), map_size(Profile) > 0 ->
    #{role => maps:get(role, Certificate, maps:get(certificate_role, Profile, undefined)),
      services => maps:get(services, Certificate, maps:get(services, Profile, [])),
      attributes => maps:get(attributes, Certificate, maps:get(attributes, Profile, [])),
      trust_level => maps:get(trust_level, Certificate, maps:get(trust_level, Profile, undefined))};
certificate_claims(Certificate, _Profile) ->
    #{role => maps:get(role, Certificate, undefined),
      services => maps:get(services, Certificate, []),
      attributes => maps:get(attributes, Certificate, []),
      trust_level => maps:get(trust_level, Certificate, undefined)}.

certificate_subject(Certificate) ->
    maps:get(subject_cn, Certificate,
             maps:get(subject, Certificate,
                      maps:get(id, Certificate, <<"not found">>))).

certificate_issuer(Certificate) ->
    maps:get(issuer_cn, Certificate,
             maps:get(issuer, Certificate, <<"not found">>)).

source_label(#{source := certificate_issue_demo}) ->
    <<"Issued Certificate">>;
source_label(#{source := cmp_demo_enrollment}) ->
    <<"Enrollment Certificate">>;
source_label(#{source := ovpn_demo_import}) ->
    <<"Imported Certificate">>;
source_label(_Certificate) ->
    <<"Runtime Certificate">>.

certificate_type_label(Certificate) ->
    maps:get(source_label, Certificate, <<"Runtime Certificate">>).

mark_selected([]) ->
    [];
mark_selected([First | Rest]) ->
    [First#{selected => true} | [Certificate#{selected => false} || Certificate <- Rest]].

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

preview_style(#{selected := true}) ->
    <<"display:block;">>;
preview_style(_Certificate) ->
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
