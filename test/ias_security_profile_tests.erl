-module(ias_security_profile_tests).
-include_lib("eunit/include/eunit.hrl").

standard_profile_rendering_test() ->
    {ok, Standard} = ias_security_profile:policy(<<"standard">>),

    ?assertEqual(<<"Standard">>, ias_security_profile:profile_label(Standard)),
    ?assertEqual(<<"Disabled">>, ias_security_profile:device_lock_label(Standard)),
    ?assertEqual(<<"Optional">>, ias_security_profile:two_factor_label(Standard)),
    ?assertEqual(<<"Preview Only">>, ias_security_profile:enforcement_label(Standard)).

high_security_profile_rendering_test() ->
    {ok, HighSecurity} = ias_security_profile:policy(<<"high_security">>),

    ?assertEqual(<<"High Security">>, ias_security_profile:profile_label(HighSecurity)),
    ?assertEqual(<<"Enabled">>, ias_security_profile:device_lock_label(HighSecurity)),
    ?assertEqual(<<"Required">>, ias_security_profile:two_factor_label(HighSecurity)),
    ?assertEqual(<<"Preview Only">>, ias_security_profile:enforcement_label(HighSecurity)).

security_policy_linking_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_policy_link">>}),

    {ok, Relationship} = ias_relationship_link:create(uses_security_policy,
                                                      maps:get(id, Device),
                                                      <<"high_security">>),
    Applied = ias_security_profile:applied_policy(Device),

    ?assertEqual(relationship, maps:get(kind, Relationship)),
    ?assertEqual(uses_security_policy, maps:get(relation_type, Relationship)),
    ?assertEqual(device, maps:get(source_kind, Relationship)),
    ?assertEqual(maps:get(id, Device), maps:get(source_id, Relationship)),
    ?assertEqual(security_policy, maps:get(target_kind, Relationship)),
    ?assertEqual(<<"high_security">>, maps:get(target_id, Relationship)),
    ?assertEqual(<<"high_security">>, maps:get(id, Applied)).

policy_effect_generation_test() ->
    {ok, Standard} = ias_security_profile:policy(<<"standard">>),
    {ok, HighSecurity} = ias_security_profile:policy(<<"high_security">>),

    ?assertEqual([<<"Multiple devices allowed">>, <<"2FA optional">>],
                 ias_security_profile:effects(Standard)),
    ?assertEqual([<<"Device binding expected">>, <<"2FA required">>],
                 ias_security_profile:effects(HighSecurity)).

security_policy_candidates_are_available_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_policy_candidates">>}),
    Preview = ias_relationship_preview:preview(Device),

    ?assertEqual([<<"high_security">>, <<"standard">>],
                 lists:sort(ids(maps:get(suggested_security_policies, Preview)))).

security_profile_object_metadata_test() ->
    {ok, Profile} = ias_security_profile:profile(<<"administrator">>),

    ?assertEqual(security_profile, maps:get(kind, Profile)),
    ?assertEqual(administrator, maps:get(id, Profile)),
    ?assertEqual(admin, maps:get(certificate_role, Profile)),
    ?assertEqual([vpn, ias], maps:get(services, Profile)),
    ?assertEqual(elevated, maps:get(trust_level, Profile)),
    ?assertEqual(enabled, maps:get(device_lock, Profile)),
    ?assertEqual(required, maps:get(two_factor, Profile)).

security_profile_comparison_test() ->
    Rows = ias_security_profile:comparison(),
    [Administrator] = [Row || Row <- Rows, maps:get(id, Row) =:= administrator],
    [DefaultUser] = [Row || Row <- Rows, maps:get(id, Row) =:= default_user],

    ?assertEqual(admin, maps:get(role, Administrator)),
    ?assertEqual(elevated, maps:get(trust_level, Administrator)),
    ?assertEqual(enabled, maps:get(device_lock, Administrator)),
    ?assertEqual(required, maps:get(two_factor, Administrator)),
    ?assertEqual(peer, maps:get(role, DefaultUser)),
    ?assertEqual(standard, maps:get(trust_level, DefaultUser)),
    ?assertEqual(disabled, maps:get(device_lock, DefaultUser)),
    ?assertEqual(optional, maps:get(two_factor, DefaultUser)).

security_profile_relationship_preview_test() ->
    ias_demo_store:clear(),
    {ok, Profile} = ias_security_profile:profile(<<"default_user">>),
    _DemoDevice = ias_demo_store:add_device(#{id => <<"device_profile_demo">>,
                                              profile_id => default_user}),
    _DemoCertificate = ias_demo_store:add_certificate(#{id => <<"cert_profile_demo">>,
                                                       profile_id => default_user}),
    Relationships = ias_security_profile:relationship_preview(Profile),

    ?assert(lists:member(bob, ids(maps:get(users, Relationships)))),
    ?assertNot(lists:member(workstation1, ids(maps:get(devices, Relationships)))),
    ?assert(lists:member(<<"device_profile_demo">>, ids(maps:get(devices, Relationships)))),
    ?assertNot(lists:member(cert3, ids(maps:get(certificates, Relationships)))),
    ?assert(lists:member(<<"cert_profile_demo">>, ids(maps:get(certificates, Relationships)))).

security_profile_relationship_preview_skips_unresolved_static_references_test() ->
    ias_demo_store:clear(),

    {ok, Certificate} = ias_certificate_issue_demo:issue(bob, <<"bob-vpn">>,
                                                         ias_demo_data:profiles()),
    {ok, Profile} = ias_security_profile:profile(<<"default_user">>),
    Relationships = ias_security_profile:relationship_preview(Profile),

    ?assertEqual([], ids(maps:get(devices, Relationships))),
    ?assertEqual([maps:get(id, Certificate)], ids(maps:get(certificates, Relationships))).

security_profile_relationship_engine_link_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_profile_relationship">>}),
    {ok, Relationship} = ias_relationship_link:create(uses_security_profile,
                                                      maps:get(id, Device),
                                                      <<"default_user">>),
    {ok, Profile} = ias_security_profile:profile(<<"default_user">>),
    Relationships = ias_security_profile:relationship_preview(Profile),

    ?assertEqual(uses_security_profile, maps:get(relation_type, Relationship)),
    ?assertEqual(security_profile, maps:get(target_kind, Relationship)),
    ?assertEqual(default_user, maps:get(target_id, Relationship)),
    ?assert(lists:member(maps:get(id, Device), ids(maps:get(devices, Relationships)))).

ids(Objects) ->
    [maps:get(id, Object) || Object <- Objects].
