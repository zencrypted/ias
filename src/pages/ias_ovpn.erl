-module(ias_ovpn).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(preview) ->
    Preview = ias_ovpn_preview:analyze(nitro:q(ovpn_text)),
    nitro:update(ovpn_preview_result, preview_panel(Preview));
event(_) ->
    ok.

content() ->
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Import OVPN Preview")},
        #p{body = ias_html:text("Paste an OpenVPN client configuration for a live-only IAS import preview.")},
        form_panel(),
        preview_panel(ias_ovpn_preview:analyze(<<"">>))
    ]}.

form_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("OVPN Input")},
        #p{style = <<"font-size:12px;margin:0 0 10px;color:#64748b;">>,
           body = ias_html:text("Preview only. Nothing is imported, stored, or connected.")},
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
                   {"Device Action", <<"create preview">>},
                   {"Device Type", <<"vpn-client">>},
                   {"Device Endpoint", endpoint(Preview)},
                   {"Certificate Action", <<"register preview">>},
                   {"CA", presence(maps:get(has_ca, Preview, false))},
                   {"Client Certificate", presence(maps:get(has_cert, Preview, false))},
                   {"Private Key", private_key_plan(maps:get(has_key, Preview, false))},
                   {"TLS Auth", presence(maps:get(tls_auth, Preview, false))},
                   {"VPN Service Action", <<"bind preview">>},
                   {"VPN Service", <<"OpenVPN">>},
                   {"VPN Remote", endpoint(Preview)},
                   {"VPN Protocol", missing_text(maps:get(proto, Preview, not_found))},
                   {"VPN Cipher", missing_text(maps:get(cipher, Preview, not_found))},
                   {"Status", <<"preview only - no changes were applied">>}
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
