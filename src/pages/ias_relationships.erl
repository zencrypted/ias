-module(ias_relationships).
-export([event/1, relationship_edge/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    render(default_filters());
event({unlink_relationship, RelationshipId}) ->
    _ = ias_relationship_link:unlink(RelationshipId),
    render(default_filters());
event({replace_certificate, DeviceId}) ->
    _ = ias_certificate_replacement:replace(DeviceId),
    render(default_filters());
event({relationship_filters, Filters}) ->
    render(normalize_filters(Filters));
event({relationship_filter_toggle, Filter, Category}) ->
    render(toggle_filter(Filter, Category));
event({relationship_filter, Filter}) ->
    render(normalize_filters(Filter));
event(_) ->
    ok.

render() ->
    render(default_filters()).

render(Filter) ->
    %% Use Nitro DOM operations instead of raw innerHTML injection.
    %% Raw innerHTML makes rendered #link postbacks appear in the DOM,
    %% but their client-side actions are not reliably wired.
    nitro:clear(stand),
    nitro:insert_bottom(stand, content(Filter)).

content(Filter) ->
    Summary = ias_relationship_graph:summary(),
    Categories = ias_relationship_graph:categorized_relationships(),
    KnownRelationships = maps:get(known, Categories, []),
    VisibleKnownRelationships = filter_relationships(KnownRelationships, Filter),
    Report = ias_relationship_graph:graph_consistency_report(),
    Analysis = ias_graph_analysis:report(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Relationship Explorer")},
        #p{body = ias_html:text("Read-only IAS object graph inspection.")},
        summary_panel(Summary),
        relationship_filter_panel(Filter, length(VisibleKnownRelationships), length(KnownRelationships)),
        #h3{body = ias_html:text("Relationships")},
        relationship_table(VisibleKnownRelationships, <<"not linked yet">>),
        #h3{body = ias_html:text("Unknown Relationships")},
        relationship_table(maps:get(unknown, Categories, []), <<"not linked yet">>),
        #h3{body = ias_html:text("Broken Relationships")},
        broken_relationship_table(maps:get(broken, Categories, [])),
        #h3{body = ias_html:text("Graph Consistency Checks")},
        consistency_table(Report),
        #h3{body = ias_html:text("GRAPH ANALYSIS")},
        analysis_table(Analysis)
    ]}.


relationship_filter_panel(Filter0, VisibleCount, TotalCount) ->
    Filter = normalize_filters(Filter0),
    #panel{class = <<"ias-relationship-filter">>, body = [
        #h3{body = ias_html:text("Graph Filters")},
        #p{body = ias_html:join([
            <<"Showing ">>, VisibleCount, <<" of ">>, TotalCount,
            <<" known relationships. Verification and audit history is hidden unless explicitly enabled.">>
        ])},
        #panel{class = <<"ias-filter-actions ias-filter-checkboxes">>, body = [
            relationship_filter_checkbox(users, "Users", Filter),
            relationship_filter_checkbox(devices, "Devices", Filter),
            relationship_filter_checkbox(certificates, "Certificates", Filter),
            relationship_filter_checkbox(vpn_services, "VPN Services", Filter),
            relationship_filter_checkbox(security_policies, "Security Profiles / Policies", Filter),
            relationship_filter_checkbox(audit, "Audit / Verification History", Filter),
            relationship_filter_checkbox(all, "All Relationships", Filter)
        ]}
    ]}.

relationship_filter_checkbox(Category, Label, Filter) ->
    Checked = filter_checked(Category, Filter),
    CheckText = case Checked of
                    true -> <<"☑ ">>;
                    false -> <<"☐ ">>
                end,
    Class = case Checked of
                true -> <<"button sgreen ias-filter-checkbox">>;
                false -> <<"button ias-filter-checkbox">>
            end,
    #link{class = Class,
          body = ias_html:join([CheckText, Label]),
          postback = {relationship_filter_toggle, Filter, Category}}.

filter_checked(all, Filter) ->
    lists:member(all, normalize_filters(Filter));
filter_checked(Category, Filter) ->
    Normalized = normalize_filters(Filter),
    lists:member(all, Normalized) orelse lists:member(Category, Normalized).

toggle_filter(Filter0, all) ->
    Filter = normalize_filters(Filter0),
    case lists:member(all, Filter) of
        true -> default_filters();
        false -> [all]
    end;
toggle_filter(Filter0, Category) ->
    Filter = lists:delete(all, normalize_filters(Filter0)),
    Toggled = case lists:member(Category, Filter) of
                  true -> lists:delete(Category, Filter);
                  false -> [Category | Filter]
              end,
    case Toggled of
        [] -> default_filters();
        _ -> lists:sort(Toggled)
    end.

default_filters() ->
    [certificates, devices, security_policies, users, vpn_services].

normalize_filters(all) -> [all];
normalize_filters(operational) -> default_filters();
normalize_filters(audit) -> [audit];
normalize_filters(users) -> [users];
normalize_filters(devices) -> [devices];
normalize_filters(vpn_services) -> [vpn_services];
normalize_filters(certificates) -> [certificates];
normalize_filters(security_policies) -> [security_policies];
normalize_filters(Filter) when is_list(Filter) ->
    Allowed = [all, users, devices, certificates, vpn_services, security_policies, audit],
    Normalized = lists:usort([Item || Item <- Filter, lists:member(Item, Allowed)]),
    case Normalized of
        [] -> default_filters();
        _ -> Normalized
    end;
normalize_filters(_) ->
    default_filters().

filter_relationships(Relationships, Filter0) ->
    Filter = normalize_filters(Filter0),
    case lists:member(all, Filter) of
        true -> Relationships;
        false -> [Relationship || Relationship <- Relationships,
                                  relationship_matches_filters(Relationship, Filter)]
    end.

relationship_matches_filters(Relationship, Filter) ->
    Audit = audit_relationship(Relationship),
    (lists:member(audit, Filter) andalso Audit) orelse
        ((not Audit) andalso relationship_matches_operational_filters(Relationship, Filter)).

relationship_matches_operational_filters(Relationship, Filter) ->
    (lists:member(users, Filter) andalso relationship_has_kind(Relationship, user)) orelse
        (lists:member(devices, Filter) andalso relationship_has_kind(Relationship, device)) orelse
        (lists:member(vpn_services, Filter) andalso relationship_has_kind(Relationship, vpn_service)) orelse
        (lists:member(certificates, Filter) andalso relationship_has_certificate_kind(Relationship)) orelse
        (lists:member(security_policies, Filter) andalso relationship_has_security_kind(Relationship)).

audit_relationship(Relationship) ->
    RelationType = maps:get(relation_type, Relationship, undefined),
    SourceKind = maps:get(source_kind, Relationship, undefined),
    TargetKind = maps:get(target_kind, Relationship, undefined),
    lists:member(RelationType, [verified_by, revoked_by]) orelse
        lists:member(SourceKind, [verification, certificate_revocation]) orelse
        lists:member(TargetKind, [verification, certificate_revocation]).

relationship_has_kind(Relationship, Kind) ->
    maps:get(source_kind, Relationship, undefined) =:= Kind orelse
        maps:get(target_kind, Relationship, undefined) =:= Kind.

relationship_has_certificate_kind(Relationship) ->
    CertificateKinds = [certificate,
                        cmp_enrollment_result,
                        certificate_enrollment,
                        certificate_replacement,
                        certificate_revocation],
    lists:member(maps:get(source_kind, Relationship, undefined), CertificateKinds) orelse
        lists:member(maps:get(target_kind, Relationship, undefined), CertificateKinds).

relationship_has_security_kind(Relationship) ->
    relationship_has_kind(Relationship, security_profile) orelse
        relationship_has_kind(Relationship, security_policy).

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
           body = canonical_relationship_tree(Relationships)}.

canonical_relationship_tree(Relationships) ->
    SourceGroups = group_relationships_by_source(Relationships),
    [relationship_source_block(Source, Items)
     || {Source, Items} <- SourceGroups].

group_relationships_by_source(Relationships) ->
    Sorted = lists:sort(fun relationship_before/2, Relationships),
    group_relationships_by_source(Sorted, []).

group_relationships_by_source([], Acc) ->
    lists:reverse(Acc);
group_relationships_by_source([Relationship | Rest], []) ->
    Source = relationship_source(Relationship),
    group_relationships_by_source(Rest, [{Source, [Relationship]}]);
group_relationships_by_source([Relationship | Rest], [{Source, Items} | AccRest] = Acc) ->
    CurrentSource = relationship_source(Relationship),
    case CurrentSource =:= Source of
        true ->
            group_relationships_by_source(Rest, [{Source, Items ++ [Relationship]} | AccRest]);
        false ->
            group_relationships_by_source(Rest, [{CurrentSource, [Relationship]} | Acc])
    end.

relationship_source(Relationship) ->
    {maps:get(source_kind, Relationship, undefined),
     maps:get(source_id, Relationship, undefined)}.

relationship_source_block({SourceKind, SourceId}, Relationships) ->
    #details{class = <<"ias-tree-source">>, open = true, body = [
        #summary{class = <<"ias-tree-source-title">>, body = [
            ias_relationship_ui:object_ref(SourceKind, SourceId),
            ias_html:text(" "),
            #span{class = <<"ias-tree-count">>,
                  body = ias_html:join(["(", length(Relationships), ")"])}
        ]},
        #panel{class = <<"ias-tree-children">>,
               body = relationship_relation_groups(Relationships)}
    ]}.

relationship_relation_groups(Relationships) ->
    RelationGroups = group_relationships_by_relation(Relationships),
    [relationship_relation_block(RelationType, Items)
     || {RelationType, Items} <- RelationGroups].

group_relationships_by_relation(Relationships) ->
    Sorted = lists:sort(fun relationship_before/2, Relationships),
    group_relationships_by_relation(Sorted, []).

group_relationships_by_relation([], Acc) ->
    lists:reverse(Acc);
group_relationships_by_relation([Relationship | Rest], []) ->
    RelationType = maps:get(relation_type, Relationship, undefined),
    group_relationships_by_relation(Rest, [{RelationType, [Relationship]}]);
group_relationships_by_relation([Relationship | Rest], [{RelationType, Items} | AccRest] = Acc) ->
    CurrentRelationType = maps:get(relation_type, Relationship, undefined),
    case CurrentRelationType =:= RelationType of
        true ->
            group_relationships_by_relation(Rest, [{RelationType, Items ++ [Relationship]} | AccRest]);
        false ->
            group_relationships_by_relation(Rest, [{CurrentRelationType, [Relationship]} | Acc])
    end.

relationship_relation_block(RelationType, Relationships) ->
    Representative = hd(Relationships),
    #details{class = <<"ias-tree-relation">>, open = true, body = [
        #summary{class = <<"ias-tree-relation-title">>, body = [
            ias_html:text(RelationType),
            ias_html:text(" "),
            relation_badge(Representative),
            ias_html:text(" "),
            #span{class = <<"ias-tree-count">>,
                  body = ias_html:join(["(", length(Relationships), ")"])}
        ]},
        #panel{class = <<"ias-tree-targets">>,
               body = [relationship_target_line(Relationship)
                       || Relationship <- Relationships]}
    ]}.

relationship_target_line(Relationship) ->
    #panel{class = <<"ias-tree-target">>, body = [
        ias_relationship_ui:object_ref(maps:get(target_kind, Relationship, undefined),
                                       maps:get(target_id, Relationship, undefined)),
        relationship_inline_action(Relationship)
    ]}.

relation_badge(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            #span{class = <<"ias-tree-badge ias-tree-badge-editable">>,
                  body = ias_html:text("editable")};
        false ->
            ias_relationship_ui:status_badge(Relationship)
    end.

relationship_inline_action(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            [ias_html:text(" "), ias_relationship_ui:action(Relationship)];
        false ->
            []
    end.

relationship_edge(Relationship) ->
    relationship_row(Relationship).

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
    {stable_text(maps:get(source_kind, Relationship, undefined)),
     stable_text(maps:get(source_id, Relationship, undefined)),
     stable_text(maps:get(relation_type, Relationship, undefined)),
     stable_text(maps:get(target_kind, Relationship, undefined)),
     stable_text(maps:get(target_id, Relationship, undefined)),
     stable_text(maps:get(created_at, Relationship, <<>>)),
     stable_text(maps:get(id, Relationship, <<>>))}.

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
