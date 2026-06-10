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
            #input{id = ovpn_upload_placeholder,
                   type = <<"button">>,
                   value = ias_html:text("Upload .ovpn (coming later)"),
                   disabled = true},
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
               #h3{body = ias_html:text("Future Mapping")},
               key_value_table([
                   {"IAS Device Preview", pending},
                   {"IAS Certificate Preview", pending},
                   {"VPN Service Preview", pending}
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
