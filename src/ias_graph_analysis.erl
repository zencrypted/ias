-module(ias_graph_analysis).
-export([report/0, devices_operational_readiness/0]).

report() ->
    #{policy_mismatches => policy_mismatches(),
      authorization_allowed_devices => authorization_allowed_devices(),
      authorization_denied_devices => authorization_denied_devices(),
      authorization_allowed_certificates => authorization_allowed_certificates(),
      authorization_denied_certificates => authorization_denied_certificates(),
      effective_certificate_statuses => effective_certificate_statuses(),
      effective_device_statuses => effective_device_statuses(),
      device_operational_readiness => devices_operational_readiness(),
      unique_verified_certificates => ias_certificate_verification:unique_verified_certificates(),
      total_verification_records => ias_certificate_verification:total_verification_records(),
      failed_verifications => ias_certificate_verification:failed_verifications(),
      certificates_never_verified => ias_certificate_verification:certificates_never_verified(),
      revoked_certificates => revoked_certificates(),
      certificates_using_revoked_current_certificate =>
          certificates_using_revoked_current_certificate(),
      devices_with_revoked_current_certificate => devices_with_revoked_current_certificate(),
      verifications_without_security_policy => verifications_without_security_policy(),
      devices_without_security_policy => devices_without_security_policy(),
      certificates_without_security_policy => certificates_without_security_policy(),
      devices_without_vpn_service => devices_without_vpn_service(),
      enrollment_certificates_without_issued_certificate =>
          enrollment_certificates_without_issued_certificate(),
      certificates_linked_to_multiple_devices => certificates_linked_to_multiple_devices(),
      devices_with_replacement_available => devices_with_replacement_available()}.

authorization_allowed_devices() ->
    [Decision || Decision <- device_authorization_decisions(),
                 maps:get(decision, Decision, deny) =:= allow].

authorization_denied_devices() ->
    [Decision || Decision <- device_authorization_decisions(),
                 maps:get(decision, Decision, deny) =:= deny].

authorization_allowed_certificates() ->
    [Decision || Decision <- certificate_authorization_decisions(),
                 maps:get(decision, Decision, deny) =:= allow].

authorization_denied_certificates() ->
    [Decision || Decision <- certificate_authorization_decisions(),
                 maps:get(decision, Decision, deny) =:= deny].

device_authorization_decisions() ->
    [ias_authorization_decision:device_decision(maps:get(id, Device, undefined),
                                                access_vpn)
     || Device <- ias_demo_store:devices()].

certificate_authorization_decisions() ->
    [ias_authorization_decision:certificate_decision(maps:get(id, Certificate, undefined),
                                                     use_ias)
     || Certificate <- ias_demo_store:certificates()].

effective_certificate_statuses() ->
    [ias_trust_status:effective_certificate_status(maps:get(id, Certificate, undefined))
     || Certificate <- ias_demo_store:certificates()].

effective_device_statuses() ->
    [ias_trust_status:effective_device_status(maps:get(id, Device, undefined))
     || Device <- ias_demo_store:devices()].

policy_mismatches() ->
    [mismatch_warning(DeviceId, CertificateId, Consistency)
     || {DeviceId, CertificateId} <- device_certificate_links(),
        Consistency <- [ias_policy_consistency:evaluate_policy_consistency(DeviceId, CertificateId)],
        policies_present(Consistency),
        maps:get(match, Consistency, false) =:= false].

devices_without_security_policy() ->
    [object_warning(Device) || Device <- ias_demo_store:devices(),
                             active_security_policy(Device) =:= not_found].

verifications_without_security_policy() ->
    [object_warning(Verification) || Verification <- ias_demo_store:runtime_objects(),
                                       maps:get(kind, Verification, undefined) =:= verification,
                                       active_security_policy(Verification) =:= not_found].

certificates_without_security_policy() ->
    [object_warning(Certificate) || Certificate <- ias_demo_store:certificates(),
                                  active_security_policy(Certificate) =:= not_found].

devices_without_vpn_service() ->
    [object_warning(Device) || Device <- ias_demo_store:devices(),
                             not has_vpn_service(Device)].

enrollment_certificates_without_issued_certificate() ->
    [object_warning(Certificate) || Certificate <- ias_demo_store:certificates(),
                                  is_enrollment_certificate(Certificate),
                                  not issues_certificate(Certificate)].

certificates_linked_to_multiple_devices() ->
    [multiple_device_warning(Certificate, DeviceIds)
     || Certificate <- ias_demo_store:certificates(),
        DeviceIds <- [linked_device_ids(Certificate)],
        length(DeviceIds) > 1].

devices_with_replacement_available() ->
    [replacement_warning(Device, Status)
     || Device <- ias_demo_store:devices(),
        Status <- [ias_certificate_role:device_status(Device)],
        maps:get(state, Status, undefined) =:= replacement_available].

revoked_certificates() ->
    [revoked_certificate_warning(Certificate)
     || Certificate <- ias_demo_store:certificates(),
        ias_certificate_revocation:revoked(Certificate)].

devices_with_revoked_current_certificate() ->
    [revoked_current_certificate_warning(Device, CurrentCertificate)
     || Device <- ias_demo_store:devices(),
        CurrentCertificate <- [current_certificate(Device)],
        CurrentCertificate =/= not_found,
        ias_certificate_revocation:revoked(CurrentCertificate)].

certificates_using_revoked_current_certificate() ->
    dedupe_warnings([#{id => maps:get(certificate_id, Warning, undefined),
                       kind => certificate}
                    || Warning <- devices_with_revoked_current_certificate()]).

devices_operational_readiness() ->
    Results = [device_readiness(Device) || Device <- ias_demo_store:devices()],
    #{ready => [Result || Result <- Results,
                          maps:get(status, Result, incomplete) =:= ready],
      incomplete => [Result || Result <- Results,
                               maps:get(status, Result, incomplete) =:= incomplete],
      all => Results}.

device_readiness(Device) ->
    DeviceId = maps:get(id, Device, undefined),
    VpnServiceId = linked_vpn_service_id(Device),
    DevicePolicyId = security_policy_id(Device),
    CurrentCertificate = maps:get(current_certificate,
                                  ias_certificate_role:device_status(Device),
                                  not_found),
    CurrentCertificateId = certificate_id(CurrentCertificate),
    CertificatePolicyId = certificate_security_policy_id(CurrentCertificate),
    VerificationStatus = certificate_verification_status(CurrentCertificate),
    RevocationStatus = certificate_revocation_status(CurrentCertificate),
    PolicyConsistency = policy_consistency(DeviceId, CurrentCertificateId),
    Missing = missing_requirements(VpnServiceId, DevicePolicyId, CurrentCertificate,
                                   CertificatePolicyId, VerificationStatus, RevocationStatus,
                                   PolicyConsistency),
    Status = readiness_status(Missing),
    #{device_id => DeviceId,
      kind => device,
      status => Status,
      vpn_service_id => VpnServiceId,
      security_policy_id => DevicePolicyId,
      current_certificate_id => CurrentCertificateId,
      certificate_security_policy_id => CertificatePolicyId,
      certificate_verification => VerificationStatus,
      certificate_revocation => RevocationStatus,
      policy_match => maps:get(match, PolicyConsistency, false),
      missing => Missing,
      suggested_actions => suggested_actions(Missing)}.

device_certificate_links() ->
    [{maps:get(source_id, Relationship, undefined),
      maps:get(target_id, Relationship, undefined)}
     || Relationship <- ias_demo_store:relationships(),
        maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
        maps:get(source_kind, Relationship, undefined) =:= device,
        maps:get(target_kind, Relationship, undefined) =:= certificate,
        resolves(maps:get(source_id, Relationship, undefined), device),
        resolves(maps:get(target_id, Relationship, undefined), certificate)].

mismatch_warning(DeviceId, CertificateId, Consistency) ->
    #{device_id => DeviceId,
      certificate_id => CertificateId,
      device_policy => maps:get(device_policy, Consistency, not_found),
      certificate_policy => maps:get(certificate_policy, Consistency, not_found),
      reason => maps:get(reason, Consistency, <<"policy mismatch">>)}.

policies_present(Consistency) ->
    maps:get(device_policy, Consistency, not_found) =/= not_found andalso
        maps:get(certificate_policy, Consistency, not_found) =/= not_found.

object_warning(Object) ->
    #{id => maps:get(id, Object, undefined),
      kind => maps:get(kind, Object, undefined)}.

multiple_device_warning(Certificate, DeviceIds) ->
    #{certificate_id => maps:get(id, Certificate, undefined),
      device_ids => DeviceIds}.

replacement_warning(Device, Status) ->
    #{device_id => maps:get(id, Device, undefined),
      current_certificate_id => certificate_id(maps:get(current_certificate, Status, not_found)),
      candidate_certificate_id => certificate_id(maps:get(candidate_certificate, Status, not_found))}.

revoked_certificate_warning(Certificate) ->
    Revocation = ias_certificate_revocation:revocation_for_certificate(Certificate),
    #{id => maps:get(id, Certificate, undefined),
      kind => certificate,
      revocation_id => revocation_id(Revocation)}.

revoked_current_certificate_warning(Device, Certificate) ->
    Revocation = ias_certificate_revocation:revocation_for_certificate(Certificate),
    #{device_id => maps:get(id, Device, undefined),
      certificate_id => maps:get(id, Certificate, undefined),
      revocation_id => revocation_id(Revocation)}.

revocation_id(not_found) ->
    not_found;
revocation_id(#{id := Id}) ->
    Id;
revocation_id(_) ->
    not_found.

active_security_policy(Object) ->
    ObjectId = maps:get(id, Object, undefined),
    ObjectKind = maps:get(kind, Object, undefined),
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_demo_store:relationships(),
             maps:get(relation_type, Relationship, undefined) =:= uses_security_policy,
             maps:get(source_kind, Relationship, undefined) =:= ObjectKind,
             maps:get(source_id, Relationship, undefined) =:= ObjectId,
             maps:get(target_kind, Relationship, undefined) =:= security_policy,
             resolves(maps:get(target_id, Relationship, undefined), security_policy)] of
        [_PolicyId | _] -> linked;
        [] -> not_found
    end.

security_policy_id(Object) ->
    ObjectId = maps:get(id, Object, undefined),
    ObjectKind = maps:get(kind, Object, undefined),
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_demo_store:relationships(),
             maps:get(relation_type, Relationship, undefined) =:= uses_security_policy,
             maps:get(source_kind, Relationship, undefined) =:= ObjectKind,
             maps:get(source_id, Relationship, undefined) =:= ObjectId,
             maps:get(target_kind, Relationship, undefined) =:= security_policy,
             resolves(maps:get(target_id, Relationship, undefined), security_policy)] of
        [PolicyId | _] -> PolicyId;
        [] -> not_found
    end.

certificate_security_policy_id(not_found) ->
    not_found;
certificate_security_policy_id(#{kind := certificate} = Certificate) ->
    security_policy_id(Certificate);
certificate_security_policy_id(_Certificate) ->
    not_found.

linked_vpn_service_id(Device) ->
    DeviceId = maps:get(id, Device, undefined),
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_demo_store:relationships(),
             maps:get(source_kind, Relationship, undefined) =:= device,
             maps:get(source_id, Relationship, undefined) =:= DeviceId,
             maps:get(target_kind, Relationship, undefined) =:= vpn_service,
             service_relation(maps:get(relation_type, Relationship, undefined)),
             resolves(maps:get(target_id, Relationship, undefined), vpn_service)] of
        [ServiceId | _] -> ServiceId;
        [] -> not_found
    end.

certificate_verification_status(#{kind := certificate} = Certificate) ->
    case ias_certificate_replacement:successful_verification(Certificate) of
        true -> verified;
        false -> not_verified
    end;
certificate_verification_status(_Certificate) ->
    not_verified.

certificate_revocation_status(#{kind := certificate} = Certificate) ->
    case ias_certificate_revocation:revoked(Certificate) of
        true -> revoked;
        false -> active
    end;
certificate_revocation_status(_Certificate) ->
    active.

policy_consistency(_DeviceId, not_found) ->
    #{match => false,
      reason => <<"no current certificate">>};
policy_consistency(DeviceId, CertificateId) ->
    ias_policy_consistency:evaluate_policy_consistency(DeviceId, CertificateId).

missing_requirements(VpnServiceId, DevicePolicyId, CurrentCertificate,
                     CertificatePolicyId, VerificationStatus, RevocationStatus,
                     PolicyConsistency) ->
    Missing = [],
    Missing1 = missing_if(VpnServiceId =:= not_found, <<"VPN Service">>, Missing),
    Missing2 = missing_if(DevicePolicyId =:= not_found, <<"Security Policy">>, Missing1),
    Missing3 = missing_if(CurrentCertificate =:= not_found,
                          <<"Current Certificate">>, Missing2),
    Missing4 = missing_if(CertificatePolicyId =:= not_found andalso
                          CurrentCertificate =/= not_found,
                          <<"Certificate Security Policy">>, Missing3),
    Missing5 = missing_if(VerificationStatus =/= verified,
                          <<"Verified Certificate">>, Missing4),
    Missing6 = missing_if(RevocationStatus =:= revoked,
                          <<"Current Certificate Revoked">>, Missing5),
    Missing7 = missing_if(maps:get(match, PolicyConsistency, false) =:= false andalso
                          CurrentCertificate =/= not_found andalso
                          DevicePolicyId =/= not_found andalso
                          CertificatePolicyId =/= not_found,
                          <<"Policy Match">>, Missing6),
    lists:reverse(Missing7).

missing_if(true, Label, Missing) ->
    [Label | Missing];
missing_if(false, _Label, Missing) ->
    Missing.

readiness_status([]) ->
    ready;
readiness_status(_Missing) ->
    incomplete.

suggested_actions(Missing) ->
    [Action || {Requirement, Action} <- suggested_action_specs(),
               lists:member(Requirement, Missing)].

suggested_action_specs() ->
    [{<<"VPN Service">>, <<"Link VPN Service">>},
     {<<"Security Policy">>, <<"Link Security Policy">>},
     {<<"Current Certificate">>, <<"Link Certificate">>},
     {<<"Certificate Security Policy">>, <<"Link Certificate Security Policy">>},
     {<<"Verified Certificate">>, <<"Verify Current Certificate">>},
     {<<"Current Certificate Revoked">>, <<"Replace Certificate">>},
     {<<"Current Certificate Revoked">>, <<"Link New Certificate">>},
     {<<"Policy Match">>, <<"Resolve Security Policy mismatch">>}].

has_vpn_service(Device) ->
    DeviceId = maps:get(id, Device, undefined),
    lists:any(fun(Relationship) ->
        maps:get(source_kind, Relationship, undefined) =:= device andalso
            maps:get(source_id, Relationship, undefined) =:= DeviceId andalso
            maps:get(target_kind, Relationship, undefined) =:= vpn_service andalso
            service_relation(maps:get(relation_type, Relationship, undefined)) andalso
            resolves(maps:get(target_id, Relationship, undefined), vpn_service)
    end, ias_demo_store:relationships()).

service_relation(uses_service) ->
    true;
service_relation(uses_vpn_service) ->
    true;
service_relation(_RelationType) ->
    false.

is_enrollment_certificate(Certificate) ->
    maps:get(source, Certificate, undefined) =:= cmp_demo_enrollment.

issues_certificate(Certificate) ->
    CertificateId = maps:get(id, Certificate, undefined),
    lists:any(fun(Relationship) ->
        maps:get(relation_type, Relationship, undefined) =:= issues andalso
            maps:get(source_kind, Relationship, undefined) =:= certificate andalso
            maps:get(source_id, Relationship, undefined) =:= CertificateId andalso
            maps:get(target_kind, Relationship, undefined) =:= certificate andalso
            resolves(maps:get(target_id, Relationship, undefined), certificate)
    end, ias_demo_store:relationships()).

linked_device_ids(Certificate) ->
    CertificateId = maps:get(id, Certificate, undefined),
    [maps:get(source_id, Relationship, undefined)
     || Relationship <- ias_demo_store:relationships(),
        maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
        maps:get(source_kind, Relationship, undefined) =:= device,
        maps:get(target_kind, Relationship, undefined) =:= certificate,
        maps:get(target_id, Relationship, undefined) =:= CertificateId,
        resolves(maps:get(source_id, Relationship, undefined), device)].

current_certificate(Device) ->
    maps:get(current_certificate, ias_certificate_role:device_status(Device), not_found).

dedupe_warnings(Warnings) ->
    dedupe_warnings(Warnings, [], []).

dedupe_warnings([], _Seen, Acc) ->
    lists:reverse(Acc);
dedupe_warnings([#{id := Id} = Warning | Rest], Seen, Acc) ->
    case lists:member(Id, Seen) of
        true -> dedupe_warnings(Rest, Seen, Acc);
        false -> dedupe_warnings(Rest, [Id | Seen], [Warning | Acc])
    end.

certificate_id(not_found) ->
    not_found;
certificate_id(#{id := Id}) ->
    Id;
certificate_id(_) ->
    not_found.

resolves(Id, Kind) ->
    case ias_demo_store:get(Id) of
        {ok, #{kind := Kind}} -> true;
        _ -> false
    end.
