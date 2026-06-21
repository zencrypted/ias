-module(ias_state).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(export_demo_state) ->
    Term = ias_demo_state:export(),
    nitro:update(state_export_result, export_result(Term)),
    nitro:wire(download_js(Term));
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
            {"Provisioning Wizard Drafts", maps:get(wizard_drafts, Summary, 0)},
            {"Total Runtime Records", maps:get(total_records, Summary, 0)}
        ])
    ]}.

export_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Export Demo State")},
        #p{body = ias_html:text("Exports current ETS demo runtime state and sanitized provisioning wizard drafts as Erlang term metadata.")},
        #link{class = [button, sgreen],
              body = ias_html:text("Export Demo State"),
              postback = export_demo_state},
        #panel{id = state_export_result}
    ]}.

import_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Import Demo State")},
        #p{body = ias_html:text("Paste an exported .eterm snapshot or choose a .eterm file.")},
        #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:12px;padding:10px;border:1px solid rgba(15,23,42,0.12);border-radius:6px;background:#fff;">>,
               body = [
            #label{for = state_import_file,
                   style = <<"font-weight:600;color:#334155;white-space:nowrap;">>,
                   body = ias_html:text("Import Demo State File")},
            #input{id = state_import_file,
                   type = <<"file">>,
                   accept = <<".eterm,text/plain">>,
                   style = <<"width:auto;flex:1;box-shadow:none;">>,
                   onchange = import_file_js()},
            #span{id = state_import_file_name,
                  style = <<"font-size:12px;color:#64748b;white-space:nowrap;">>,
                  body = ias_html:text("No file selected")}
        ]},
        #textarea{id = state_import_snapshot,
                  rows = 12,
                  cols = 90,
                  placeholder = <<"Paste exported IAS demo state Erlang term snapshot here">>,
                  style = <<"width:100%;min-height:220px;font-family:monospace;">>},
        #panel{style = <<"margin-top:12px;">>, body = [
            #link{id = state_import_button,
                  class = [button, sgreen],
                  body = ias_html:text("Import Demo State"),
                  source = [state_import_snapshot],
                  postback = import_demo_state}
        ]}
    ]}.

clear_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Clear Demo State")},
        #p{body = ias_html:text("Clears ETS runtime demo objects, relationships, certificate material and provisioning wizard drafts. Built-in fixtures are not deleted.")},
        #link{class = [button, sgreen],
              body = ias_html:text("Clear Demo State"),
              postback = clear_demo_state}
    ]}.

export_result(Term) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Demo state export ready")},
               key_value_table([
                   {"Bytes", byte_size(Term)}
               ])
           ]}.

import_result(#{imported_objects := Objects,
                imported_relationships := Relationships,
                skipped_invalid_records := Skipped} = Result) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Demo state import completed")},
               key_value_table([
                   {"Imported Objects", Objects},
                   {"Imported Relationships", Relationships},
                   {"Imported Wizard Drafts", maps:get(imported_wizard_drafts, Result, 0)},
                   {"Skipped Invalid Records", Skipped}
               ]),
               imported_wizard_drafts_action(Result)
           ]};
import_result({error, Reason}) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("Demo state import failed")},
               key_value_table([
                   {"Reason", Reason}
               ])
           ]}.

imported_wizard_drafts_action(Result) ->
    case maps:get(imported_wizard_drafts, Result, 0) of
        Count when Count > 0 ->
            #panel{style = <<"margin-top:12px;">>, body = [
                #link{url = <<"/app/provisioning-wizard.htm">>,
                      class = [button, sgreen],
                      body = ias_html:text("Open Restored Wizard Drafts")}
            ]};
        _ ->
            #panel{body = []}
    end.

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


import_file_js() ->
    <<
        "var file=this.files && this.files[0];",
        "if (!file) { return false; }",
        "var name=file.name || '';",
        "var lower=name.toLowerCase();",
        "if (!(lower.endsWith('.eterm') || file.type === 'text/plain' || lower.endsWith('.txt'))) {",
        "alert('Please select an .eterm file.');",
        "this.value='';",
        "var cleared=document.getElementById('state_import_file_name');",
        "if (cleared) { cleared.textContent='No file selected'; }",
        "return false;",
        "}",
        "var fileName=document.getElementById('state_import_file_name');",
        "if (fileName) { fileName.textContent=name; }",
        "var reader=new FileReader();",
        "reader.onload=function(e) {",
        "var target=document.getElementById('state_import_snapshot');",
        "if (target) { target.value=e.target.result || ''; }",
        "var importButton=document.getElementById('state_import_button');",
        "if (importButton) { setTimeout(function(){ importButton.click(); }, 0); }",
        "};",
        "reader.onerror=function() { alert('Could not read selected demo state file.'); };",
        "reader.readAsText(file);",
        "return false;"
    >>.

download_js(Term) ->
    Encoded = base64:encode(Term),
    [
        <<"var data=atob('">>, Encoded, <<"');">>,
        <<"var blob=new Blob([data],{type:'text/plain'});">>,
        <<"var url=URL.createObjectURL(blob);">>,
        <<"var a=document.createElement('a');">>,
        <<"a.href=url;">>,
        <<"a.download='ias-demo-state.eterm';">>,
        <<"document.body.appendChild(a);">>,
        <<"a.click();">>,
        <<"document.body.removeChild(a);">>,
        <<"URL.revokeObjectURL(url);">>
    ].
