-module(ias_relationship_graph_tests).
-include_lib("eunit/include/eunit.hrl").

relationship_type_is_known_test() ->
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(uses_security_profile)),
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(issued_certificate)),
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(uses_certificate)),
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(verified_by)),
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(uses_security_policy)),
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(uses_service)),
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(uses_vpn_service)),
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(issues)),
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(replaced_certificate_by)),
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(old_certificate)),
    ?assertEqual(true, ias_relationship_graph:known_relationship_type(new_certificate)),
    ?assertEqual(false, ias_relationship_graph:known_relationship_type(unknown_relation)).

vpn_service_relationship_is_known_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"graph_vpn_device">>}),
    Service = ias_demo_store:add_service(#{id => <<"graph_vpn_service">>}),
    {ok, Relationship} = ias_relationship_link:create(uses_service,
                                                       maps:get(id, Device),
                                                       maps:get(id, Service)),

    Categories = ias_relationship_graph:categorized_relationships(),

    ?assertEqual([maps:get(id, Relationship)], ids(maps:get(known, Categories))),
    ?assertEqual([], maps:get(unknown, Categories)),
    ?assertEqual([], maps:get(broken, Categories)).

relationship_tree_render_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"tree_device">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"tree_certificate">>}),
    {ok, Relationship} = ias_relationship_link:create(uses_certificate,
                                                       maps:get(id, Device),
                                                       maps:get(id, Certificate)),

    Edge = ias_relationship_graph:tree_edge(Relationship),

    ?assertEqual(<<"tree_device">>, maps:get(source, Edge)),
    ?assertEqual(uses_certificate, maps:get(relation_type, Edge)),
    ?assertEqual(<<"tree_certificate">>, maps:get(target, Edge)).

broken_relationship_detection_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"graph_device">>}),
    Broken = ias_demo_store:add_relationship(#{
        relation_type => uses_certificate,
        source_kind => device,
        source_id => maps:get(id, Device),
        target_kind => certificate,
        target_id => <<"missing_certificate">>
    }),

    Categories = ias_relationship_graph:categorized_relationships(),
    BrokenRelationships = maps:get(broken, Categories),

    ?assertEqual([maps:get(id, Broken)], ids(BrokenRelationships)).

empty_relationship_state_test() ->
    ias_demo_store:clear(),

    Categories = ias_relationship_graph:categorized_relationships(),
    Summary = ias_relationship_graph:summary(),

    ?assertEqual([], maps:get(known, Categories)),
    ?assertEqual([], maps:get(unknown, Categories)),
    ?assertEqual([], maps:get(broken, Categories)),
    ?assertEqual(0, maps:get(total_relationships, Summary)).

graph_consistency_report_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"graph_report_device">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"graph_report_certificate">>}),
    {ok, Known} = ias_relationship_link:create(uses_certificate,
                                               maps:get(id, Device),
                                               maps:get(id, Certificate)),
    Unknown = ias_demo_store:add_relationship(#{
        relation_type => experimental_relation,
        source_kind => device,
        source_id => maps:get(id, Device),
        target_kind => certificate,
        target_id => maps:get(id, Certificate)
    }),
    Broken = ias_demo_store:add_relationship(#{
        relation_type => uses_certificate,
        source_kind => device,
        source_id => maps:get(id, Device),
        target_kind => certificate,
        target_id => <<"missing_report_certificate">>
    }),

    Report = ias_relationship_graph:graph_consistency_report(),

    ?assertEqual(3, maps:get(total_relationships, Report)),
    ?assertEqual([maps:get(id, Broken)], ids(maps:get(broken_relationships, Report))),
    ?assertEqual([maps:get(id, Unknown)], ids(maps:get(unknown_relationships, Report))),
    ?assertEqual([<<"missing_report_certificate">>],
                 [maps:get(id, Object) || Object <- maps:get(missing_objects, Report)]),
    ?assert(lists:member(maps:get(id, Known),
                         ids(maps:get(known, ias_relationship_graph:categorized_relationships())))).

ids(Objects) ->
    [maps:get(id, Object) || Object <- Objects].
