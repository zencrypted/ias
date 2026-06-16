-module(ias_relationships).
-export([event/1, relationship_edge/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    render();
event({unlink_relationship, RelationshipId}) ->
    _ = ias_relationship_link:unlink(RelationshipId),
    render();
event(_) ->
    ok.

render() ->
    %% Use Nitro DOM operations instead of raw innerHTML injection.
    %% Raw innerHTML makes rendered #link postbacks appear in the DOM,
    %% but their client-side actions are not reliably wired.
    nitro:clear(stand),
    nitro:insert_bottom(stand, content()).

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
           body = grouped_relationship_sections(Relationships)}.

grouped_relationship_sections(Relationships) ->
    Sorted = lists:sort(fun relationship_before/2, Relationships),
    Groups = [
        {<<"Editable Relationships">>, editable,
         [Relationship || Relationship <- Sorted,
                          relationship_group(Relationship) =:= editable]},
        {<<"Lifecycle Relationships">>, lifecycle,
         [Relationship || Relationship <- Sorted,
                          relationship_group(Relationship) =:= lifecycle]},
        {<<"Audit Relationships">>, audit,
         [Relationship || Relationship <- Sorted,
                          relationship_group(Relationship) =:= audit]},
        {<<"Protected Relationships">>, protected,
         [Relationship || Relationship <- Sorted,
                          relationship_group(Relationship) =:= protected]}
    ],
    [relationship_group_section(Title, Group, Items)
     || {Title, Group, Items} <- Groups, Items =/= []].

relationship_group_section(Title, _Group, Relationships) ->
    #panel{class = <<"ias-relationship-group">>, body = [
        #h3{body = ias_html:join([Title, <<" (">>, length(Relationships), <<")">>])},
        #table{class = <<"ias-table">>,
               body = #tbody{body = [relationship_group_header() |
                                      [relationship_row(Relationship)
                                       || Relationship <- Relationships]]}}
    ]}.

relationship_group_header() ->
    #tr{cells = [
        #th{body = ias_html:text("Source")},
        #th{body = ias_html:text("Relationship")},
        #th{body = ias_html:text("Target")},
        #th{body = ias_html:text("Status")},
        #th{body = ias_html:text("Action")}
    ]}.

relationship_row(Relationship) ->
    #tr{cells = [
        #td{body = ias_relationship_ui:object_entry(source, Relationship)},
        #td{body = ias_html:text(maps:get(relation_type, Relationship, undefined))},
        #td{body = ias_relationship_ui:object_entry(target, Relationship)},
        #td{body = relationship_status(Relationship)},
        #td{body = relationship_action(Relationship)}
    ]}.

relationship_status(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true -> ias_html:text("editable");
        false -> ias_relationship_ui:status_badge(Relationship)
    end.

relationship_action(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true -> ias_relationship_ui:action(Relationship);
        false -> ias_html:text("-")
    end.

relationship_before(A, B) ->
    relationship_sort_key(A) =< relationship_sort_key(B).

relationship_sort_key(Relationship) ->
    {relationship_group_order(relationship_group(Relationship)),
     stable_text(maps:get(source_kind, Relationship, undefined)),
     stable_text(maps:get(source_id, Relationship, undefined)),
     stable_text(maps:get(relation_type, Relationship, undefined)),
     stable_text(maps:get(target_kind, Relationship, undefined)),
     stable_text(maps:get(target_id, Relationship, undefined)),
     stable_text(maps:get(created_at, Relationship, <<>>)),
     stable_text(maps:get(id, Relationship, <<>>))}.

relationship_group(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            editable;
        false ->
            protected_group(maps:get(relation_type, Relationship, undefined))
    end.

protected_group(issues) -> lifecycle;
protected_group(issued_certificate) -> lifecycle;
protected_group(verified_by) -> audit;
protected_group(_) -> protected.

relationship_group_order(editable) -> 1;
relationship_group_order(lifecycle) -> 2;
relationship_group_order(audit) -> 3;
relationship_group_order(protected) -> 4.

stable_text(Value) when is_binary(Value) -> Value;
stable_text(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
stable_text(Value) when is_integer(Value) -> integer_to_binary(Value);
stable_text(Value) -> ias_html:text(Value).

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
    #panel{class = <<"ias-analysis">>,
           body = ias_graph_analysis_details:warning_blocks(Analysis)}.

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
