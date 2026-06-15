-module(ias_certificate_verification_tests).
-include_lib("eunit/include/eunit.hrl").

verification_creates_runtime_object_and_relationships_test() ->
    ias_demo_store:clear(),
    Certificate = certificate(<<"peer_a">>, true, true, administrator_claims(), administrator),

    {ok, Verification} = ias_certificate_verification:verify(Certificate),
    CertificateId = maps:get(certificate_id, Verification),

    ?assertEqual(verification, maps:get(kind, Verification)),
    ?assertEqual(CertificateId, maps:get(certificate_id, Verification)),
    ?assertEqual(administrator, maps:get(profile_id, Verification)),
    ?assertEqual(verified, maps:get(verification_result, Verification)),
    ?assertEqual(allow, maps:get(authorization_result, Verification)),
    ?assertMatch({ok, #{kind := certificate}}, ias_demo_store:get(CertificateId)),
    ?assert(lists:any(edge(uses_verification, certificate, CertificateId,
                           verification, maps:get(id, Verification)),
                      ias_demo_store:relationships())),
    ?assert(lists:any(edge(uses_security_policy, verification, maps:get(id, Verification),
                           security_policy, <<"high_security">>),
                      ias_demo_store:relationships())).

graph_analysis_verification_checks_test() ->
    ias_demo_store:clear(),
    {ok, Verified} = ias_certificate_verification:verify(
        certificate(<<"peer_a">>, true, true, administrator_claims(), administrator)),
    {ok, Failed} = ias_certificate_verification:verify(
        certificate(<<"peer_b">>, false, true, peer_claims(), default_user)),
    Never = ias_demo_store:add_certificate(#{id => <<"never_verified_certificate">>,
                                             source => verification_demo}),

    Report = ias_graph_analysis:report(),

    ?assert(lists:any(fun(Warning) ->
        maps:get(certificate_id, Warning) =:= maps:get(certificate_id, Verified)
    end, maps:get(verified_certificates, Report))),
    ?assert(lists:any(fun(Verification) ->
        maps:get(id, Verification) =:= maps:get(id, Failed)
    end, maps:get(failed_verifications, Report))),
    ?assert(lists:any(fun(Warning) ->
        maps:get(id, Warning) =:= maps:get(id, Never)
    end, maps:get(certificates_never_verified, Report))).

certificate_verification_history_test() ->
    ias_demo_store:clear(),
    {ok, Verification} = ias_certificate_verification:verify(
        certificate(<<"peer_a">>, true, true, administrator_claims(), administrator)),
    {ok, Certificate} = ias_demo_store:get(maps:get(certificate_id, Verification)),

    ?assertEqual([maps:get(id, Verification)],
                 [maps:get(id, Item) || Item <- ias_certificate_verification:verification_history(Certificate)]),
    ?assertEqual(<<"Verified">>, ias_certificate_verification:certificate_status(Certificate)).

failed_certificate_status_test() ->
    ias_demo_store:clear(),
    {ok, Verification} = ias_certificate_verification:verify(
        certificate(<<"peer_b">>, false, true, peer_claims(), default_user)),
    {ok, Certificate} = ias_demo_store:get(maps:get(certificate_id, Verification)),

    ?assertEqual(<<"Verification Failed">>, ias_certificate_verification:certificate_status(Certificate)).

verification_detail_rendering_test() ->
    ias_demo_store:clear(),
    {ok, Verification} = ias_certificate_verification:verify(
        certificate(<<"peer_a">>, true, true, administrator_claims(), administrator)),
    Html = iolist_to_binary(nitro:render(
        ias_graph_analysis_details:warning_blocks(ias_graph_analysis:report()))),

    ?assertMatch({_, _}, binary:match(Html, <<"Verified certificates">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Verification #">>)),
    ?assertMatch({_, _}, binary:match(Html, maps:get(id, Verification))).

edge(RelationType, SourceKind, SourceId, TargetKind, TargetId) ->
    fun(Relationship) ->
        maps:get(relation_type, Relationship, undefined) =:= RelationType andalso
            maps:get(source_kind, Relationship, undefined) =:= SourceKind andalso
            maps:get(source_id, Relationship, undefined) =:= SourceId andalso
            maps:get(target_kind, Relationship, undefined) =:= TargetKind andalso
            maps:get(target_id, Relationship, undefined) =:= TargetId
    end.

certificate(PeerId, Trusted, KeyMatch, Claims, ProfileId) ->
    Profile = profile(ProfileId),
    #{peer_id => PeerId,
      subject_cn => PeerId,
      issuer_cn => <<"Zencrypted Dev CA">>,
      trusted => Trusted,
      key_match => KeyMatch,
      user => #{id => alice, name => <<"Alice">>},
      profile => Profile,
      claims => Claims}.

profile(ProfileId) ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile) =:= ProfileId],
    Profile.

administrator_claims() ->
    #{role => admin,
      services => [vpn, ias],
      attributes => [admin, issue_certificates, revoke_certificates],
      trust_level => elevated}.

peer_claims() ->
    #{role => peer,
      services => [vpn],
      attributes => [user, device, vpn_peer],
      trust_level => standard}.
