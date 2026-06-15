-module(ias_state).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(export_demo_state) ->
    Json = ias_demo_state:export(),
    nitro:update(state_export_result, export_result(Json)),
    nitro:wire(download_js(Json));
event(import_demo_state) ->
    Snapshot = nitro:q(state_import_snapshot),
    Result = ias_demo_state:import(Snapshot),
    nitro:update(state_result, import_result(Result)),
    nitro:update(state_summary, runtime_summary());
event(clear_demo_state) ->
    ok = ias_demo_state:clear(),
    nitro:update(state_result, clear_result()),
    nitro:update(state_summary, runtime_summary());
event(_) ->
    ok.

content() ->
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Demo State")},
        #p{body = ias_html:text("Demo/runtime only. No production persistence. No private key export. No certificate body export.")},
        #panel{id = state_summary, body = runtime_summary()},
        export_panel(),
        import_panel(),
        clear_panel(),
        #panel{id = state_result}
    ]}.

runtime_summary() ->
    Summary = ias_demo_state:summary(),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Runtime State Summary")},
        key_value_table([
            {"Runtime Objects", maps:get(objects, Summary, 0)},
            {"Runtime Relationships", maps:get(relationships, Summary, 0)},
            {"Total Runtime Records", maps:get(total_records, Summary, 0)}
        ])
    ]}.

export_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Export Demo State")},
        #p{body = ias_html:text("Exports current ETS demo runtime state as JSON metadata.")},
        #link{class = [button, sgreen],
              body = ias_html:text("Export Demo State"),
              postback = export_demo_state},
        #panel{id = state_export_result}
    ]}.

import_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Import Demo State")},
        #textarea{id = state_import_snapshot,
                  rows = 12,
                  cols = 90,
                  placeholder = <<"Paste exported IAS demo state JSON snapshot here">>,
                  style = <<"width:100%;min-height:220px;font-family:monospace;">>},
        #panel{style = <<"margin-top:12px;">>, body = [
            #link{class = [button, sgreen],
                  body = ias_html:text("Import Demo State"),
                  source = [state_import_snapshot],
                  postback = import_demo_state}
        ]}
    ]}.

clear_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Clear Demo State")},
        #p{body = ias_html:text("Clears ETS runtime demo objects and relationships only. Built-in fixtures are not deleted.")},
        #link{class = [button, sgreen],
              body = ias_html:text("Clear Demo State"),
              postback = clear_demo_state}
    ]}.

export_result(Json) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Demo state export ready")},
               key_value_table([
                   {"Bytes", byte_size(Json)}
               ])
           ]}.

import_result(#{imported_objects := Objects,
                imported_relationships := Relationships,
                skipped_invalid_records := Skipped}) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Demo state import completed")},
               key_value_table([
                   {"Imported Objects", Objects},
                   {"Imported Relationships", Relationships},
                   {"Skipped Invalid Records", Skipped}
               ])
           ]};
import_result({error, Reason}) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("Demo state import failed")},
               key_value_table([
                   {"Reason", Reason}
               ])
           ]}.

clear_result() ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Demo state cleared")},
               #p{body = ias_html:text("ETS runtime demo objects and relationships were cleared.")}
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

download_js(Json) ->
    Encoded = base64:encode(Json),
    [
        <<"var data=atob('">>, Encoded, <<"');">>,
        <<"var blob=new Blob([data],{type:'application/json'});">>,
        <<"var url=URL.createObjectURL(blob);">>,
        <<"var a=document.createElement('a');">>,
        <<"a.href=url;">>,
        <<"a.download='ias-demo-state.json';">>,
        <<"document.body.appendChild(a);">>,
        <<"a.click();">>,
        <<"document.body.removeChild(a);">>,
        <<"URL.revokeObjectURL(url);">>
    ].
