-module(ias_certificate_issue_demo_tests).
-include_lib("eunit/include/eunit.hrl").

demo_certificate_issue_stores_certificate_metadata_test() ->
    ias_demo_store:clear(),

    {ok, Certificate} = ias_certificate_issue_demo:issue(alice, <<"peer_new">>,
                                                         ias_demo_data:profiles()),

    ?assertEqual(certificate, maps:get(kind, Certificate)),
    ?assertEqual(certificate_issue_demo, maps:get(source, Certificate)),
    ?assertEqual(alice, maps:get(user, Certificate)),
    ?assertEqual(administrator, maps:get(profile_id, Certificate)),
    ?assertEqual(<<"peer_new">>, maps:get(subject_cn, Certificate)),
    ?assertEqual(admin, maps:get(role, Certificate)),
    ?assertEqual([vpn, ias], maps:get(services, Certificate)),
    ?assertEqual([admin, issue_certificates, revoke_certificates],
                 maps:get(attributes, Certificate)),
    ?assertEqual(elevated, maps:get(trust_level, Certificate)),
    ?assertEqual(enabled, maps:get(device_lock, Certificate)),
    ?assertEqual(required, maps:get(two_factor, Certificate)),
    ?assert(maps:is_key(created_at, Certificate)),
    ?assertEqual(false, maps:get(private_key_stored, Certificate)),
    ?assertEqual(false, maps:get(certificate_body_stored, Certificate)).

demo_certificate_issue_creates_relationships_test() ->
    ias_demo_store:clear(),

    {ok, Certificate} = ias_certificate_issue_demo:issue(alice, <<"peer_new">>,
                                                         ias_demo_data:profiles()),
    CertificateId = maps:get(id, Certificate),
    Relationships = ias_demo_store:relationships(),

    ?assert(lists:any(fun(Relationship) ->
        maps:get(relation_type, Relationship) =:= issued_certificate andalso
        maps:get(source_kind, Relationship) =:= user andalso
        maps:get(source_id, Relationship) =:= alice andalso
        maps:get(target_kind, Relationship) =:= certificate andalso
        maps:get(target_id, Relationship) =:= CertificateId
    end, Relationships)),
    ?assert(lists:any(fun(Relationship) ->
        maps:get(relation_type, Relationship) =:= issued_certificate andalso
        maps:get(source_kind, Relationship) =:= security_profile andalso
        maps:get(source_id, Relationship) =:= administrator andalso
        maps:get(target_kind, Relationship) =:= certificate andalso
        maps:get(target_id, Relationship) =:= CertificateId
    end, Relationships)).

security_profile_preview_shows_issued_certificate_test() ->
    ias_demo_store:clear(),

    {ok, Certificate} = ias_certificate_issue_demo:issue(alice, <<"peer_new">>,
                                                         ias_demo_data:profiles()),
    {ok, Profile} = ias_security_profile:profile(<<"administrator">>),
    Relationships = ias_security_profile:relationship_preview(Profile),

    ?assert(lists:member(maps:get(id, Certificate),
                         ids(maps:get(certificates, Relationships)))).

security_profile_issued_certificates_are_deduplicated_test() ->
    ias_demo_store:clear(),

    {ok, Certificate} = ias_certificate_issue_demo:issue(alice, <<"peer_new">>,
                                                         ias_demo_data:profiles()),
    {ok, Profile} = ias_security_profile:profile(<<"administrator">>),
    Relationships = ias_security_profile:relationship_preview(Profile),
    CertificateId = maps:get(id, Certificate),
    CertificateIds = ids(maps:get(certificates, Relationships)),

    ?assertEqual([CertificateId], [Id || Id <- CertificateIds, Id =:= CertificateId]).

user_relationships_show_issued_certificate_test() ->
    ias_demo_store:clear(),

    {ok, Certificate} = ias_certificate_issue_demo:issue(alice, <<"peer_new">>,
                                                         ias_demo_data:profiles()),
    {ok, User} = ias_demo_store:get(alice),
    Relationships = ias_relationship_link:relationships_for(User),

    ?assert(lists:any(fun(Relationship) ->
        maps:get(relation_type, Relationship) =:= issued_certificate andalso
        maps:get(target_id, Relationship) =:= maps:get(id, Certificate)
    end, Relationships)).

ids(Objects) ->
    [maps:get(id, Object) || Object <- Objects].
