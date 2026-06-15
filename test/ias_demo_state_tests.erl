-module(ias_demo_state_tests).
-include_lib("eunit/include/eunit.hrl").

export_demo_state_roundtrip_test() ->
    ias_demo_store:clear(),
    setup_demo_graph(),
    BeforeCategories = ias_relationship_graph:categorized_relationships(),
    BeforeAnalysis = warning_counts(ias_graph_analysis:report()),
    Json = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    ?assertEqual(0, maps:get(total_records, ias_demo_state:summary())),

    Result = ias_demo_state:import(Json),
    AfterCategories = ias_relationship_graph:categorized_relationships(),
    AfterAnalysis = warning_counts(ias_graph_analysis:report()),

    ?assertEqual(3, maps:get(imported_objects, Result)),
    ?assertEqual(2, maps:get(imported_relationships, Result)),
    ?assertEqual(0, maps:get(skipped_invalid_records, Result)),
    ?assertEqual(length(maps:get(known, BeforeCategories)),
                 length(maps:get(known, AfterCategories))),
    ?assertEqual([], maps:get(unknown, AfterCategories)),
    ?assertEqual([], maps:get(broken, AfterCategories)),
    ?assertEqual(BeforeAnalysis, AfterAnalysis).

clear_demo_state_test() ->
    ias_demo_store:clear(),
    setup_demo_graph(),

    ok = ias_demo_state:clear(),

    ?assertEqual(0, maps:get(total_records, ias_demo_state:summary())),
    ?assertEqual([], ias_demo_store:relationships()),
    ?assertMatch([_ | _], ias_demo_store:users()).

import_demo_state_restores_relationships_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_demo_graph(),
    Json = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    Result = ias_demo_state:import(Json),

    ?assertEqual(2, maps:get(imported_relationships, Result)),
    ?assert(lists:any(fun(Relationship) ->
        maps:get(relation_type, Relationship) =:= uses_certificate andalso
        maps:get(source_id, Relationship) =:= maps:get(id, Device) andalso
        maps:get(target_id, Relationship) =:= maps:get(id, Certificate)
    end, ias_demo_store:relationships())),
    ?assertEqual([], maps:get(broken, ias_relationship_graph:categorized_relationships())).

import_demo_state_rejects_malformed_snapshot_test() ->
    ias_demo_store:clear(),

    ?assertEqual({error, malformed_snapshot}, ias_demo_state:import(<<"{not-json">>)),
    ?assertEqual({error, invalid_snapshot_format},
                 ias_demo_state:import(<<"{\"format\":\"wrong\",\"objects\":[],\"relationships\":[]}">>)),
    ?assertEqual(0, maps:get(total_records, ias_demo_state:summary())).

export_demo_state_does_not_export_private_material_test() ->
    ias_demo_store:clear(),
    _Certificate = ias_demo_store:add_certificate(#{
        id => <<"secret_certificate">>,
        source => certificate_issue_demo,
        private_key_body => <<"PRIVATE-KEY-BODY">>,
        certificate_pem => <<"CERTIFICATE-PEM-BODY">>,
        csr_body => <<"CSR-BODY">>,
        private_key_stored => true,
        certificate_body_stored => true
    }),

    Json = ias_demo_state:export(),
    Decoded = jiffy:decode(Json, [return_maps]),
    [Exported] = maps:get(<<"objects">>, Decoded),

    ?assertEqual(nomatch, binary:match(Json, <<"PRIVATE-KEY-BODY">>)),
    ?assertEqual(nomatch, binary:match(Json, <<"CERTIFICATE-PEM-BODY">>)),
    ?assertEqual(nomatch, binary:match(Json, <<"CSR-BODY">>)),
    ?assertEqual(false, maps:get(<<"private_key_stored">>, Exported)),
    ?assertEqual(false, maps:get(<<"certificate_body_stored">>, Exported)).

setup_demo_graph() ->
    Device = ias_demo_store:add_device(#{id => <<"state_device">>,
                                         source => ovpn_demo_import,
                                         import_id => <<"state_import">>,
                                         type => <<"vpn-client">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"state_certificate">>,
                                                   source => ovpn_demo_import,
                                                   import_id => <<"state_import">>,
                                                   ca_present => true,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),
    Service = ias_demo_store:add_service(#{id => <<"state_vpn_service">>,
                                           source => ovpn_demo_import,
                                           import_id => <<"state_import">>,
                                           service => openvpn,
                                           remote => <<"example.com:1194">>}),
    {ok, _CertRel} = ias_relationship_link:create(uses_certificate,
                                                  maps:get(id, Device),
                                                  maps:get(id, Certificate)),
    {ok, _ServiceRel} = ias_relationship_link:create(uses_service,
                                                     maps:get(id, Device),
                                                     maps:get(id, Service)),
    #{device => Device,
      certificate => Certificate,
      service => Service}.

warning_counts(Report) ->
    maps:from_list([{Key, length(Value)} || {Key, Value} <- maps:to_list(Report)]).
