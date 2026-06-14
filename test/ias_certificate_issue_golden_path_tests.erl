-module(ias_certificate_issue_golden_path_tests).
-include_lib("eunit/include/eunit.hrl").

alice_administrator_golden_path_test() ->
    ias_demo_store:clear(),

    {ok, Certificate} = ias_certificate_issue_demo:issue(alice, <<"alice-vpn">>,
                                                         ias_demo_data:profiles()),
    CertificateId = maps:get(id, Certificate),

    {ok, User} = ias_demo_store:get(alice),
    ?assert(lists:member(CertificateId, ids(ias_user_detail:issued_certificates(User)))),

    {ok, Profile} = ias_security_profile:profile(administrator),
    ProfileRelationships = ias_security_profile:relationship_preview(Profile),
    ?assert(lists:member(CertificateId, ids(maps:get(certificates, ProfileRelationships)))),

    Metadata = ias_certificate_detail:metadata(Certificate),
    ?assertEqual(alice, maps:get(issued_user_id, Metadata)),
    ?assertEqual(<<"Alice">>, maps:get(issued_user, Metadata)),
    ?assertEqual(administrator, maps:get(source_security_profile, Metadata)),
    ?assertEqual(admin, maps:get(role, Metadata)),
    ?assertEqual([vpn, ias], maps:get(services, Metadata)),
    ?assertEqual(elevated, maps:get(trust_level, Metadata)),
    ?assertEqual(enabled, maps:get(device_lock, Metadata)),
    ?assertEqual(required, maps:get(two_factor, Metadata)),

    Policy = ias_certificate_detail:security_policy(Certificate),
    ?assertEqual(administrator, maps:get(profile, Policy)),
    ?assertEqual(enabled, maps:get(device_lock, Policy)),
    ?assertEqual(required, maps:get(two_factor, Policy)),
    ?assertEqual([<<"Device binding expected">>, <<"2FA required">>],
                 ias_security_profile:effects(Policy)),
    ?assertEqual(allow, maps:get(decision, ias_policy:evaluate_service(Profile, ias))).

bob_default_user_golden_path_test() ->
    ias_demo_store:clear(),

    {ok, Certificate} = ias_certificate_issue_demo:issue(bob, <<"bob-vpn">>,
                                                         ias_demo_data:profiles()),
    CertificateId = maps:get(id, Certificate),

    {ok, User} = ias_demo_store:get(bob),
    ?assert(lists:member(CertificateId, ids(ias_user_detail:issued_certificates(User)))),

    {ok, Profile} = ias_security_profile:profile(default_user),
    ProfileRelationships = ias_security_profile:relationship_preview(Profile),
    ?assert(lists:member(CertificateId, ids(maps:get(certificates, ProfileRelationships)))),

    Metadata = ias_certificate_detail:metadata(Certificate),
    ?assertEqual(bob, maps:get(issued_user_id, Metadata)),
    ?assertEqual(<<"Bob">>, maps:get(issued_user, Metadata)),
    ?assertEqual(default_user, maps:get(source_security_profile, Metadata)),
    ?assertEqual(peer, maps:get(role, Metadata)),
    ?assertEqual([vpn], maps:get(services, Metadata)),
    ?assertEqual(standard, maps:get(trust_level, Metadata)),
    ?assertEqual(disabled, maps:get(device_lock, Metadata)),
    ?assertEqual(optional, maps:get(two_factor, Metadata)),

    Policy = ias_certificate_detail:security_policy(Certificate),
    ?assertEqual(default_user, maps:get(profile, Policy)),
    ?assertEqual(disabled, maps:get(device_lock, Policy)),
    ?assertEqual(optional, maps:get(two_factor, Policy)),
    ?assertEqual(deny, maps:get(decision, ias_policy:evaluate_service(Profile, ias))).

ids(Objects) ->
    [maps:get(id, Object) || Object <- Objects].
