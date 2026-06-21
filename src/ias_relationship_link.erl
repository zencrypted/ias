-module(ias_relationship_link).
-export([create/3, unlink/1, unlinkable/1, relationships_for/1, exists/3, status/3]).

create(RelationType, SourceId, TargetId) ->
    with_objects(SourceId, TargetId,
                 fun(Source, Target) -> create_for_objects(RelationType, Source, Target) end).

unlink(RelationshipId) ->
    case ias_demo_store:get(RelationshipId) of
        {ok, #{kind := relationship} = Relationship} ->
            case unlinkable(Relationship) of
                true ->
                    ok = ias_demo_store:delete_relationship(maps:get(id, Relationship, RelationshipId)),
                    {ok, unlinked};
                false ->
                    {error, protected_relationship}
            end;
        _ ->
            {error, not_found}
    end.

unlinkable(#{kind := relationship, relation_type := RelationType} = Relationship) ->
    unlinkable_relationship(RelationType, Relationship);
unlinkable(_Relationship) ->
    false.

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
create_for_objects(uses_ca_certificate, #{kind := vpn_service} = Service,
                   #{kind := certificate} = Certificate) ->
    create_relationship(uses_ca_certificate, Service, Certificate);
create_for_objects(uses_ca_certificate, #{kind := certificate} = Certificate,
                   #{kind := vpn_service} = Service) ->
    create_relationship(uses_ca_certificate, Service, Certificate);
create_for_objects(verified_by, #{kind := certificate} = Certificate,
                   #{kind := verification} = Verification) ->
    create_relationship(verified_by, Certificate, Verification);
create_for_objects(verified_by, #{kind := verification} = Verification,
                   #{kind := certificate} = Certificate) ->
    create_relationship(verified_by, Certificate, Verification);
create_for_objects(uses_security_policy, #{kind := Kind} = Object,
                   #{kind := security_policy} = Policy)
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service; Kind =:= verification ->
    create_relationship(uses_security_policy, Object, Policy);
create_for_objects(uses_security_policy, #{kind := security_policy} = Policy,
                   #{kind := Kind} = Object)
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service; Kind =:= verification ->
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
create_for_objects(issues, #{kind := cmp_enrollment_result} = Enrollment,
                   #{kind := certificate} = Certificate) ->
    create_relationship(issues, Enrollment, Certificate);
create_for_objects(issues, #{kind := certificate} = Certificate,
                   #{kind := cmp_enrollment_result} = Enrollment) ->
    create_relationship(issues, Enrollment, Certificate);
create_for_objects(issues, #{kind := certificate} = SourceCertificate,
                   #{kind := certificate} = TargetCertificate) ->
    create_relationship(issues, SourceCertificate, TargetCertificate);
create_for_objects(replaced_certificate_by, #{kind := device} = Device,
                   #{kind := certificate_replacement} = Replacement) ->
    create_relationship(replaced_certificate_by, Device, Replacement);
create_for_objects(replaced_certificate_by, #{kind := certificate_replacement} = Replacement,
                   #{kind := device} = Device) ->
    create_relationship(replaced_certificate_by, Device, Replacement);
create_for_objects(old_certificate, #{kind := certificate_replacement} = Replacement,
                   #{kind := certificate} = Certificate) ->
    create_relationship(old_certificate, Replacement, Certificate);
create_for_objects(old_certificate, #{kind := certificate} = Certificate,
                   #{kind := certificate_replacement} = Replacement) ->
    create_relationship(old_certificate, Replacement, Certificate);
create_for_objects(new_certificate, #{kind := certificate_replacement} = Replacement,
                   #{kind := certificate} = Certificate) ->
    create_relationship(new_certificate, Replacement, Certificate);
create_for_objects(new_certificate, #{kind := certificate} = Certificate,
                   #{kind := certificate_replacement} = Replacement) ->
    create_relationship(new_certificate, Replacement, Certificate);
create_for_objects(revoked_by, #{kind := certificate} = Certificate,
                   #{kind := certificate_revocation} = Revocation) ->
    create_relationship(revoked_by, Certificate, Revocation);
create_for_objects(revoked_by, #{kind := certificate_revocation} = Revocation,
                   #{kind := certificate} = Certificate) ->
    create_relationship(revoked_by, Certificate, Revocation);
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
create_relationship(RelationType, Source, Target)
  when RelationType =:= uses_certificate;
       RelationType =:= uses_service;
       RelationType =:= uses_ca_certificate ->
    case ias_relationship_constraints:check_create(RelationType, Source, Target) of
        {ok, Warnings} ->
            add_relationship(RelationType, Source, Target, Warnings);
        {linked, Relationship} ->
            {ok, Relationship};
        {blocked, Reason} ->
            {error, Reason}
    end;
create_relationship(RelationType, Source, Target) ->
    case existing_relationship(RelationType, Source, Target) of
        not_found ->
            add_relationship(RelationType, Source, Target);
        Relationship ->
            {ok, Relationship}
    end.

add_relationship(RelationType, Source, Target) ->
    add_relationship(RelationType, Source, Target, []).

add_relationship(RelationType, Source, Target, Warnings) ->
    Score = candidate_score(Source, Target),
    {ok, ias_demo_store:add_relationship(#{
        relation_type => RelationType,
        source_kind => maps:get(kind, Source, undefined),
        source_id => maps:get(id, Source, undefined),
        target_kind => maps:get(kind, Target, undefined),
        target_id => maps:get(id, Target, undefined),
        score => Score,
        warnings => Warnings
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
canonical_for_objects(uses_ca_certificate, #{kind := vpn_service} = Service,
                      #{kind := certificate} = Certificate) ->
    {ok, uses_ca_certificate, Service, Certificate};
canonical_for_objects(uses_ca_certificate, #{kind := certificate} = Certificate,
                      #{kind := vpn_service} = Service) ->
    {ok, uses_ca_certificate, Service, Certificate};
canonical_for_objects(verified_by, #{kind := certificate} = Certificate,
                      #{kind := verification} = Verification) ->
    {ok, verified_by, Certificate, Verification};
canonical_for_objects(verified_by, #{kind := verification} = Verification,
                      #{kind := certificate} = Certificate) ->
    {ok, verified_by, Certificate, Verification};
canonical_for_objects(uses_security_policy, #{kind := Kind} = Object,
                      #{kind := security_policy} = Policy)
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service; Kind =:= verification ->
    {ok, uses_security_policy, Object, Policy};
canonical_for_objects(uses_security_policy, #{kind := security_policy} = Policy,
                      #{kind := Kind} = Object)
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service; Kind =:= verification ->
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
canonical_for_objects(issues, #{kind := cmp_enrollment_result} = Enrollment,
                      #{kind := certificate} = Certificate) ->
    {ok, issues, Enrollment, Certificate};
canonical_for_objects(issues, #{kind := certificate} = Certificate,
                      #{kind := cmp_enrollment_result} = Enrollment) ->
    {ok, issues, Enrollment, Certificate};
canonical_for_objects(issues, #{kind := certificate} = SourceCertificate,
                      #{kind := certificate} = TargetCertificate) ->
    {ok, issues, SourceCertificate, TargetCertificate};
canonical_for_objects(replaced_certificate_by, #{kind := device} = Device,
                      #{kind := certificate_replacement} = Replacement) ->
    {ok, replaced_certificate_by, Device, Replacement};
canonical_for_objects(replaced_certificate_by, #{kind := certificate_replacement} = Replacement,
                      #{kind := device} = Device) ->
    {ok, replaced_certificate_by, Device, Replacement};
canonical_for_objects(old_certificate, #{kind := certificate_replacement} = Replacement,
                      #{kind := certificate} = Certificate) ->
    {ok, old_certificate, Replacement, Certificate};
canonical_for_objects(old_certificate, #{kind := certificate} = Certificate,
                      #{kind := certificate_replacement} = Replacement) ->
    {ok, old_certificate, Replacement, Certificate};
canonical_for_objects(new_certificate, #{kind := certificate_replacement} = Replacement,
                      #{kind := certificate} = Certificate) ->
    {ok, new_certificate, Replacement, Certificate};
canonical_for_objects(new_certificate, #{kind := certificate} = Certificate,
                      #{kind := certificate_replacement} = Replacement) ->
    {ok, new_certificate, Replacement, Certificate};
canonical_for_objects(revoked_by, #{kind := certificate} = Certificate,
                      #{kind := certificate_revocation} = Revocation) ->
    {ok, revoked_by, Certificate, Revocation};
canonical_for_objects(revoked_by, #{kind := certificate_revocation} = Revocation,
                      #{kind := certificate} = Certificate) ->
    {ok, revoked_by, Certificate, Revocation};
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
relationship_status(RelationType, Source, Target)
  when RelationType =:= uses_certificate;
       RelationType =:= uses_service;
       RelationType =:= uses_ca_certificate ->
    case ias_relationship_constraints:status(RelationType, Source, Target) of
        {ok, []} -> link;
        {ok, Warnings} -> {link_warning, Warnings};
        {linked, Relationship} -> {linked, Relationship};
        {blocked, Reason} -> {blocked, Reason}
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
candidates_for(#{kind := vpn_service} = Source, #{kind := certificate}) ->
    maps:get(suggested_ca_certificates, ias_relationship_preview:preview(Source), []);
candidates_for(#{kind := certificate} = Source, #{kind := vpn_service}) ->
    maps:get(suggested_ca_services, ias_relationship_preview:preview(Source), []);
candidates_for(#{kind := Kind} = Source, #{kind := security_policy})
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service; Kind =:= verification ->
    maps:get(suggested_security_policies, ias_relationship_preview:preview(Source), []);
candidates_for(#{kind := security_policy}, #{kind := Kind} = Target)
  when Kind =:= device; Kind =:= certificate; Kind =:= vpn_service; Kind =:= verification ->
    maps:get(suggested_security_policies, ias_relationship_preview:preview(Target), []);
candidates_for(_Source, _Target) ->
    [].

touches(Relationship, Kind, Id) ->
    (maps:get(source_kind, Relationship, undefined) =:= Kind andalso
     maps:get(source_id, Relationship, undefined) =:= Id) orelse
    (maps:get(target_kind, Relationship, undefined) =:= Kind andalso
     maps:get(target_id, Relationship, undefined) =:= Id).

unlinkable_relationship(uses_certificate, #{source_kind := device, target_kind := certificate}) ->
    true;
unlinkable_relationship(uses_service, #{source_kind := device, target_kind := vpn_service}) ->
    true;
unlinkable_relationship(uses_vpn_service, #{source_kind := device, target_kind := vpn_service}) ->
    true;
unlinkable_relationship(uses_ca_certificate, #{source_kind := vpn_service, target_kind := certificate}) ->
    true;
unlinkable_relationship(uses_security_policy, #{target_kind := security_policy}) ->
    true;
unlinkable_relationship(_RelationType, _Relationship) ->
    false.
