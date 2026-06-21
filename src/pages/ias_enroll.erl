-module(ias_enroll).
-export([event/1, content_for/1, enrollment_context/0]).
-include_lib("n2o/include/n2o.hrl").
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(preview) ->
    CommonName = field_value(nitro:q(enroll_common_name), <<"vpn-client">>),
    Profile = field_value(nitro:q(enroll_profile), <<"secp384r1">>),
    CmpServer = field_value(nitro:q(enroll_cmp_server), <<"127.0.0.1:8829">>),
    Context = context_from_form(),
    nitro:update(enroll_preview_result, preview_panel(CommonName, Profile, CmpServer,
                                                      Context));
event(enroll) ->
    CommonName = field_value(nitro:q(enroll_common_name), <<"vpn-client">>),
    Profile = field_value(nitro:q(enroll_profile), <<"secp384r1">>),
    CmpServer = field_value(nitro:q(enroll_cmp_server), <<"127.0.0.1:8829">>),
    Context = context_from_form(),
    EnrollmentCN = ias_cmp_enrollment:enrollment_cn(CommonName),
    Result = ias_cmp_enrollment:enroll(#{
        common_name => CommonName,
        enrollment_common_name => EnrollmentCN,
        profile => Profile,
        server => CmpServer
    }),
    nitro:update(enroll_preview_result,
                 preview_panel(CommonName, EnrollmentCN, Profile, CmpServer, Result,
                               Context));
event(import_cert_demo) ->
    EnrollmentId = field_value(nitro:q(enroll_import_enrollment_id), <<"not found">>),
    Context = context_from_form(),
    case ias_cert_enrollment_import:import(EnrollmentId) of
        {ok, Stored} ->
            certificate_import_done(Stored, Context);
        not_found ->
            nitro:update(enroll_import_result, certificate_import_not_found())
    end;
event({issue_enrollment_certificate, CertificateId, UserSelectId}) ->
    UserId = selected_issue_user(nitro:q(UserSelectId)),
    Result = issue_enrollment_certificate(CertificateId, UserId),
    nitro:update(enroll_lifecycle_result_id(CertificateId),
                 enrollment_lifecycle_result(CertificateId, Result));
event(_) ->
    ok.

content() ->
    content_for(enrollment_context()).

content_for(Context) ->
    CommonName = maps:get(suggested_cn, Context, <<"vpn-client">>),
    Profile = <<"secp384r1">>,
    CmpServer = <<"127.0.0.1:8829">>,
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Certificate Enrollment Preview")},
        #p{body = ias_html:text("Preview how IAS will prepare a certificate enrollment request before calling the external CA/CMP service.")},
        return_context_panel(Context),
        form_panel(CommonName, Profile, CmpServer, Context),
        preview_panel(CommonName, Profile, CmpServer, Context)
    ]}.

form_panel(CommonName, Profile, CmpServer, Context) ->
    Body = [
        #h3{body = ias_html:text("Enrollment Input")},
        input_row("Common Name", enroll_common_name, CommonName),
        input_row("Profile", enroll_profile, Profile),
        input_row("CMP Server", enroll_cmp_server, CmpServer)
    ] ++ hidden_context_fields(Context) ++ [
        #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
               body = [
                   #link{id = enroll_preview_button,
                         class = [button, sgreen],
                         body = ias_html:text("Preview Enrollment"),
                         source = enroll_form_sources(),
                         postback = preview},
                   #link{id = enroll_ca_button,
                         class = [button, sgreen],
                         body = ias_html:text("Enroll via CA"),
                         source = enroll_form_sources(),
                         postback = enroll},
                   #span{style = <<"font-size:12px;color:#64748b;">>,
                         body = ias_html:text("Development mode only. No certificate or key material is stored by IAS.")}
               ]}
    ],
    #panel{class = <<"ias-status-card">>, body = Body}.

input_row(Label, Id, Value) ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = Id,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text(Label)},
               #input{id = Id,
                      type = <<"text">>,
                      value = ias_html:text(Value),
                      style = <<"min-width:260px;max-width:420px;width:100%;">>}
           ]}.

return_context_panel(#{return_to := <<"provisioning_wizard">>} = Context) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Return to Provisioning Wizard")},
        key_value_table([
            {"Wizard", maps:get(wizard_id, Context, <<>>)},
            {"Device", maps:get(device_id, Context, <<>>)},
            {"Suggested CN", maps:get(suggested_cn, Context, <<"vpn-client">>)}
        ]),
        #link{url = wizard_url(maps:get(wizard_id, Context, <<>>)),
              class = [button, sgreen],
              body = ias_html:text("Return to Provisioning Wizard")}
    ]};
return_context_panel(_Context) ->
    #panel{body = []}.

hidden_context_fields(Context) ->
    [hidden(enroll_wizard_id, maps:get(wizard_id, Context, <<>>)),
     hidden(enroll_return_to, maps:get(return_to, Context, <<>>)),
     hidden(enroll_device_id, maps:get(device_id, Context, <<>>)),
     hidden(enroll_suggested_cn, maps:get(suggested_cn, Context, <<"vpn-client">>))].

enroll_form_sources() ->
    [enroll_common_name, enroll_profile, enroll_cmp_server | context_source_ids()].

context_source_ids() ->
    [enroll_wizard_id, enroll_return_to, enroll_device_id, enroll_suggested_cn].

preview_panel(CommonName, Profile, CmpServer, Context) ->
    preview_panel(CommonName, CommonName, Profile, CmpServer, preview, Context).

preview_panel(CommonName, EnrollmentCN, Profile, CmpServer, Enrollment, Context) ->
    #panel{id = enroll_preview_result,
           class = <<"ias-status-card">>,
           body = [
               #h3{body = ias_html:text("CSR Preview")},
               key_value_table([
                   {"Requested CN", CommonName},
                   {"Enrollment CN", EnrollmentCN},
                   {"Subject", ias_html:join([<<"CN=">>, EnrollmentCN])},
                   {"Key Type", <<"EC">>},
                   {"Curve", Profile},
                   {"CSR Status", csr_status(Enrollment)}
               ]),
               #h3{body = ias_html:text("CMP Enrollment Plan")},
               key_value_table([
                   {"Command", <<"p10cr">>},
                   {"Server", CmpServer},
                   {"Protection", <<"shared secret">>},
                   {"CA Service", <<"external CA/CMP">>},
                   {"Runtime", <<"CA OTP 28 service">>}
               ]),
               #h3{body = ias_html:text("Issued Certificate Preview")},
               issued_certificate_table(Enrollment, Context)
           ]}.

issued_certificate_table(preview, _Context) ->
    key_value_table([
        {"Status", <<"not issued yet">>},
        {"Reason", <<"preview only">>},
        {"Future Result", <<"X.509 certificate">>}
    ]);
issued_certificate_table({ok, Certificate}, Context) ->
    EnrollmentId = ias_demo_store:add_enrollment_result(Certificate),
    _ = maybe_stage_cmp_material(EnrollmentId, Certificate),
    #panel{body = [
        key_value_table([
            {"Status", <<"issued">>},
            {"Subject", maps:get(subject, Certificate, <<"not found">>)},
            {"Issuer", maps:get(issuer, Certificate, <<"not found">>)},
            {"Not Before", maps:get(not_before, Certificate, <<"not found">>)},
            {"Not After", maps:get(not_after, Certificate, <<"not found">>)}
        ]),
        certificate_import_controls(EnrollmentId, Context)
    ]};
issued_certificate_table({error, ca_unavailable}, _Context) ->
    key_value_table([
        {"Status", <<"failed">>},
        {"Reason", <<"CA service unavailable">>}
    ]);
issued_certificate_table({error, Reason}, _Context) ->
    key_value_table([
        {"Status", <<"failed">>},
        {"Reason", Reason}
    ]).


maybe_stage_cmp_material(EnrollmentId, Certificate) ->
    case maps:get(certificate_pem, Certificate, undefined) of
        undefined -> not_found;
        Pem -> ias_certificate_material:stage_cmp(EnrollmentId, Pem)
    end.

csr_status({ok, _Certificate}) ->
    <<"generated">>;
csr_status({error, _Reason}) ->
    <<"failed">>;
csr_status(preview) ->
    <<"planned">>.

certificate_import_controls(EnrollmentId, Context) ->
    Body = [
               hidden(enroll_import_enrollment_id, EnrollmentId)
           ] ++ hidden_context_fields(Context) ++ [
               #link{id = enroll_import_cert_button,
                     class = [button, sgreen],
                     body = ias_html:text("Import Certificate as Demo"),
                     source = [enroll_import_enrollment_id | context_source_ids()],
                     postback = import_cert_demo},
               #panel{id = enroll_import_result}
           ],
    #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
           body = Body}.

hidden(Id, Value) ->
    #input{id = Id,
           type = <<"hidden">>,
           value = ias_html:text(Value)}.

certificate_import_result(Stored) ->
    Id = maps:get(id, Stored, undefined),
    #panel{style = <<"padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Certificate demo import completed")},
               key_value_table([
                   {"Issued Certificate", Id},
                   {"Subject", maps:get(subject, Stored, <<"not found">>)},
                   {"Issuer", maps:get(issuer, Stored, <<"not found">>)},
                   {"Private Key Stored", maps:get(private_key_stored, Stored, false)},
                   {"Certificate Body Stored", maps:get(certificate_body_stored, Stored, false)}
               ]),
               #link{url = ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]),
                     style = <<"display:inline-block;margin-top:8px;padding:7px 10px;border:1px solid #93c5fd;border-radius:5px;background:#ffffff;color:#1d4ed8;text-decoration:none;font-size:12px;font-weight:600;">>,
                     body = ias_html:text("View Demo Object")},
               enrollment_lifecycle_panel(Stored)
           ]}.

certificate_import_done(Stored, #{return_to := <<"provisioning_wizard">>,
                                  wizard_id := WizardId}) when WizardId =/= <<>> ->
    case ias_provisioning_wizard_store:select_existing_client_certificate(
           WizardId, maps:get(id, Stored, undefined)) of
        {ok, _Draft} ->
            nitro:redirect(wizard_url(WizardId));
        {error, Reason} ->
            nitro:update(enroll_import_result,
                         wizard_return_error(Stored, WizardId, Reason))
    end;
certificate_import_done(Stored, _Context) ->
    nitro:update(enroll_import_result, certificate_import_result(Stored)).

wizard_return_error(Stored, WizardId, Reason) ->
    #panel{style = <<"padding:12px;border:1px solid rgba(217,119,6,0.25);border-radius:6px;background:#fffbeb;">>,
           body = [
               #h3{body = ias_html:text("Certificate imported; wizard return needs review")},
               key_value_table([
                   {"Issued Certificate", maps:get(id, Stored, undefined)},
                   {"Reason", Reason}
               ]),
               #link{url = wizard_url(WizardId),
                     class = [button, sgreen],
                     body = ias_html:text("Return to Wizard with This Certificate")}
           ]}.

certificate_import_not_found() ->
    #panel{style = <<"padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("Certificate demo import failed")},
               #p{body = ias_html:text("Issued enrollment metadata is no longer available in server runtime state.")}
           ]}.

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

context_from_form() ->
    normalize_context(#{
        wizard_id => field_value(nitro:q(enroll_wizard_id), <<>>),
        return_to => field_value(nitro:q(enroll_return_to), <<>>),
        device_id => field_value(nitro:q(enroll_device_id), <<>>),
        suggested_cn => field_value(nitro:q(enroll_suggested_cn), <<"vpn-client">>)
    }).

enrollment_context() ->
    normalize_context(#{
        wizard_id => query_param(<<"wizard_id">>, <<>>),
        return_to => query_param(<<"return_to">>, <<>>),
        device_id => query_param(<<"device_id">>, <<>>),
        suggested_cn => query_param(<<"suggested_cn">>, <<"vpn-client">>)
    }).

normalize_context(Context) ->
    #{wizard_id => ias_html:text(maps:get(wizard_id, Context, <<>>)),
      return_to => ias_html:text(maps:get(return_to, Context, <<>>)),
      device_id => ias_html:text(maps:get(device_id, Context, <<>>)),
      suggested_cn => field_value(maps:get(suggested_cn, Context, <<"vpn-client">>),
                                  <<"vpn-client">>)}.

query_param(Key, Default) ->
    Cx = get(context),
    Req = Cx#cx.req,
    Query = case Req of
        #{qs := QS} -> uri_string:dissect_query(nitro:to_binary(QS));
        #{query_string := QS} -> uri_string:dissect_query(nitro:to_binary(QS));
        _ -> []
    end,
    case proplists:get_value(Key, Query) of
        undefined ->
            case Key of
                <<"wizard_id">> -> field_value(nitro:qc(wizard_id), Default);
                <<"return_to">> -> field_value(nitro:qc(return_to), Default);
                <<"device_id">> -> field_value(nitro:qc(device_id), Default);
                <<"suggested_cn">> -> field_value(nitro:qc(suggested_cn), Default)
            end;
        Value ->
            field_value(Value, Default)
    end.

enrollment_lifecycle_panel(Certificate) ->
    CertificateId = maps:get(id, Certificate, undefined),
    #panel{id = enroll_lifecycle_result_id(CertificateId),
           style = <<"margin-top:14px;">>,
           body = enrollment_lifecycle_body(Certificate)}.

enrollment_lifecycle_result(CertificateId, {ok, _IssuedCertificate}) ->
    case ias_demo_store:get(CertificateId) of
        {ok, Certificate} ->
            enrollment_lifecycle_panel(Certificate);
        not_found ->
            lifecycle_error_panel("Enrollment certificate not found")
    end;
enrollment_lifecycle_result(_CertificateId, {error, source_certificate_not_found}) ->
    lifecycle_error_panel("Enrollment certificate not found");
enrollment_lifecycle_result(_CertificateId, {error, user_not_found}) ->
    lifecycle_error_panel("Issue user not found");
enrollment_lifecycle_result(_CertificateId, {error, profile_not_found}) ->
    lifecycle_error_panel("Security profile not found");
enrollment_lifecycle_result(_CertificateId, {error, Reason}) ->
    lifecycle_error_panel(Reason).

enrollment_lifecycle_body(Certificate) ->
    CertificateId = maps:get(id, Certificate, undefined),
    case ias_certificate_issue_demo:issued_certificate_for_source(CertificateId) of
        {ok, IssuedCertificate} ->
            [
                #h3{body = ias_html:text("Certificate Lifecycle")},
                key_value_table([
                    {"Status", <<"Issued">>},
                    {"Issued To", maps:get(user_name, IssuedCertificate,
                                           maps:get(user, IssuedCertificate, undefined))},
                    {"Issued Certificate", certificate_link(IssuedCertificate)}
                ])
            ];
        not_found ->
            [
                #h3{body = ias_html:text("Certificate Lifecycle")},
                key_value_table([
                    {"Status", <<"Pending">>}
                ]),
                issue_to_selector(CertificateId),
                issue_lifecycle_controls(CertificateId)
            ]
    end.

issue_enrollment_certificate(CertificateId, UserId) ->
    case ias_demo_store:get(CertificateId) of
        {ok, Certificate} ->
            SubjectCN = lifecycle_subject(Certificate),
            ias_certificate_issue_demo:issue_from_certificate(CertificateId, UserId,
                                                              SubjectCN, ias_demo_data:profiles());
        not_found ->
            {error, source_certificate_not_found}
    end.

issue_to_selector(CertificateId) ->
    SelectId = enroll_lifecycle_user_id(CertificateId),
    #panel{style = <<"margin-top:12px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
           body = [
               #span{body = ias_html:text("Issue To: ")},
               #select{id = SelectId,
                       body = issue_user_options()}
           ]}.

issue_lifecycle_controls(CertificateId) ->
    SelectId = enroll_lifecycle_user_id(CertificateId),
    #panel{style = <<"margin-top:10px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
           body = [
               #link{id = enroll_lifecycle_issue_button_id(CertificateId),
                     class = [button, sgreen],
                     body = ias_html:text("Issue Certificate"),
                     source = [SelectId],
                     postback = {issue_enrollment_certificate, CertificateId, SelectId}}
           ]}.

enroll_lifecycle_user_id(CertificateId) ->
    ias_html:join([<<"enroll_issue_user_">>, CertificateId]).

enroll_lifecycle_issue_button_id(CertificateId) ->
    ias_html:join([<<"enroll_issue_button_">>, CertificateId]).

issue_user_options() ->
    [issue_user_option(User) || User <- ias_demo_data:users()].

issue_user_option(User) ->
    UserId = maps:get(id, User),
    #option{value = ias_html:text(UserId),
            selected = UserId =:= alice,
            body = ias_html:text(maps:get(name, User, UserId))}.

selected_issue_user(undefined) ->
    alice;
selected_issue_user(<<>>) ->
    alice;
selected_issue_user(Value) ->
    Text = ias_html:text(Value),
    case [UserId || User <- ias_demo_data:users(),
                    UserId <- [maps:get(id, User, undefined)],
                    ias_html:text(UserId) =:= Text] of
        [UserId | _] -> UserId;
        [] -> alice
    end.

lifecycle_subject(Certificate) ->
    case maps:get(requested_cn, Certificate, <<"peer_new">>) of
        <<"not found">> -> maps:get(enrollment_cn, Certificate, <<"peer_new">>);
        Value -> Value
    end.

certificate_link(Certificate) ->
    Id = maps:get(id, Certificate, undefined),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]),
          body = ias_html:join([<<"Certificate #">>, Id])}.

wizard_url(WizardId) ->
    ias_html:join([<<"/app/provisioning-wizard.htm?id=">>, ias_html:text(WizardId)]).

lifecycle_error_panel(Reason) ->
    #panel{style = <<"padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("Certificate lifecycle issue failed")},
               #p{body = ias_html:text(Reason)}
           ]}.

enroll_lifecycle_result_id(CertificateId) ->
    ias_html:join([<<"enroll_lifecycle_">>, ias_html:text(CertificateId)]).
