-module(ias_certificate_replacement).
-export([replace/1,
         action_state/1,
         history_for_device/1,
         successful_verification/1]).

replace(DeviceId) ->
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} ->
            replace_device(Device);
        _ ->
            {error, not_found}
    end.

action_state(#{kind := device} = Device) ->
    Status = ias_certificate_role:device_status(Device),
    case maps:get(state, Status, undefined) of
        replacement_available ->
            Candidate = maps:get(candidate_certificate, Status, not_found),
            case successful_verification(Candidate) of
                true -> replace;
                false -> {blocked, <<"candidate certificate is not verified">>}
            end;
        _ ->
            not_available
    end;
action_state(_Object) ->
    not_available.

history_for_device(DeviceId) ->
    [Replacement || Relationship <- ias_demo_store:relationships(),
                    maps:get(relation_type, Relationship, undefined) =:= replaced_certificate_by,
                    maps:get(source_kind, Relationship, undefined) =:= device,
                    maps:get(source_id, Relationship, undefined) =:= DeviceId,
                    maps:get(target_kind, Relationship, undefined) =:= certificate_replacement,
                    {ok, Replacement} <- [ias_demo_store:get(maps:get(target_id, Relationship, undefined))],
                    maps:get(kind, Replacement, undefined) =:= certificate_replacement].

successful_verification(#{kind := certificate} = Certificate) ->
    lists:any(fun(Verification) ->
        maps:get(verification_status, Verification, undefined) =:= verified
    end, ias_certificate_verification:verification_history(Certificate));
successful_verification(_Certificate) ->
    false.

replace_device(Device) ->
    Status = ias_certificate_role:device_status(Device),
    case maps:get(state, Status, undefined) of
        replacement_available ->
            Current = maps:get(current_certificate, Status, not_found),
            Candidate = maps:get(candidate_certificate, Status, not_found),
            replace_with_candidate(Device, Current, Candidate);
        _ ->
            {error, no_replacement_available}
    end.

replace_with_candidate(Device, Current, Candidate) ->
    case successful_verification(Candidate) of
        false ->
            {error, candidate_certificate_not_verified};
        true ->
            do_replace(Device, Current, Candidate)
    end.

do_replace(Device, Current, Candidate) ->
    DeviceId = maps:get(id, Device, undefined),
    CurrentId = maps:get(id, Current, undefined),
    CandidateId = maps:get(id, Candidate, undefined),
    ok = remove_active_certificate_links(DeviceId),
    Replacement = replacement_object(DeviceId, CurrentId, CandidateId),
    Stored = ias_demo_store:put_runtime_object(Replacement),
    _ = ias_relationship_link:create(uses_certificate, DeviceId, CandidateId),
    _ = ias_relationship_link:create(replaced_certificate_by, DeviceId, maps:get(id, Stored)),
    _ = ias_relationship_link:create(old_certificate, maps:get(id, Stored), CurrentId),
    _ = ias_relationship_link:create(new_certificate, maps:get(id, Stored), CandidateId),
    {ok, Stored}.

remove_active_certificate_links(DeviceId) ->
    [ok = ias_demo_store:delete_relationship(maps:get(id, Relationship, undefined))
     || Relationship <- ias_demo_store:relationships(),
        maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
        maps:get(source_kind, Relationship, undefined) =:= device,
        maps:get(source_id, Relationship, undefined) =:= DeviceId,
        maps:get(target_kind, Relationship, undefined) =:= certificate],
    ok.

replacement_object(DeviceId, OldCertificateId, NewCertificateId) ->
    Id = replacement_id(DeviceId),
    #{id => Id,
      kind => certificate_replacement,
      source => certificate_replacement_demo,
      import_id => Id,
      device_id => DeviceId,
      old_certificate_id => OldCertificateId,
      new_certificate_id => NewCertificateId,
      status => completed,
      created_at => created_at(),
      private_key_stored => false,
      certificate_body_stored => false}.

replacement_id(DeviceId) ->
    ias_html:join([<<"certificate_replacement_">>,
                   ias_html:text(DeviceId), <<"_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
