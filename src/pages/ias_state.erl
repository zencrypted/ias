-module(ias_state).
-export([event/1, content/0]).
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
    nitro:update(state_summary, state_summary_content());
event(clear_demo_state) ->
    ok = ias_demo_state:clear(),
    nitro:update(state_result, clear_result()),
    nitro:update(state_summary, state_summary_content());
event(_) ->
    ok.

content() ->
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Demo State")},
        #p{body = ias_html:text("Domain metadata, wizard drafts, sanitized VPN delivery audit entries, and CSR enrollment metadata are durable through KVS. ETS remains the runtime projection, while certificate material, event bridge state, and browser sessions remain explicitly volatile.")},
        #panel{id = state_summary, body = state_summary_content()},
        export_panel(),
        import_panel(),
        clear_panel(),
        #panel{id = state_result}
    ]}.

state_summary_content() ->
    Summary = ias_demo_state:summary(),
    #panel{id = state_summary_content, body = [
        runtime_summary(Summary),
        persistence_policy_summary(Summary),
        projection_health_summary(Summary)
    ]}.

runtime_summary(Summary) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Runtime State Summary")},
        key_value_table([
            {"Runtime Objects", maps:get(objects, Summary, 0)},
            {"Runtime Relationships", maps:get(relationships, Summary, 0)},
            {"Provisioning Wizard Drafts", maps:get(wizard_drafts, Summary, 0)},
            {"Total Runtime Records", maps:get(total_records, Summary, 0)}
        ])
    ]}.

persistence_policy_summary(Summary) ->
    Stores = maps:get(persistence_stores, Summary, []),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Persistence Store Policy")},
        #p{body = ias_html:text("Durable stores use KVS as their source of truth. Volatile stores are intentionally excluded until their lifecycle and secure-material policies are defined.")},
        key_value_table([
            {"Durable Domain Objects", health_value(maps:get(durable_objects,
                                                               Summary,
                                                               unavailable))},
            {"Durable Relationships", health_value(maps:get(durable_relationships,
                                                              Summary,
                                                              unavailable))},
            {"Durable Wizard Drafts", health_value(maps:get(durable_wizard_drafts,
                                                              Summary,
                                                              unavailable))},
            {"Durable Delivery Audit Entries",
             health_value(maps:get(durable_delivery_audit_entries,
                                   Summary,
                                   unavailable))},
            {"ETS Delivery Audit Projection",
             health_value(maps:get(ets_delivery_audit_entries,
                                   Summary,
                                   unavailable))},
            {"Durable CSR Enrollment States",
             health_value(maps:get(durable_csr_enrollment_states,
                                   Summary,
                                   unavailable))},
            {"ETS CSR Enrollment Projection",
             health_value(maps:get(ets_csr_enrollment_states,
                                   Summary,
                                   unavailable))},
            {"Volatile Certificate Materials",
             health_value(maps:get(volatile_certificate_materials,
                                   Summary,
                                   unavailable))}
        ]),
        #h3{body = ias_html:text("Store Classification")},
        key_value_table([{maps:get(label, Store, maps:get(store, Store, unknown)),
                          persistence_store_value(Store)}
                         || Store <- Stores])
    ]}.

persistence_store_value(Store) ->
    ias_html:join([
        ias_html:text(maps:get(mode, Store, unknown)),
        <<" / ">>,
        ias_html:text(maps:get(backend, Store, unknown)),
        <<" / ">>,
        ias_html:text(maps:get(policy, Store, <<"unspecified">>))
    ]).

projection_health_summary(Summary) ->
    Status = maps:get(projection_status, Summary, unavailable),
    #panel{class = <<"ias-status-card">>,
           style = projection_health_style(Status),
           body = [
        #h3{body = ias_html:text("Durable Projection Health")},
        #p{body = ias_html:text(projection_health_notice(Status))},
        key_value_table([
            {"Projection Status", projection_status_text(Status)},
            {"Durable Objects", health_value(maps:get(durable_objects,
                                                       Summary,
                                                       undefined))},
            {"Durable Relationships", health_value(maps:get(durable_relationships,
                                                             Summary,
                                                             undefined))},
            {"Durable Total", health_value(maps:get(durable_total,
                                                     Summary,
                                                     undefined))},
            {"ETS Projection Objects", maps:get(ets_projection_objects,
                                                Summary,
                                                0)},
            {"ETS Projection Relationships", maps:get(ets_projection_relationships,
                                                      Summary,
                                                      0)},
            {"ETS Projection Total", maps:get(ets_projection_total,
                                              Summary,
                                              0)},
            {"Projection Hash Algorithm", health_value(maps:get(projection_hash_algorithm,
                                                                  Summary,
                                                                  undefined))},
            {"Durable Projection Hash", health_value(maps:get(durable_projection_hash,
                                                                Summary,
                                                                undefined))},
            {"ETS Projection Hash", health_value(maps:get(ets_projection_hash,
                                                            Summary,
                                                            undefined))},
            {"Last Successful Rehydration", health_value(maps:get(last_rehydrated_at,
                                                                   Summary,
                                                                   undefined))},
            {"Last Rehydration Attempt", health_value(maps:get(last_rehydration_attempt_at,
                                                                Summary,
                                                                undefined))},
            {"Last Rehydration Error", health_value(maps:get(last_rehydration_error,
                                                              Summary,
                                                              undefined))}
        ])
    ]}.

projection_status_text(synchronized) -> <<"SYNCHRONIZED">>;
projection_status_text(mismatch) -> <<"MISMATCH">>;
projection_status_text(unavailable) -> <<"UNAVAILABLE">>;
projection_status_text(Status) -> ias_html:text(Status).

projection_health_notice(synchronized) ->
    "The ETS read projection matches the validated KVS domain graph and current durable VPN authority overlay.";
projection_health_notice(mismatch) ->
    "The ETS read projection differs from the validated durable state. Rehydration is required before the projection can be trusted.";
projection_health_notice(unavailable) ->
    "The durable domain graph could not be validated. IAS startup fails closed when this condition is detected.";
projection_health_notice(_) ->
    "Projection health is unknown.".

projection_health_style(synchronized) ->
    <<"border-color:rgba(22,163,74,0.35);background:#f0fdf4;">>;
projection_health_style(mismatch) ->
    <<"border-color:rgba(217,119,6,0.35);background:#fffbeb;">>;
projection_health_style(unavailable) ->
    <<"border-color:rgba(220,38,38,0.35);background:#fef2f2;">>;
projection_health_style(_) ->
    <<>>.

health_value(undefined) -> <<"not available">>;
health_value(Value) -> Value.

export_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Export Demo State")},
        #p{body = ias_html:text("Exports the current sanitized ETS projection and provisioning wizard drafts as Erlang term metadata. This snapshot is not the durable source of truth.")},
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
        #p{body = ias_html:text("Clears durable KVS domain objects, wizard drafts, VPN delivery audit entries, CSR enrollment states, their ETS projections, VPN authority and incident state, and volatile certificate material. Built-in fixtures are not deleted.")},
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
               #p{body = ias_html:text("Durable demo domain state, wizard drafts, VPN delivery audit history, and their ETS projections were cleared.")}
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
