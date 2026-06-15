-module(ias_certificate_verification_tests).
-include_lib("eunit/include/eunit.hrl").

verify_certificate_creates_runtime_object_test() ->
    ias_demo_store:clear(),
    Certificate = certificate(<<"peer_a">>, true, true, administrator_claims(), administrator),

    {ok, Verification} = ias_certificate_verification:verify(Certificate),
    CertificateId = maps:get(certificate_id, Verification),

    ?assertEqual(verification, maps:get(kind, Verification)),
    ?assertEqual(CertificateId, maps:get(certificate_id, Verification)),
    ?assertEqual(<<"peer_a">>, maps:get(certificate_subject, Verification)),
    ?assertEqual(verified, maps:get(verification_status, Verification)),
    ?assertEqual(allow, maps:get(authorization_status, Verification)),
    ?assertEqual(administrator, maps:get(resolved_profile, Verification)),
    ?assertEqual(<<"high_security">>, maps:get(resolved_policy, Verification)),
    ?assertEqual(true, maps:get(trusted, Verification)),
    ?assertEqual(true, maps:get(key_match, Verification)),
    ?assertMatch({ok, #{kind := certificate}}, ias_demo_store:get(CertificateId)).

verify_certificate_links_certificate_to_verification_test() ->
    ias_demo_store:clear(),
    {ok, Verification} = ias_certificate_verification:verify(
        certificate(<<"peer_a">>, true, true, administrator_claims(), administrator)),
    CertificateId = maps:get(certificate_id, Verification),

    ?assert(lists:any(edge(verified_by, certificate, CertificateId,
                           verification, maps:get(id, Verification)),
                      ias_demo_store:relationships())).

verification_uses_security_policy_test() ->
    ias_demo_store:clear(),
    {ok, Verification} = ias_certificate_verification:verify(
        certificate(<<"peer_a">>, true, true, administrator_claims(), administrator)),

    ?assert(lists:any(edge(uses_security_policy, verification, maps:get(id, Verification),
                           security_policy, <<"high_security">>),
                      ias_demo_store:relationships())).

certificate_detail_shows_verification_history_test() ->
    ias_demo_store:clear(),
    {ok, Verification} = ias_certificate_verification:verify(
        certificate(<<"peer_a">>, true, true, administrator_claims(), administrator)),
    {ok, Certificate} = ias_demo_store:get(maps:get(certificate_id, Verification)),

    ?assertEqual([maps:get(id, Verification)],
                 [maps:get(id, Item) || Item <- ias_certificate_verification:verification_history(Certificate)]),
    ?assertEqual(<<"Verified">>, ias_certificate_verification:certificate_status(Certificate)).

graph_analysis_detects_verified_certificates_test() ->
    ias_demo_store:clear(),
    {ok, Verification} = ias_certificate_verification:verify(
        certificate(<<"peer_a">>, true, true, administrator_claims(), administrator)),
    Report = ias_graph_analysis:report(),

    ?assert(lists:any(fun(Warning) ->
        maps:get(certificate_id, Warning) =:= maps:get(certificate_id, Verification) andalso
            maps:get(verification_id, Warning) =:= maps:get(id, Verification)
    end, maps:get(verified_certificates, Report))).

graph_analysis_detects_certificates_never_verified_test() ->
    ias_demo_store:clear(),
    Never = ias_demo_store:add_certificate(#{id => <<"never_verified_certificate">>,
                                             source => verification_demo}),
    Report = ias_graph_analysis:report(),

    ?assert(lists:any(fun(Warning) ->
        maps:get(id, Warning) =:= maps:get(id, Never)
    end, maps:get(certificates_never_verified, Report))).

failed_verification_appears_in_graph_analysis_test() ->
    ias_demo_store:clear(),
    {ok, Failed} = ias_certificate_verification:verify(
        certificate(<<"peer_b">>, false, true, peer_claims(), default_user)),
    {ok, Certificate} = ias_demo_store:get(maps:get(certificate_id, Failed)),
    Report = ias_graph_analysis:report(),

    ?assert(lists:any(fun(Verification) ->
        maps:get(id, Verification) =:= maps:get(id, Failed)
    end, maps:get(failed_verifications, Report))),
    ?assertEqual(<<"Verification Failed">>, ias_certificate_verification:certificate_status(Certificate)).

verification_without_security_policy_is_reported_test() ->
    ias_demo_store:clear(),
    {ok, Verification} = ias_certificate_verification:verify(
        certificate(<<"peer_unknown">>, true, true, #{}, undefined)),
    Report = ias_graph_analysis:report(),

    ?assertEqual(undefined, maps:get(resolved_policy, Verification)),
    ?assertEqual(false, lists:any(edge_target(maps:get(id, Verification), uses_security_policy),
                                  ias_demo_store:relationships())),
    ?assert(lists:any(fun(Warning) ->
        maps:get(id, Warning) =:= maps:get(id, Verification)
    end, maps:get(verifications_without_security_policy, Report))).

verification_detail_rendering_test() ->
    ias_demo_store:clear(),
    {ok, Verification} = ias_certificate_verification:verify(
        certificate(<<"peer_a">>, true, true, administrator_claims(), administrator)),
    Html = iolist_to_binary(nitro:render(
        ias_graph_analysis_details:warning_blocks(ias_graph_analysis:report()))),

    ?assertMatch({_, _}, binary:match(Html, <<"Verified certificates">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Verification #">>)),
    ?assertMatch({_, _}, binary:match(Html, maps:get(id, Verification))).

runtime_certificate_selector_includes_supported_sources_test() ->
    ias_demo_store:clear(),
    Issued = ias_demo_store:add_certificate(runtime_certificate(<<"runtime_issued_cert">>,
                                                               certificate_issue_demo)),
    Imported = ias_demo_store:add_certificate(runtime_certificate(<<"runtime_ovpn_cert">>,
                                                                 ovpn_demo_import)),
    Enrollment = ias_demo_store:add_certificate(runtime_certificate(<<"runtime_cmp_cert">>,
                                                                   cmp_demo_enrollment)),
    _Unsupported = ias_demo_store:add_certificate(runtime_certificate(<<"runtime_other_cert">>,
                                                                     verification_demo)),

    Certificates = ias_verify_cert:verification_certificates(),
    Ids = [maps:get(certificate_id, Certificate) || Certificate <- Certificates],

    ?assert(lists:member(maps:get(id, Issued), Ids)),
    ?assert(lists:member(maps:get(id, Imported), Ids)),
    ?assert(lists:member(maps:get(id, Enrollment), Ids)),
    ?assertNot(lists:member(<<"runtime_other_cert">>, Ids)).

runtime_certificate_verification_updates_graph_analysis_test() ->
    ias_demo_store:clear(),
    RuntimeCertificate = ias_demo_store:add_certificate(runtime_certificate(<<"runtime_graph_cert">>,
                                                                           certificate_issue_demo)),
    Before = ias_graph_analysis:report(),
    Certificate = ias_verify_cert:verification_certificate(maps:get(id, RuntimeCertificate)),

    {ok, Verification} = ias_certificate_verification:verify(Certificate),
    After = ias_graph_analysis:report(),

    ?assert(lists:any(fun(Warning) ->
        maps:get(id, Warning) =:= maps:get(id, RuntimeCertificate)
    end, maps:get(certificates_never_verified, Before))),
    ?assertNot(lists:any(fun(Warning) ->
        maps:get(id, Warning) =:= maps:get(id, RuntimeCertificate)
    end, maps:get(certificates_never_verified, After))),
    ?assert(lists:any(fun(Warning) ->
        maps:get(certificate_id, Warning) =:= maps:get(id, RuntimeCertificate) andalso
            maps:get(verification_id, Warning) =:= maps:get(id, Verification)
    end, maps:get(verified_certificates, After))),
    ?assert(lists:any(edge(verified_by, certificate, maps:get(id, RuntimeCertificate),
                           verification, maps:get(id, Verification)),
                      ias_demo_store:relationships())).

edge(RelationType, SourceKind, SourceId, TargetKind, TargetId) ->
    fun(Relationship) ->
        maps:get(relation_type, Relationship, undefined) =:= RelationType andalso
            maps:get(source_kind, Relationship, undefined) =:= SourceKind andalso
            maps:get(source_id, Relationship, undefined) =:= SourceId andalso
            maps:get(target_kind, Relationship, undefined) =:= TargetKind andalso
            maps:get(target_id, Relationship, undefined) =:= TargetId
    end.

edge_target(SourceId, RelationType) ->
    fun(Relationship) ->
        maps:get(relation_type, Relationship, undefined) =:= RelationType andalso
            maps:get(source_id, Relationship, undefined) =:= SourceId
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

profile(undefined) ->
    #{};
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

runtime_certificate(Id, Source) ->
    #{id => Id,
      source => Source,
      import_id => <<"runtime_verification_test">>,
      user => alice,
      profile_id => administrator,
      subject_cn => Id,
      issuer_cn => <<"Zencrypted Dev CA">>,
      role => admin,
      services => [vpn, ias],
      attributes => [admin, issue_certificates, revoke_certificates],
      trust_level => elevated,
      trusted => true,
      key_match => true,
      private_key_stored => false,
      certificate_body_stored => false}.
