-module(ias_graph_analysis).
-export([report/0]).

report() ->
    #{policy_mismatches => policy_mismatches(),
      verified_certificates => ias_certificate_verification:verified_certificates(),
      failed_verifications => ias_certificate_verification:failed_verifications(),
      certificates_never_verified => ias_certificate_verification:certificates_never_verified(),
      verifications_without_security_policy => verifications_without_security_policy(),
      devices_without_security_policy => devices_without_security_policy(),
      certificates_without_security_policy => certificates_without_security_policy(),
      devices_without_vpn_service => devices_without_vpn_service(),
      enrollment_certificates_without_issued_certificate =>
          enrollment_certificates_without_issued_certificate(),
      certificates_linked_to_multiple_devices => certificates_linked_to_multiple_devices(),
      devices_with_replacement_available => devices_with_replacement_available()}.

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
