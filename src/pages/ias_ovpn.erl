-module(ias_ovpn).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(preview) ->
    Preview = ias_ovpn_preview:analyze(nitro:q(ovpn_text)),
    nitro:update(ovpn_preview_result, preview_panel(Preview));
event(import_plan) ->
    Preview = ias_ovpn_preview:analyze(nitro:q(ovpn_text)),
    nitro:update(ovpn_preview_result, preview_panel(Preview, [import_plan_panel(Preview)]));
event(import_demo) ->
    Preview = ias_ovpn_preview:analyze(nitro:q(ovpn_text)),
    ImportId = ias_demo_store:add_import(ias_ovpn_import:import_map(Preview)),
    nitro:update(ovpn_preview_result, preview_panel(Preview, [demo_import_panel(Preview, ImportId)]));
event(_) ->
    ok.

content() ->
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Import OVPN Preview")},
        #p{body = ias_html:text("Paste an OpenVPN client configuration to preview its IAS mapping and optionally store sanitized demo objects in volatile ETS state.")},
        form_panel(),
        preview_panel(ias_ovpn_preview:analyze(<<"">>))
    ]}.

form_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("OVPN Input")},
        #p{style = <<"font-size:12px;margin:0 0 10px;color:#64748b;">>,
           body = ias_html:text("Preview is read-only. The explicit demo action stores sanitized metadata in volatile ETS only; it never stores key material or connects a VPN.")},
        #textarea{id = ovpn_text,
                  name = <<"ovpn_text">>,
                  rows = 24,
                  style = <<"width:100%;min-height:420px;box-sizing:border-box;font-family:monospace;font-size:13px;line-height:1.45;">>,
                  placeholder = ias_html:text("Paste .ovpn content here"),
                  body = ias_html:text("")},
        #panel{style = <<"display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-top:12px;">>,
               body = [
            #panel{style = <<"display:flex;gap:10px;align-items:center;flex:1 1 360px;min-width:280px;padding:10px;border:1px solid rgba(15,23,42,0.12);border-radius:6px;background:#fff;">>,
                   body = [
                #label{for = ovpn_file,
                       style = <<"font-weight:600;color:#334155;white-space:nowrap;">>,
                       body = ias_html:text("OVPN file")},
                #input{id = ovpn_file,
                       type = <<"file">>,
                       accept = <<".ovpn">>,
                       style = <<"width:auto;flex:1;box-shadow:none;">>,
                       onchange = file_upload_js()},
                #span{id = ovpn_file_name,
                      style = <<"font-size:12px;color:#64748b;white-space:nowrap;">>,
                      body = ias_html:text("No file selected")}
            ]},
            #link{id = ovpn_preview_button,
                class = [button, sgreen],
                body = ias_html:text("Preview"),
                source = [ovpn_text],
                postback = preview}
        ]}
    ]}.

preview_panel(Preview) ->
    preview_panel(Preview, []).

preview_panel(Preview, ExtraBody) ->
    #panel{id = ovpn_preview_result,
           class = <<"ias-status-card">>,
           body = [
               #h3{body = ias_html:text("Preview Output")},
               key_value_table([
                   {"OVPN Detected", maps:get(detected, Preview, false)},
                   {"Lines", maps:get(lines, Preview, 0)},
                   {"Has inline CA block", maps:get(has_ca, Preview, false)},
                   {"Has inline Certificate block", maps:get(has_cert, Preview, false)},
                   {"Has inline Private Key block", maps:get(has_key, Preview, false)}
               ]),
               #h3{body = ias_html:text("Extracted Config")},
               key_value_table([
                   {"Remote Host", missing_text(maps:get(remote_host, Preview, not_found))},
                   {"Remote Port", missing_text(maps:get(remote_port, Preview, not_found))},
                   {"Protocol", missing_text(maps:get(proto, Preview, not_found))},
                   {"Device", missing_text(maps:get(dev, Preview, not_found))},
                   {"Route Count", maps:get(route_count, Preview, 0)},
                   {"TLS Auth", maps:get(tls_auth, Preview, false)},
                   {"Cipher", missing_text(maps:get(cipher, Preview, not_found))},
                   {"Compression", maps:get(compression, Preview, false)}
               ]),
               #h3{body = ias_html:text("IAS Device Preview")},
               key_value_table([
                   {"Type", <<"vpn-client">>},
                   {"Endpoint", endpoint(Preview)},
                   {"Transport", missing_text(maps:get(proto, Preview, not_found))},
                   {"Tunnel Device", missing_text(maps:get(dev, Preview, not_found))}
               ]),
               #h3{body = ias_html:text("IAS Certificate Preview")},
               key_value_table([
                   {"CA", presence(maps:get(has_ca, Preview, false))},
                   {"Client Certificate", presence(maps:get(has_cert, Preview, false))},
                   {"Private Key", presence(maps:get(has_key, Preview, false))},
                   {"TLS Auth", presence(maps:get(tls_auth, Preview, false))}
               ]),
               #h3{body = ias_html:text("VPN Service Preview")},
               key_value_table([
                   {"Service", <<"OpenVPN">>},
                   {"Remote", endpoint(Preview)},
                   {"Protocol", missing_text(maps:get(proto, Preview, not_found))},
                   {"Cipher", missing_text(maps:get(cipher, Preview, not_found))},
                   {"Compression", compression(maps:get(compression, Preview, false))},
                   {"Routes", maps:get(route_count, Preview, 0)}
               ]),
               #h3{body = ias_html:text("Import Plan Preview")},
               key_value_table([
                   {"Device Action", <<"propose demo device">>},
                   {"Device Type", <<"vpn-client">>},
                   {"Device Endpoint", endpoint(Preview)},
                   {"Certificate Action", <<"propose certificate metadata">>},
                   {"CA", presence(maps:get(has_ca, Preview, false))},
                   {"Client Certificate", presence(maps:get(has_cert, Preview, false))},
                   {"Private Key", private_key_plan(maps:get(has_key, Preview, false))},
                   {"TLS Auth", presence(maps:get(tls_auth, Preview, false))},
                   {"VPN Service Action", <<"propose demo service binding">>},
                   {"VPN Service", <<"OpenVPN">>},
                   {"VPN Remote", endpoint(Preview)},
                   {"VPN Protocol", missing_text(maps:get(proto, Preview, not_found))},
                   {"VPN Cipher", missing_text(maps:get(cipher, Preview, not_found))},
                   {"Status", <<"read-only preview - no state changes">>}
               ]),
               import_demo_button()
           ] ++ ExtraBody}.


import_demo_button() ->
    #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
           body = [
               #link{id = ovpn_import_plan_button,
                     class = [button, sgreen],
                     body = ias_html:text("Generate Import Plan"),
                     source = [ovpn_text],
                     postback = import_plan},
               #link{id = ovpn_import_demo_button,
                     class = [button, sgreen],
                     body = ias_html:text("Store Demo Objects"),
                     source = [ovpn_text],
                     postback = import_demo},
               #span{style = <<"font-size:12px;color:#64748b;">>,
                     body = ias_html:text("Explicit demo action. Volatile ETS metadata only; private key material is never stored.")}
           ]}.

import_plan_panel(Preview) ->
    #panel{style = <<"margin-top:16px;padding:12px;border:1px solid rgba(59,130,246,0.25);border-radius:6px;background:#eff6ff;">>,
           body = [
               #h3{body = ias_html:text("IMPORT PLAN")},
               key_value_table([
                   {"Device Action", <<"propose demo device">>},
                   {"Device Type", <<"vpn-client">>},
                   {"Device Endpoint", endpoint(Preview)},
                   {"Certificate Action", <<"propose certificate metadata">>},
                   {"CA", presence(maps:get(has_ca, Preview, false))},
                   {"Client Certificate", presence(maps:get(has_cert, Preview, false))},
                   {"Private Key", private_key_plan(maps:get(has_key, Preview, false))},
                   {"TLS Auth", presence(maps:get(tls_auth, Preview, false))},
                   {"VPN Service Action", <<"propose demo service binding">>},
                   {"VPN Service", <<"OpenVPN">>},
                   {"VPN Remote", endpoint(Preview)},
                   {"VPN Protocol", missing_text(maps:get(proto, Preview, not_found))},
                   {"VPN Cipher", missing_text(maps:get(cipher, Preview, not_found))},
                   {"Status", <<"read-only plan - no state changes">>}
               ])
           ]}.

demo_import_panel(Preview, ImportId) ->
    #panel{style = <<"margin-top:16px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Demo Store Result")},
               #p{style = <<"font-size:12px;margin:0 0 10px;color:#166534;">>,
                  body = ias_html:text("Sanitized Device, Certificate metadata, and VPN Service objects were stored in volatile ETS demo state.")},
               key_value_table([
                   {"Import ID", ImportId},
                   {"Device", ias_html:join([<<"vpn-client " >>, endpoint(Preview)])},
                   {"Certificate", certificate_result(Preview)},
                   {"VPN Service", vpn_service_result(Preview)},
                   {"Private Key", private_key_plan(maps:get(has_key, Preview, false))},
                   {"Status", <<"stored in volatile ETS demo state">>}
               ]),
               #panel{style = <<"display:flex;gap:10px;flex-wrap:wrap;margin-top:12px;">>,
                      body = [
                          demo_result_link(<<"/app/devices.htm">>, "View Devices"),
                          demo_result_link(<<"/app/certificates.htm">>, "View Certificates"),
                          demo_result_link(<<"/app/services.htm">>, "View Services")
                      ]}
           ]}.


demo_result_link(Url, Label) ->
    #link{url = Url,
          style = <<"display:inline-block;padding:7px 10px;border:1px solid #93c5fd;border-radius:5px;background:#ffffff;color:#1d4ed8;text-decoration:none;font-size:12px;font-weight:600;">>,
          body = ias_html:text(Label)}.

certificate_result(Preview) ->
    ias_html:join([
        <<"CA " >>, presence(maps:get(has_ca, Preview, false)),
        <<", client certificate " >>, presence(maps:get(has_cert, Preview, false)),
        <<", TLS auth " >>, presence(maps:get(tls_auth, Preview, false))
    ]).

vpn_service_result(Preview) ->
    ias_html:join([
        <<"OpenVPN " >>,
        missing_text(maps:get(proto, Preview, not_found)),
        <<" " >>,
        endpoint(Preview),
        <<", cipher " >>,
        missing_text(maps:get(cipher, Preview, not_found))
    ]).

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

missing_text(not_found) ->
    <<"not found">>;
missing_text(Value) ->
    Value.

endpoint(Preview) ->
    Host = maps:get(remote_host, Preview, not_found),
    Port = maps:get(remote_port, Preview, not_found),
    case {Host, Port} of
        {not_found, _} -> <<"not found">>;
        {_, not_found} -> <<"not found">>;
        _ -> ias_html:join([Host, <<":">>, Port])
    end.

presence(true) ->
    <<"present">>;
presence(false) ->
    <<"missing">>.

compression(true) ->
    <<"enabled">>;
compression(false) ->
    <<"disabled">>.

private_key_plan(true) ->
    <<"present but not stored">>;
private_key_plan(false) ->
    <<"missing">>.

file_upload_js() ->
    <<
        "var file=this.files && this.files[0];",
        "if (!file) { return false; }",
        "if (!file.name || !file.name.toLowerCase().endsWith('.ovpn')) {",
        "alert('Please select an .ovpn file.');",
        "this.value='';",
        "var cleared=document.getElementById('ovpn_file_name');",
        "if (cleared) { cleared.textContent='No file selected'; }",
        "return false;",
        "}",
        "var fileName=document.getElementById('ovpn_file_name');",
        "if (fileName) { fileName.textContent=file.name; }",
        "var reader=new FileReader();",
        "reader.onload=function(e) {",
        "var target=document.getElementById('ovpn_text');",
        "if (target) { target.value=e.target.result || ''; }",
        "var preview=document.getElementById('ovpn_preview_button');",
        "if (preview) { preview.click(); }",
        "};",
        "reader.readAsText(file);",
        "return false;"
    >>.
