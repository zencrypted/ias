-module(ias_certificate_revocation_tests).
-include_lib("eunit/include/eunit.hrl").

revoke_certificate_creates_revocation_object_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(),

    {ok, Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate),
                                                         <<"key compromised">>),

    ?assertEqual(certificate_revocation, maps:get(kind, Revocation)),
    ?assertEqual(maps:get(id, Certificate), maps:get(certificate_id, Revocation)),
    ?assertEqual(<<"key compromised">>, maps:get(reason, Revocation)),
    ?assertEqual(completed, maps:get(status, Revocation)),
    ?assertEqual(certificate_revocation_demo, maps:get(source, Revocation)).

revoke_certificate_creates_revoked_by_relationship_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(),

    {ok, Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),

    ?assert(lists:any(edge(revoked_by, certificate, maps:get(id, Certificate),
                           certificate_revocation, maps:get(id, Revocation)),
                      ias_demo_store:relationships())).

revoked_certificate_is_not_revocable_twice_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(),

    {ok, First} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),
    {ok, Second} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),
    RevokedBy = [Relationship || Relationship <- ias_demo_store:relationships(),
                                 maps:get(relation_type, Relationship, undefined) =:= revoked_by],

    ?assertEqual(maps:get(id, First), maps:get(id, Second)),
    ?assertEqual(1, length(RevokedBy)).

revoked_current_certificate_makes_device_incomplete_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_ready_device(),
    Before = readiness_for(Device),

    {ok, _Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),
    After = readiness_for(Device),

    ?assertEqual(ready, maps:get(status, Before)),
    ?assertEqual(incomplete, maps:get(status, After)),
    ?assertEqual(revoked, maps:get(certificate_revocation, After)),
    ?assert(lists:member(<<"Current Certificate Revoked">>, maps:get(missing, After))),
    ?assert(lists:member(<<"Replace Certificate">>, maps:get(suggested_actions, After))),
    ?assert(lists:member(<<"Link New Certificate">>, maps:get(suggested_actions, After))).

revocation_is_visible_in_relationship_explorer_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(),
    {ok, Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),
    [Relationship] = [Relationship || Relationship <- ias_demo_store:relationships(),
                                      maps:get(relation_type, Relationship, undefined) =:= revoked_by],
    Categories = ias_relationship_graph:categorized_relationships(),
    Html = iolist_to_binary(nitro:render(ias_relationships:relationship_edge(Relationship))),

    ?assert(lists:member(maps:get(id, Relationship),
                         [maps:get(id, Known) || Known <- maps:get(known, Categories)])),
    ?assertMatch({_, _}, binary:match(Html, <<"revoked_by">>)),
    ?assertMatch({_, _}, binary:match(Html, maps:get(id, Revocation))),
    ?assertEqual([], maps:get(unknown, Categories)),
    ?assertEqual([], maps:get(broken, Categories)).

revocation_snapshot_roundtrip_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(),
    {ok, Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),
    Term = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    Result = ias_demo_state:import(Term),

    ?assertMatch({ok, #{kind := certificate_revocation}}, ias_demo_store:get(maps:get(id, Revocation))),
    ?assert(lists:any(edge(revoked_by, certificate, maps:get(id, Certificate),
                           certificate_revocation, maps:get(id, Revocation)),
                      ias_demo_store:relationships())),
    ?assert(maps:get(imported_objects, Result) >= 4),
    ?assert(maps:get(imported_relationships, Result) >= 5),
    ?assertEqual([], maps:get(broken, ias_relationship_graph:categorized_relationships())).

revoked_by_relationship_is_protected_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_ready_device(),
    {ok, _Revocation} = ias_certificate_revocation:revoke(maps:get(id, Certificate)),
    [Relationship] = [Relationship || Relationship <- ias_demo_store:relationships(),
                                      maps:get(relation_type, Relationship, undefined) =:= revoked_by],

    ?assertEqual(false, ias_relationship_link:unlinkable(Relationship)),
    ?assertEqual({error, protected_relationship},
                 ias_relationship_link:unlink(maps:get(id, Relationship))).

setup_ready_device() ->
    Device = ias_demo_store:add_device(#{id => <<"revocation_device">>,
                                         source => ovpn_demo_import,
                                         import_id => <<"revocation_import">>,
                                         type => <<"vpn-client">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"revocation_certificate">>,
                                                   source => ovpn_demo_import,
                                                   import_id => <<"revocation_import">>,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),
    Service = ias_demo_store:add_service(#{id => <<"revocation_service">>,
                                           source => ovpn_demo_import,
                                           import_id => <<"revocation_import">>,
                                           service => openvpn,
                                           remote => <<"example.com:1194">>}),
    {ok, _CertificateLink} = ias_relationship_link:create(uses_certificate,
                                                          maps:get(id, Device),
                                                          maps:get(id, Certificate)),
    {ok, _ServiceLink} = ias_relationship_link:create(uses_service,
                                                      maps:get(id, Device),
                                                      maps:get(id, Service)),
    {ok, _DevicePolicy} = ias_relationship_link:create(uses_security_policy,
                                                       maps:get(id, Device),
                                                       <<"high_security">>),
    {ok, _CertificatePolicy} = ias_relationship_link:create(uses_security_policy,
                                                            maps:get(id, Certificate),
                                                            <<"high_security">>),
    {ok, _Verification} = ias_certificate_verification:verify(
        Certificate#{certificate_id => maps:get(id, Certificate),
                     subject_cn => maps:get(id, Certificate),
                     issuer_cn => <<"Zencrypted Dev CA">>,
                     profile => administrator_profile(),
                     profile_id => administrator,
                     claims => #{role => admin,
                                 services => [vpn, ias],
                                 attributes => [admin, issue_certificates, revoke_certificates],
                                 trust_level => elevated},
                     trusted => true,
                     key_match => true}),
    #{device => Device,
      certificate => Certificate,
      service => Service}.

readiness_for(Device) ->
    DeviceId = maps:get(id, Device),
    [Readiness] = [Readiness || Readiness <- maps:get(all, ias_graph_analysis:devices_operational_readiness()),
                                maps:get(device_id, Readiness) =:= DeviceId],
    Readiness.

administrator_profile() ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile, undefined) =:= administrator],
    Profile.

edge(RelationType, SourceKind, SourceId, TargetKind, TargetId) ->
    fun(Relationship) ->
        maps:get(relation_type, Relationship, undefined) =:= RelationType andalso
            maps:get(source_kind, Relationship, undefined) =:= SourceKind andalso
            maps:get(source_id, Relationship, undefined) =:= SourceId andalso
            maps:get(target_kind, Relationship, undefined) =:= TargetKind andalso
            maps:get(target_id, Relationship, undefined) =:= TargetId
    end.
