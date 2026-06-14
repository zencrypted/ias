-module(ias_relationship_link).
-export([create/3, relationships_for/1, exists/3, status/3]).

create(RelationType, SourceId, TargetId) ->
    with_objects(SourceId, TargetId,
                 fun(Source, Target) -> create_for_objects(RelationType, Source, Target) end).

relationships_for(Object) ->
    Id = maps:get(id, Object, undefined),
    Kind = maps:get(kind, Object, undefined),
    [Relationship || Relationship <- ias_demo_store:relationships(),
                     touches(Relationship, Kind, Id)].

exists(RelationType, SourceId, TargetId) ->
    case canonical(RelationType, SourceId, TargetId) of
        {ok, CanonicalRelationType, Source, Target} ->
            existing_relationship(CanonicalRelationType, Source, Target);
        _ ->
            not_found
    end.

status(RelationType, SourceId, TargetId) ->
    case canonical(RelationType, SourceId, TargetId) of
        {ok, CanonicalRelationType, Source, Target} ->
            relationship_status(CanonicalRelationType, Source, Target);
        _ ->
            not_found
    end.

with_objects(SourceId, TargetId, Fun) ->
    case {ias_demo_store:get(SourceId), ias_demo_store:get(TargetId)} of
        {{ok, Source}, {ok, Target}} -> Fun(Source, Target);
        _ -> {error, not_found}
    end.

create_for_objects(uses_certificate, #{kind := device} = Device,
                   #{kind := certificate} = Certificate) ->
    create_relationship(uses_certificate, Device, Certificate);
create_for_objects(uses_certificate, #{kind := certificate} = Certificate,
                   #{kind := device} = Device) ->
    create_relationship(uses_certificate, Device, Certificate);
create_for_objects(uses_service, #{kind := device} = Device,
                   #{kind := vpn_service} = Service) ->
    create_relationship(uses_service, Device, Service);
create_for_objects(uses_service, #{kind := vpn_service} = Service,
                   #{kind := device} = Device) ->
    create_relationship(uses_service, Device, Service);
create_for_objects(uses_security_policy, #{kind := Kind} = Object,
                   #{kind := security_policy} = Policy)
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service ->
    create_relationship(uses_security_policy, Object, Policy);
create_for_objects(uses_security_policy, #{kind := security_policy} = Policy,
                   #{kind := Kind} = Object)
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service ->
    create_relationship(uses_security_policy, Object, Policy);
create_for_objects(uses_security_profile, #{kind := Kind} = Object,
                   #{kind := security_profile} = Profile)
  when Kind =:= user; Kind =:= device; Kind =:= certificate ->
    create_relationship(uses_security_profile, Object, Profile);
create_for_objects(uses_security_profile, #{kind := security_profile} = Profile,
                   #{kind := Kind} = Object)
  when Kind =:= user; Kind =:= device; Kind =:= certificate ->
    create_relationship(uses_security_profile, Object, Profile);
create_for_objects(issued_certificate, #{kind := user} = User,
                   #{kind := certificate} = Certificate) ->
    create_relationship(issued_certificate, User, Certificate);
create_for_objects(issued_certificate, #{kind := certificate} = Certificate,
                   #{kind := user} = User) ->
    create_relationship(issued_certificate, User, Certificate);
create_for_objects(issued_certificate, #{kind := security_profile} = Profile,
                   #{kind := certificate} = Certificate) ->
    create_relationship(issued_certificate, Profile, Certificate);
create_for_objects(issued_certificate, #{kind := certificate} = Certificate,
                   #{kind := security_profile} = Profile) ->
    create_relationship(issued_certificate, Profile, Certificate);
create_for_objects(_RelationType, _Source, _Target) ->
    {error, unsupported}.

create_relationship(uses_security_policy, Source,
                    #{kind := security_policy} = Policy) ->
    case relationship_status(uses_security_policy, Source, Policy) of
        link ->
            add_relationship(uses_security_policy, Source, Policy);
        {linked, Relationship} ->
            {ok, Relationship};
        {already_has_policy, PolicyId, _Relationship} ->
            {error, {already_has_policy, PolicyId}}
    end;
create_relationship(RelationType, Source, Target) ->
    case existing_relationship(RelationType, Source, Target) of
        not_found ->
            add_relationship(RelationType, Source, Target);
        Relationship ->
            {ok, Relationship}
    end.

add_relationship(RelationType, Source, Target) ->
    Score = candidate_score(Source, Target),
    {ok, ias_demo_store:add_relationship(#{
        relation_type => RelationType,
        source_kind => maps:get(kind, Source, undefined),
        source_id => maps:get(id, Source, undefined),
        target_kind => maps:get(kind, Target, undefined),
        target_id => maps:get(id, Target, undefined),
        score => Score
    })}.

canonical(RelationType, SourceId, TargetId) ->
    with_objects(SourceId, TargetId,
                 fun(Source, Target) -> canonical_for_objects(RelationType, Source, Target) end).

canonical_for_objects(uses_certificate, #{kind := device} = Device,
                      #{kind := certificate} = Certificate) ->
    {ok, uses_certificate, Device, Certificate};
canonical_for_objects(uses_certificate, #{kind := certificate} = Certificate,
                      #{kind := device} = Device) ->
    {ok, uses_certificate, Device, Certificate};
canonical_for_objects(uses_service, #{kind := device} = Device,
                      #{kind := vpn_service} = Service) ->
    {ok, uses_service, Device, Service};
canonical_for_objects(uses_service, #{kind := vpn_service} = Service,
                      #{kind := device} = Device) ->
    {ok, uses_service, Device, Service};
canonical_for_objects(uses_security_policy, #{kind := Kind} = Object,
                      #{kind := security_policy} = Policy)
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service ->
    {ok, uses_security_policy, Object, Policy};
canonical_for_objects(uses_security_policy, #{kind := security_policy} = Policy,
                      #{kind := Kind} = Object)
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service ->
    {ok, uses_security_policy, Object, Policy};
canonical_for_objects(uses_security_profile, #{kind := Kind} = Object,
                      #{kind := security_profile} = Profile)
  when Kind =:= user; Kind =:= device; Kind =:= certificate ->
    {ok, uses_security_profile, Object, Profile};
canonical_for_objects(uses_security_profile, #{kind := security_profile} = Profile,
                      #{kind := Kind} = Object)
  when Kind =:= user; Kind =:= device; Kind =:= certificate ->
    {ok, uses_security_profile, Object, Profile};
canonical_for_objects(issued_certificate, #{kind := user} = User,
                      #{kind := certificate} = Certificate) ->
    {ok, issued_certificate, User, Certificate};
canonical_for_objects(issued_certificate, #{kind := certificate} = Certificate,
                      #{kind := user} = User) ->
    {ok, issued_certificate, User, Certificate};
canonical_for_objects(issued_certificate, #{kind := security_profile} = Profile,
                      #{kind := certificate} = Certificate) ->
    {ok, issued_certificate, Profile, Certificate};
canonical_for_objects(issued_certificate, #{kind := certificate} = Certificate,
                      #{kind := security_profile} = Profile) ->
    {ok, issued_certificate, Profile, Certificate};
canonical_for_objects(_RelationType, _Source, _Target) ->
    {error, unsupported}.

existing_relationship(RelationType, Source, Target) ->
    SourceKind = maps:get(kind, Source, undefined),
    SourceId = maps:get(id, Source, undefined),
    TargetKind = maps:get(kind, Target, undefined),
    TargetId = maps:get(id, Target, undefined),
    case [Relationship || Relationship <- ias_demo_store:relationships(),
                          maps:get(relation_type, Relationship, undefined) =:= RelationType,
                          maps:get(source_kind, Relationship, undefined) =:= SourceKind,
                          maps:get(source_id, Relationship, undefined) =:= SourceId,
                          maps:get(target_kind, Relationship, undefined) =:= TargetKind,
                          maps:get(target_id, Relationship, undefined) =:= TargetId] of
        [Relationship | _] -> Relationship;
        [] -> not_found
    end.

relationship_status(uses_security_policy, Source,
                    #{kind := security_policy} = Policy) ->
    case existing_security_policy_relationship(Source) of
        not_found ->
            link;
        #{target_id := PolicyId} = Relationship ->
            case PolicyId =:= maps:get(id, Policy, undefined) of
                true -> {linked, Relationship};
                false -> {already_has_policy, PolicyId, Relationship}
            end
    end;
relationship_status(RelationType, Source, Target) ->
    case existing_relationship(RelationType, Source, Target) of
        not_found -> link;
        Relationship -> {linked, Relationship}
    end.

existing_security_policy_relationship(Source) ->
    SourceKind = maps:get(kind, Source, undefined),
    SourceId = maps:get(id, Source, undefined),
    case [Relationship || Relationship <- ias_demo_store:relationships(),
                          maps:get(relation_type, Relationship, undefined) =:= uses_security_policy,
                          maps:get(source_kind, Relationship, undefined) =:= SourceKind,
                          maps:get(source_id, Relationship, undefined) =:= SourceId,
                          maps:get(target_kind, Relationship, undefined) =:= security_policy] of
        [Relationship | _] -> Relationship;
        [] -> not_found
    end.

candidate_score(Source, Target) ->
    TargetId = maps:get(id, Target, undefined),
    Candidates = candidates_for(Source, Target),
    case [maps:get(relationship_score, Candidate, 0)
          || Candidate <- Candidates,
             maps:get(id, Candidate, undefined) =:= TargetId] of
        [Score | _] -> Score;
        [] -> 0
    end.

candidates_for(#{kind := device} = Source, #{kind := certificate}) ->
    maps:get(suggested_certificates, ias_relationship_preview:preview(Source), []);
candidates_for(#{kind := device} = Source, #{kind := vpn_service}) ->
    maps:get(suggested_services, ias_relationship_preview:preview(Source), []);
candidates_for(#{kind := certificate} = Source, #{kind := device}) ->
    maps:get(suggested_devices, ias_relationship_preview:preview(Source), []);
candidates_for(#{kind := vpn_service} = Source, #{kind := device}) ->
    maps:get(suggested_devices, ias_relationship_preview:preview(Source), []);
candidates_for(#{kind := Kind} = Source, #{kind := security_policy})
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service ->
    maps:get(suggested_security_policies, ias_relationship_preview:preview(Source), []);
candidates_for(#{kind := security_policy}, #{kind := Kind} = Target)
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service ->
    maps:get(suggested_security_policies, ias_relationship_preview:preview(Target), []);
candidates_for(_Source, _Target) ->
    [].

touches(Relationship, Kind, Id) ->
    (maps:get(source_kind, Relationship, undefined) =:= Kind andalso
     maps:get(source_id, Relationship, undefined) =:= Id) orelse
    (maps:get(target_kind, Relationship, undefined) =:= Kind andalso
     maps:get(target_id, Relationship, undefined) =:= Id).
