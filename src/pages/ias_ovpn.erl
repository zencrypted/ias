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
        #textarea{id = ovpn_text,
                  name = <<"ovpn_text">>,
                  rows = 16,
                  placeholder = ias_html:text("Paste .ovpn content here"),
                  body = ias_html:text("")},
        #panel{body = [
            #input{id = ovpn_file,
                type = <<"file">>,
                accept = <<".ovpn">>,
                onchange = file_upload_js()},
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

file_upload_js() ->
    <<
        "var file=this.files && this.files[0];",
        "if (!file) { return false; }",
        "if (!file.name || !file.name.toLowerCase().endsWith('.ovpn')) {",
        "alert('Please select an .ovpn file.');",
        "this.value='';",
        "return false;",
        "}",
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
