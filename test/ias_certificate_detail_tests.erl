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
