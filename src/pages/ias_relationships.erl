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
        consistency_table(Report)
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
