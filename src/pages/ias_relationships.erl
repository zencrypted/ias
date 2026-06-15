-module(ias_relationships).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    Content = content(),
    Html = iolist_to_binary(nitro:render(Content)),
    SafeHtml = nitro:js_escape(Html),
    nitro:wire(["qi('stand').innerHTML='", SafeHtml, "';"]);
event(_) ->
    ok.

content() ->
    Summary = ias_relationship_graph:summary(),
    Categories = ias_relationship_graph:categorized_relationships(),
    Report = ias_relationship_graph:graph_consistency_report(),
    Analysis = ias_graph_analysis:report(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Relationship Explorer")},
        #p{body = ias_html:text("Read-only IAS object graph inspection.")},
        summary_panel(Summary),
        #h3{body = ias_html:text("Relationships")},
        relationship_table(maps:get(known, Categories, []), <<"not linked yet">>),
        #h3{body = ias_html:text("Unknown Relationships")},
        relationship_table(maps:get(unknown, Categories, []), <<"not linked yet">>),
        #h3{body = ias_html:text("Broken Relationships")},
        broken_relationship_table(maps:get(broken, Categories, [])),
        #h3{body = ias_html:text("Graph Consistency Checks")},
        consistency_table(Report),
        #h3{body = ias_html:text("GRAPH ANALYSIS")},
        analysis_table(Analysis)
    ]}.

summary_panel(Summary) ->
    #panel{class = <<"ias-summary">>, body = [
        summary_item("Users", maps:get(users, Summary, 0)),
        summary_item("Devices", maps:get(devices, Summary, 0)),
        summary_item("Certificates", maps:get(certificates, Summary, 0)),
        summary_item("Security Profiles", maps:get(security_profiles, Summary, 0)),
        summary_item("Security Policies", maps:get(security_policies, Summary, 0)),
        summary_item("VPN Services", maps:get(vpn_services, Summary, 0)),
        summary_item("Relationships", maps:get(relationships, Summary, 0)),
        summary_item("Total Relationships", maps:get(total_relationships, Summary, 0))
    ]}.

summary_item(Label, Count) ->
    #panel{class = <<"ias-summary-item">>,
           body = ias_html:join([Label, <<": ">>, Count])}.

relationship_table([], EmptyLabel) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [
                   #tr{cells = [#td{colspan = 3, body = ias_html:text(EmptyLabel)}]}
               ]}}
    ]};
relationship_table(Relationships, _EmptyLabel) ->
    #panel{class = <<"ias-relationship-tree">>,
           body = [relationship_edge(Relationship) || Relationship <- Relationships]}.

relationship_edge(Relationship) ->
    Edge = ias_relationship_graph:tree_edge(Relationship),
    #pre{class = <<"ias-tree-line">>,
         style = <<"font-family:monospace;white-space:pre;">>,
         body = relationship_edge_text(Edge)}.

relationship_edge_text(Edge) ->
    ias_html:join([
        maps:get(source, Edge, <<"-">>), <<"\n">>,
        <<"  +-- ">>, maps:get(relation_type, Edge, undefined), <<"\n">>,
        <<"      +-- ">>, maps:get(target, Edge, <<"-">>)
    ]).

broken_relationship_table([]) ->
    relationship_table([], <<"not linked yet">>);
broken_relationship_table(Relationships) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [broken_header() |
                                      [broken_relationship_row(Relationship)
                                       || Relationship <- Relationships]]}}
    ]}.

broken_header() ->
    #tr{cells = [
        #th{body = ias_html:text("Status")},
        #th{body = ias_html:text("Source")},
        #th{body = ias_html:text("Relationship")},
        #th{body = ias_html:text("Missing Target ID")}
    ]}.

broken_relationship_row(Relationship) ->
    #tr{cells = [
        #td{body = ias_html:text("Broken Relationship")},
        #td{body = object_or_missing(maps:get(source_id, Relationship, undefined))},
        #td{body = ias_html:text(maps:get(relation_type, Relationship, undefined))},
        #td{body = missing_target_id(Relationship)}
    ]}.

consistency_table(Report) ->
    Rows = [
        {"Broken Relationships", length(maps:get(broken_relationships, Report, []))},
        {"Unknown Relationship Types", length(maps:get(unknown_relationships, Report, []))},
        {"Missing Objects", length(maps:get(missing_objects, Report, []))},
        {"Total Relationships", maps:get(total_relationships, Report, 0)}
    ],
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [#tr{cells = [
                                        #th{body = ias_html:text(Label)},
                                        #td{body = ias_html:text(Value)}
                                    ]} || {Label, Value} <- Rows]}}
    ]}.

analysis_table(Analysis) ->
    Warnings = analysis_warnings(Analysis),
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [analysis_header() |
                                      lists:append([analysis_rows(Warning)
                                                    || Warning <- Warnings])]}}
    ]}.

analysis_header() ->
    #tr{cells = [
        #th{body = ias_html:text("Warnings")},
        #th{body = ias_html:text("Count")},
        #th{body = ias_html:text("Details")}
    ]}.

analysis_warnings(Analysis) ->
    [
        {<<"Policy mismatches">>, maps:get(policy_mismatches, Analysis, []), fun policy_mismatch_detail/1},
        {<<"Devices without security policy">>, maps:get(devices_without_security_policy, Analysis, []), fun object_detail/1},
        {<<"Certificates without security policy">>, maps:get(certificates_without_security_policy, Analysis, []), fun object_detail/1},
        {<<"Devices without VPN service">>, maps:get(devices_without_vpn_service, Analysis, []), fun object_detail/1},
        {<<"Enrollment certificates without issued certificate">>,
         maps:get(enrollment_certificates_without_issued_certificate, Analysis, []), fun object_detail/1},
        {<<"Certificates linked to multiple devices">>,
         maps:get(certificates_linked_to_multiple_devices, Analysis, []), fun multiple_device_detail/1},
        {<<"Devices with replacement available">>,
         maps:get(devices_with_replacement_available, Analysis, []), fun replacement_detail/1}
    ].

analysis_rows({Label, Warnings, DetailFun}) ->
    Summary = #tr{cells = [
        #th{body = ias_html:text(Label)},
        #td{body = ias_html:text(length(Warnings))},
        #td{body = ias_html:text(summary_detail(Warnings))}
    ]},
    [Summary | detail_rows(Label, Warnings, DetailFun)].

summary_detail([]) ->
    <<"none">>;
summary_detail(_Warnings) ->
    <<"see details">>.

detail_rows(_Label, [], _DetailFun) ->
    [];
detail_rows(Label, Warnings, DetailFun) ->
    [#tr{cells = [
        #td{body = ias_html:text(Label)},
        #td{body = ias_html:text(<<"">>)},
        #td{body = ias_html:text(DetailFun(Warning))}
    ]} || Warning <- Warnings].

policy_mismatch_detail(Warning) ->
    ias_html:join([
        <<"Device ">>, maps:get(device_id, Warning, undefined),
        <<" policy ">>, maps:get(device_policy, Warning, not_found),
        <<"; Certificate ">>, maps:get(certificate_id, Warning, undefined),
        <<" policy ">>, maps:get(certificate_policy, Warning, not_found)
    ]).

object_detail(Warning) ->
    ias_html:join([maps:get(kind, Warning, undefined), <<" ">>,
                   maps:get(id, Warning, undefined)]).

multiple_device_detail(Warning) ->
    ias_html:join([
        <<"Certificate ">>, maps:get(certificate_id, Warning, undefined),
        <<" linked to devices ">>, ias_html:join_csv(maps:get(device_ids, Warning, []))
    ]).

replacement_detail(Warning) ->
    ias_html:join([
        <<"Device ">>, maps:get(device_id, Warning, undefined),
        <<" current ">>, maps:get(current_certificate_id, Warning, not_found),
        <<" candidate ">>, maps:get(candidate_certificate_id, Warning, not_found)
    ]).

object_label(Id) ->
    case ias_demo_store:get(Id) of
        {ok, Object} ->
            ias_html:text(maps:get(name, Object, maps:get(id, Object, Id)));
        not_found ->
            ias_html:text(Id)
    end.

object_or_missing(Id) ->
    case ias_demo_store:get(Id) of
        {ok, Object} ->
            ias_html:text(maps:get(name, Object, maps:get(id, Object, Id)));
        not_found ->
            ias_html:text("Broken Relationship")
    end.

missing_target_id(Relationship) ->
    TargetId = maps:get(target_id, Relationship, undefined),
    case ias_demo_store:get(TargetId) of
        {ok, _Object} ->
            missing_source_id(Relationship);
        not_found ->
            ias_html:text(TargetId)
    end.

missing_source_id(Relationship) ->
    SourceId = maps:get(source_id, Relationship, undefined),
    case ias_demo_store:get(SourceId) of
        {ok, _Object} -> ias_html:text(<<"not linked yet">>);
        not_found -> ias_html:text(SourceId)
    end.
