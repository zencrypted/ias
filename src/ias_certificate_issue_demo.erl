-module(ias_certificate_issue_demo).
-export([issue/3, issue_from_certificate/4]).

issue(UserId, SubjectCN, Profiles) ->
    case ias_demo_store:get(UserId) of
        {ok, #{kind := user} = User} ->
            Profile = profile_for_user(User, Profiles),
            issue_for_user(User, Profile, SubjectCN, undefined);
        _ ->
            {error, user_not_found}
    end.

issue_from_certificate(SourceCertificateId, UserId, SubjectCN, Profiles) ->
    case ias_demo_store:get(SourceCertificateId) of
        {ok, #{kind := certificate, source := cmp_demo_enrollment} = SourceCertificate} ->
            issue_from_enrollment_certificate(SourceCertificate, UserId, SubjectCN, Profiles);
        _ ->
            {error, source_certificate_not_found}
    end.

issue_from_enrollment_certificate(SourceCertificate, UserId, SubjectCN, Profiles) ->
    SourceId = maps:get(id, SourceCertificate, undefined),
    case ias_demo_store:get(UserId) of
        {ok, #{kind := user} = User} ->
            Profile = profile_for_user(User, Profiles),
            issue_for_user(User, Profile, SubjectCN, SourceId);
        _ ->
            {error, user_not_found}
    end.

issue_for_user(User, Profile, SubjectCN, SourceCertificateId) when is_map(Profile), map_size(Profile) > 0 ->
    Certificate = certificate_object(User, Profile, SubjectCN, SourceCertificateId),
    Stored = ias_demo_store:add_certificate(Certificate),
    _ = ias_relationship_link:create(issued_certificate,
                                     maps:get(id, User, undefined),
                                     maps:get(id, Stored, undefined)),
    _ = ias_relationship_link:create(issued_certificate,
                                     maps:get(id, Profile, undefined),
                                     maps:get(id, Stored, undefined)),
    _ = maybe_link_source_certificate(SourceCertificateId, Stored),
    {ok, Stored};
issue_for_user(_User, _Profile, _SubjectCN, _SourceCertificateId) ->
    {error, profile_not_found}.

maybe_link_source_certificate(undefined, _Certificate) ->
    ok;
maybe_link_source_certificate(SourceCertificateId, Certificate) ->
    case ias_relationship_link:create(issues, SourceCertificateId,
                                      maps:get(id, Certificate, undefined)) of
        {ok, _Relationship} ->
            ok;
        _ ->
            ok
    end.

certificate_object(User, Profile, SubjectCN, SourceCertificateId) ->
    Claims = ias_policy:certificate_claims(Profile),
    ProfileId = maps:get(id, Profile, undefined),
    UserId = maps:get(id, User, undefined),
    Id = certificate_id(UserId),
    #{id => Id,
      import_id => ias_html:join([<<"certificate_issue_">>, ias_html:text(UserId)]),
      source => certificate_issue_demo,
      user => UserId,
      user_name => maps:get(name, User, UserId),
      profile => ProfileId,
      profile_id => ProfileId,
      subject_cn => ias_html:text(SubjectCN),
      role => maps:get(role, Claims, undefined),
      services => maps:get(services, Claims, []),
      attributes => maps:get(attributes, Claims, []),
      trust_level => maps:get(trust_level, Claims, undefined),
      device_lock => ias_policy:device_lock(Profile),
      two_factor => ias_policy:two_factor(Profile),
      private_key_stored => false,
      certificate_body_stored => false,
      source_certificate_id => SourceCertificateId}.

certificate_id(UserId) ->
    ias_html:join([<<"issued_certificate_">>,
                   ias_html:text(UserId), <<"_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

profile_for_user(User, Profiles) ->
    ProfileId = maps:get(profile_id, User, undefined),
    case [Profile || Profile <- Profiles, maps:get(id, Profile, undefined) =:= ProfileId] of
        [Profile | _] -> Profile;
        [] -> #{}
    end.
