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
                   #span{style = <<"font-size:12px;color:#64748b;">>,
                         body = ias_html:text("Preview only. No keys, CSR files, CMP calls, or CA calls are created.")}
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
    #panel{id = enroll_preview_result,
           class = <<"ias-status-card">>,
           body = [
               #h3{body = ias_html:text("CSR Preview")},
               key_value_table([
                   {"Subject", ias_html:join([<<"CN=">>, CommonName])},
                   {"Key Type", <<"EC">>},
                   {"Curve", Profile},
                   {"CSR Status", <<"planned">>}
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
               key_value_table([
                   {"Status", <<"not issued yet">>},
                   {"Reason", <<"preview only">>},
                   {"Future Result", <<"X.509 certificate">>}
               ])
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
