-module(ias_certificate_issue_demo).
-export([issue/3]).

issue(UserId, SubjectCN, Profiles) ->
    case ias_demo_store:get(UserId) of
        {ok, #{kind := user} = User} ->
            Profile = profile_for_user(User, Profiles),
            issue_for_user(User, Profile, SubjectCN);
        _ ->
            {error, user_not_found}
    end.

issue_for_user(User, Profile, SubjectCN) when is_map(Profile), map_size(Profile) > 0 ->
    Certificate = certificate_object(User, Profile, SubjectCN),
    Stored = ias_demo_store:add_certificate(Certificate),
    _ = ias_relationship_link:create(issued_certificate,
                                     maps:get(id, User, undefined),
                                     maps:get(id, Stored, undefined)),
    _ = ias_relationship_link:create(issued_certificate,
                                     maps:get(id, Profile, undefined),
                                     maps:get(id, Stored, undefined)),
    {ok, Stored};
issue_for_user(_User, _Profile, _SubjectCN) ->
    {error, profile_not_found}.

certificate_object(User, Profile, SubjectCN) ->
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
      certificate_body_stored => false}.

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
