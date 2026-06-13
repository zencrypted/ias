-module(ias_enroll).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(preview) ->
    CommonName = field_value(nitro:q(enroll_common_name), <<"vpn-client">>),
    Profile = field_value(nitro:q(enroll_profile), <<"secp384r1">>),
    CmpServer = field_value(nitro:q(enroll_cmp_server), <<"127.0.0.1:8829">>),
    nitro:update(enroll_preview_result, preview_panel(CommonName, Profile, CmpServer));
event(enroll) ->
    CommonName = field_value(nitro:q(enroll_common_name), <<"vpn-client">>),
    Profile = field_value(nitro:q(enroll_profile), <<"secp384r1">>),
    CmpServer = field_value(nitro:q(enroll_cmp_server), <<"127.0.0.1:8829">>),
    EnrollmentCN = ias_cmp_enrollment:enrollment_cn(CommonName),
    Result = ias_cmp_enrollment:enroll(#{
        common_name => CommonName,
        enrollment_common_name => EnrollmentCN,
        profile => Profile,
        server => CmpServer
    }),
    nitro:update(enroll_preview_result, preview_panel(CommonName, EnrollmentCN, Profile, CmpServer, Result));
event(import_cert_demo) ->
    EnrollmentId = field_value(nitro:q(enroll_import_enrollment_id), <<"not found">>),
    case ias_demo_store:get_enrollment_result(EnrollmentId) of
        {ok, Enrollment} ->
            Certificate = certificate_demo_object(Enrollment),
            Stored = ias_demo_store:add_certificate(Certificate),
            nitro:update(enroll_import_result, certificate_import_result(Stored));
        not_found ->
            nitro:update(enroll_import_result, certificate_import_not_found())
    end;
event(_) ->
    ok.

content() ->
    CommonName = <<"vpn-client">>,
    Profile = <<"secp384r1">>,
    CmpServer = <<"127.0.0.1:8829">>,
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Certificate Enrollment Preview")},
        #p{body = ias_html:text("Preview how IAS will prepare a certificate enrollment request before calling the external CA/CMP service.")},
        form_panel(CommonName, Profile, CmpServer),
        preview_panel(CommonName, Profile, CmpServer)
    ]}.

form_panel(CommonName, Profile, CmpServer) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Enrollment Input")},
        input_row("Common Name", enroll_common_name, CommonName),
        input_row("Profile", enroll_profile, Profile),
        input_row("CMP Server", enroll_cmp_server, CmpServer),
        #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
               body = [
                   #link{id = enroll_preview_button,
                         class = [button, sgreen],
                         body = ias_html:text("Preview Enrollment"),
                         source = [enroll_common_name, enroll_profile, enroll_cmp_server],
                         postback = preview},
                   #link{id = enroll_ca_button,
                         class = [button, sgreen],
                         body = ias_html:text("Enroll via CA"),
                         source = [enroll_common_name, enroll_profile, enroll_cmp_server],
                         postback = enroll},
                   #span{style = <<"font-size:12px;color:#64748b;">>,
                         body = ias_html:text("Development mode only. No certificate or key material is stored by IAS.")}
               ]}
    ]}.

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

preview_panel(CommonName, Profile, CmpServer) ->
    preview_panel(CommonName, CommonName, Profile, CmpServer, preview).

preview_panel(CommonName, EnrollmentCN, Profile, CmpServer, Enrollment) ->
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
               issued_certificate_table(Enrollment)
           ]}.

issued_certificate_table(preview) ->
    key_value_table([
        {"Status", <<"not issued yet">>},
        {"Reason", <<"preview only">>},
        {"Future Result", <<"X.509 certificate">>}
    ]);
issued_certificate_table({ok, Certificate}) ->
    EnrollmentId = ias_demo_store:add_enrollment_result(Certificate),
    #panel{body = [
        key_value_table([
            {"Status", <<"issued">>},
            {"Subject", maps:get(subject, Certificate, <<"not found">>)},
            {"Issuer", maps:get(issuer, Certificate, <<"not found">>)},
            {"Not Before", maps:get(not_before, Certificate, <<"not found">>)},
            {"Not After", maps:get(not_after, Certificate, <<"not found">>)}
        ]),
        certificate_import_controls(EnrollmentId)
    ]};
issued_certificate_table({error, ca_unavailable}) ->
    key_value_table([
        {"Status", <<"failed">>},
        {"Reason", <<"CA service unavailable">>}
    ]);
issued_certificate_table({error, Reason}) ->
    key_value_table([
        {"Status", <<"failed">>},
        {"Reason", Reason}
    ]).

csr_status({ok, _Certificate}) ->
    <<"generated">>;
csr_status({error, _Reason}) ->
    <<"failed">>;
csr_status(preview) ->
    <<"planned">>.

certificate_import_controls(EnrollmentId) ->
    #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
           body = [
               hidden(enroll_import_enrollment_id, EnrollmentId),
               #link{id = enroll_import_cert_button,
                     class = [button, sgreen],
                     body = ias_html:text("Import Certificate as Demo"),
                     source = [enroll_import_enrollment_id],
                     postback = import_cert_demo},
               #panel{id = enroll_import_result}
           ]}.

hidden(Id, Value) ->
    #input{id = Id,
           type = <<"hidden">>,
           value = ias_html:text(Value)}.

certificate_demo_object(Enrollment) ->
    Subject = maps:get(subject, Enrollment, <<"not found">>),
    ImportId = demo_import_id(Subject),
    #{id => ias_html:join([ImportId, <<"_certificate">>]),
      source => cmp_demo_enrollment,
      import_id => ImportId,
      subject => Subject,
      issuer => maps:get(issuer, Enrollment, <<"not found">>),
      not_before => maps:get(not_before, Enrollment, <<"not found">>),
      not_after => maps:get(not_after, Enrollment, <<"not found">>),
      requested_cn => maps:get(requested_cn, Enrollment, <<"not found">>),
      enrollment_cn => maps:get(enrollment_cn, Enrollment, <<"not found">>),
      profile => maps:get(profile, Enrollment, <<"secp384r1">>),
      cmp_server => maps:get(cmp_server, Enrollment, <<"127.0.0.1:8829">>),
      private_key_stored => false,
      certificate_body_stored => false}.

demo_import_id(Subject) ->
    ias_html:join([<<"cmp_enrollment_">>,
                   ias_html:text(erlang:system_time(millisecond)), <<"_">>,
                   ias_html:text(erlang:unique_integer([positive])), <<"_">>,
                   file_stem(Subject)]).

file_stem(Value) ->
    file_stem(ias_html:text(Value), <<>>).

file_stem(<<>>, <<>>) ->
    <<"certificate">>;
file_stem(<<>>, Acc) ->
    Acc;
file_stem(<<Char/utf8, Rest/binary>>, Acc)
  when (Char >= $a andalso Char =< $z) orelse
       (Char >= $A andalso Char =< $Z) orelse
       (Char >= $0 andalso Char =< $9) orelse
       Char =:= $_ orelse
       Char =:= $- ->
    file_stem(Rest, <<Acc/binary, Char/utf8>>);
file_stem(<<_Char/utf8, Rest/binary>>, Acc) ->
    file_stem(Rest, <<Acc/binary, $_>>).

certificate_import_result(Stored) ->
    Id = maps:get(id, Stored, undefined),
    #panel{style = <<"padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Certificate demo import completed")},
               key_value_table([
                   {"Certificate ID", Id},
                   {"Subject", maps:get(subject, Stored, <<"not found">>)},
                   {"Issuer", maps:get(issuer, Stored, <<"not found">>)},
                   {"Private Key Stored", maps:get(private_key_stored, Stored, false)},
                   {"Certificate Body Stored", maps:get(certificate_body_stored, Stored, false)}
               ]),
               #link{url = ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]),
                     style = <<"display:inline-block;margin-top:8px;padding:7px 10px;border:1px solid #93c5fd;border-radius:5px;background:#ffffff;color:#1d4ed8;text-decoration:none;font-size:12px;font-weight:600;">>,
                     body = ias_html:text("View Demo Object")}
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
        #td{body = ias_html:text(Value)}
    ]}.

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
