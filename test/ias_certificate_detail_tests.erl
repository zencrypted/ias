-module(ias_certificate_detail_tests).
-include_lib("eunit/include/eunit.hrl").

certificate_class_detects_imported_enrollment_and_issued_sources_test() ->
    ?assertEqual(<<"Imported OVPN Certificate">>,
                 ias_certificate_detail:certificate_class(#{kind => certificate,
                                                            source => ovpn_demo_import,
                                                            id => <<"some_id">>})),
    ?assertEqual(<<"Enrollment Certificate">>,
                 ias_certificate_detail:certificate_class(#{kind => certificate,
                                                            source => cmp_demo_enrollment,
                                                            id => <<"some_id">>})),
    ?assertEqual(<<"Issued Identity Certificate">>,
                 ias_certificate_detail:certificate_class(#{kind => certificate,
                                                            source => certificate_issue_demo,
                                                            id => <<"some_id">>})).

certificate_class_falls_back_to_id_prefix_test() ->
    ?assertEqual(<<"Imported OVPN Certificate">>,
                 ias_certificate_detail:certificate_class(#{kind => certificate,
                                                            id => <<"ovpn_import_1_certificate">>})),
    ?assertEqual(<<"Enrollment Certificate">>,
                 ias_certificate_detail:certificate_class(#{kind => certificate,
                                                            id => <<"cmp_enrollment_1_certificate">>})),
    ?assertEqual(<<"Issued Identity Certificate">>,
                 ias_certificate_detail:certificate_class(#{kind => certificate,
                                                            id => <<"issued_certificate_alice_1">>})).

certificate_class_note_explains_enrollment_context_test() ->
    Note = ias_certificate_detail:certificate_class_note(#{kind => certificate,
                                                           source => cmp_demo_enrollment,
                                                           id => <<"cmp_enrollment_1_certificate">>}),
    ?assertMatch({_, _}, binary:match(Note, <<"issue it to a user/security profile">>)).

manual_ca_object_is_ca_certificate_test() ->
    Certificate = #{kind => certificate,
                    source => ca_certificate,
                    material_type => ca_certificate,
                    certificate_role => ca_certificate,
                    id => <<"manual_ca_certificate_1">>},

    ?assertEqual(<<"CA Certificate">>,
                 ias_certificate_detail:certificate_class(Certificate)).

certificate_role_has_highest_priority_test() ->
    Certificate = #{kind => certificate,
                    source => certificate_issue_demo,
                    material_type => client_certificate,
                    certificate_role => ca_certificate,
                    id => <<"issued_certificate_alice_1">>},

    ?assertEqual(<<"CA Certificate">>,
                 ias_certificate_detail:certificate_class(Certificate)).

material_type_classifies_ca_certificate_test() ->
    Certificate = #{kind => certificate,
                    source => certificate_issue_demo,
                    material_type => ca_certificate,
                    id => <<"issued_certificate_alice_1">>},

    ?assertEqual(<<"CA Certificate">>,
                 ias_certificate_detail:certificate_class(Certificate)).

source_classifies_ca_certificate_test() ->
    Certificate = #{kind => certificate,
                    source => ca_certificate,
                    id => <<"some_id">>},

    ?assertEqual(<<"CA Certificate">>,
                 ias_certificate_detail:certificate_class(Certificate)).

manual_ca_id_prefix_falls_back_to_ca_certificate_test() ->
    Certificate = #{kind => certificate,
                    id => <<"manual_ca_certificate_1782001_1">>},

    ?assertEqual(<<"CA Certificate">>,
                 ias_certificate_detail:certificate_class(Certificate)).

ca_certificate_note_explains_material_boundary_test() ->
    Note = ias_certificate_detail:certificate_class_note(#{kind => certificate,
                                                           source => ca_certificate,
                                                           id => <<"manual_ca_certificate_1">>}),

    ?assertMatch({_, _}, binary:match(Note, <<"Operator-registered CA trust anchor">>)),
    ?assertMatch({_, _}, binary:match(Note, <<"stored separately from Demo State metadata">>)).

existing_certificate_classes_are_unchanged_test() ->
    ?assertEqual(<<"Issued Identity Certificate">>,
                 ias_certificate_detail:certificate_class(#{kind => certificate,
                                                            source => certificate_issue_demo,
                                                            id => <<"issued_certificate_alice_1">>})),
    ?assertEqual(<<"Enrollment Certificate">>,
                 ias_certificate_detail:certificate_class(#{kind => certificate,
                                                            source => cmp_demo_enrollment,
                                                            id => <<"cmp_enrollment_1_certificate">>})),
    ?assertEqual(<<"Imported OVPN Certificate">>,
                 ias_certificate_detail:certificate_class(#{kind => certificate,
                                                            source => ovpn_demo_import,
                                                            id => <<"ovpn_import_1_certificate">>})).
