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

ids(Objects) ->
    [maps:get(id, Object) || Object <- Objects].
