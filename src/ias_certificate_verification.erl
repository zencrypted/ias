-module(ias_certificate_verification).
-export([verify/1,
         unique_verified_certificates/0,
         total_verification_records/0,
         failed_verifications/0,
         certificates_never_verified/0,
         verification_history/1,
         certificate_status/1]).

verify(Certificate) ->
    StoredCertificate = ensure_certificate(Certificate),
    Verification = ias_demo_store:put_runtime_object(verification_object(StoredCertificate, Certificate)),
    _ = ias_relationship_link:create(verified_by,
                                     maps:get(id, StoredCertificate, undefined),
                                     maps:get(id, Verification, undefined)),
    _ = link_security_policy(Verification),
    {ok, Verification}.

unique_verified_certificates() ->
    grouped_verified_certificates(verified_by_relationships(), []).

total_verification_records() ->
    verifications().

failed_verifications() ->
    [Verification || Verification <- verifications(),
                     maps:get(verification_status, Verification, undefined) =/= verified].

certificates_never_verified() ->
    [#{id => maps:get(id, Certificate, undefined), kind => certificate}
     || Certificate <- ias_demo_store:certificates(),
        verification_history(Certificate) =:= []].

verification_history(#{kind := certificate} = Certificate) ->
    CertificateId = maps:get(id, Certificate, undefined),
    [Verification || Relationship <- ias_demo_store:relationships(),
                     maps:get(relation_type, Relationship, undefined) =:= verified_by,
                     maps:get(source_kind, Relationship, undefined) =:= certificate,
                     maps:get(source_id, Relationship, undefined) =:= CertificateId,
                     maps:get(target_kind, Relationship, undefined) =:= verification,
                     {ok, Verification} <- [ias_demo_store:get(maps:get(target_id, Relationship, undefined))],
                     maps:get(kind, Verification, undefined) =:= verification];
verification_history(_Object) ->
    [].

certificate_status(not_found) ->
    <<"Not Verified">>;
certificate_status(#{kind := certificate} = Certificate) ->
    case verification_history(Certificate) of
        [] ->
            <<"Not Verified">>;
        History ->
            case lists:any(fun(Verification) ->
                maps:get(verification_status, Verification, undefined) =/= verified
            end, History) of
                true -> <<"Verification Failed">>;
                false -> <<"Verified">>
            end
    end;
certificate_status(_Object) ->
    <<"Not Verified">>.

ensure_certificate(Certificate) ->
    CertificateId = certificate_id(Certificate),
    case ias_demo_store:get(CertificateId) of
        {ok, #{kind := certificate} = Stored} ->
            Stored;
        _ ->
            ias_demo_store:add_certificate(certificate_object(CertificateId, Certificate))
    end.

certificate_object(CertificateId, Certificate) ->
    #{id => CertificateId,
      source => verification_demo,
      import_id => <<"verification_demo">>,
      peer_id => maps:get(peer_id, Certificate, undefined),
      subject_cn => maps:get(subject_cn, Certificate, undefined),
      issuer_cn => maps:get(issuer_cn, Certificate, undefined),
      profile_id => profile_id(Certificate),
      trusted => maps:get(trusted, Certificate, false),
      key_match => maps:get(key_match, Certificate, false),
      private_key_stored => false,
      certificate_body_stored => false}.

verification_object(StoredCertificate, Certificate) ->
    ProfileId = profile_id(Certificate),
    PolicyId = policy_id(ProfileId),
    VerificationStatus = verification_status(Certificate),
    AuthorizationStatus = authorization_status(Certificate),
    Id = verification_id(maps:get(id, StoredCertificate, undefined)),
    #{id => Id,
      kind => verification,
      source => verification_demo,
      import_id => <<"verification_demo">>,
      certificate_id => maps:get(id, StoredCertificate, undefined),
      certificate_subject => maps:get(subject_cn, Certificate, undefined),
      verification_status => VerificationStatus,
      authorization_status => AuthorizationStatus,
      resolved_profile => ProfileId,
      resolved_policy => PolicyId,
      trusted => maps:get(trusted, Certificate, false),
      key_match => maps:get(key_match, Certificate, false),
      created_at => created_at()}.

verification_status(Certificate) when is_map(Certificate) ->
    Claims = maps:get(claims, Certificate, #{}),
    Profile = maps:get(profile, Certificate, #{}),
    ProfileClaims = ias_policy:certificate_claims(Profile),
    case maps:get(trusted, Certificate, false) =:= true andalso
         maps:get(key_match, Certificate, false) =:= true andalso
         ias_policy:certificate_claims_match(ProfileClaims, Claims) =:= true of
        true -> verified;
        false -> failed
    end.

authorization_status(Certificate) ->
    Decision = ias_policy:evaluate_certificate(Certificate, vpn),
    maps:get(decision, Decision, deny).

profile_id(Certificate) ->
    Profile = maps:get(profile, Certificate, #{}),
    maps:get(id, Profile, maps:get(profile_id, Certificate, undefined)).

policy_id(administrator) ->
    <<"high_security">>;
policy_id(<<"administrator">>) ->
    <<"high_security">>;
policy_id(default_user) ->
    <<"standard">>;
policy_id(<<"default_user">>) ->
    <<"standard">>;
policy_id(undefined) ->
    undefined;
policy_id(_ProfileId) ->
    undefined.

link_security_policy(#{resolved_policy := undefined}) ->
    ok;
link_security_policy(Verification) ->
    _ = ias_relationship_link:create(uses_security_policy,
                                     maps:get(id, Verification, undefined),
                                     maps:get(resolved_policy, Verification, undefined)),
    ok.

certificate_id(Certificate) ->
    case maps:get(certificate_id, Certificate, undefined) of
        undefined ->
            case maps:get(id, Certificate, undefined) of
                undefined ->
                    ias_html:join([<<"verify_certificate_">>,
                                   maps:get(peer_id, Certificate, <<"unknown">>)]);
                Id ->
                    Id
            end;
        Id ->
            Id
    end.

verification_id(CertificateId) ->
    ias_html:join([<<"verification_">>,
                   ias_html:text(CertificateId), <<"_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

verifications() ->
    [Object || Object <- ias_demo_store:runtime_objects(),
               maps:get(kind, Object, undefined) =:= verification].

verified_by_relationships() ->
    [Relationship || Relationship <- ias_demo_store:relationships(),
                     maps:get(relation_type, Relationship, undefined) =:= verified_by,
                     maps:get(source_kind, Relationship, undefined) =:= certificate,
                     maps:get(target_kind, Relationship, undefined) =:= verification].

grouped_verified_certificates([], Acc) ->
    lists:reverse(Acc);
grouped_verified_certificates([Relationship | Rest], Acc) ->
    CertificateId = maps:get(source_id, Relationship, undefined),
    VerificationId = maps:get(target_id, Relationship, undefined),
    case take_certificate_group(CertificateId, Acc, []) of
        {not_found, Kept} ->
            grouped_verified_certificates(Rest, [#{certificate_id => CertificateId,
                                                   verification_ids => [VerificationId]} | Kept]);
        {Group, Kept} ->
            VerificationIds = maps:get(verification_ids, Group, []),
            grouped_verified_certificates(Rest, [Group#{verification_ids => VerificationIds ++ [VerificationId]} | Kept])
    end.

take_certificate_group(_CertificateId, [], Kept) ->
    {not_found, lists:reverse(Kept)};
take_certificate_group(CertificateId, [#{certificate_id := CertificateId} = Group | Rest], Kept) ->
    {Group, lists:reverse(Kept) ++ Rest};
take_certificate_group(CertificateId, [Group | Rest], Kept) ->
    take_certificate_group(CertificateId, Rest, [Group | Kept]).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
