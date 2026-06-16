-module(ias_certificate_revocation).
-export([revoke/1,
         revoke/2,
         revoked/1,
         revocation_for_certificate/1]).

revoke(CertificateId) ->
    revoke(CertificateId, <<"demo revocation">>).

revoke(CertificateId, Reason) ->
    case ias_demo_store:get(CertificateId) of
        {ok, #{kind := certificate} = Certificate} ->
            revoke_certificate(Certificate, Reason);
        _ ->
            {error, not_found}
    end.

revoked(#{kind := certificate} = Certificate) ->
    revocation_for_certificate(Certificate) =/= not_found;
revoked(_Certificate) ->
    false.

revocation_for_certificate(#{kind := certificate} = Certificate) ->
    CertificateId = maps:get(id, Certificate, undefined),
    case [Revocation || Relationship <- ias_demo_store:relationships(),
                         maps:get(relation_type, Relationship, undefined) =:= revoked_by,
                         maps:get(source_kind, Relationship, undefined) =:= certificate,
                         maps:get(source_id, Relationship, undefined) =:= CertificateId,
                         maps:get(target_kind, Relationship, undefined) =:= certificate_revocation,
                         {ok, Revocation} <- [ias_demo_store:get(maps:get(target_id, Relationship, undefined))],
                         maps:get(kind, Revocation, undefined) =:= certificate_revocation] of
        [Revocation | _] -> Revocation;
        [] -> not_found
    end;
revocation_for_certificate(_Object) ->
    not_found.

revoke_certificate(Certificate, Reason) ->
    case revocation_for_certificate(Certificate) of
        not_found ->
            Stored = ias_demo_store:put_runtime_object(revocation_object(Certificate, Reason)),
            _ = ias_relationship_link:create(revoked_by,
                                             maps:get(id, Certificate, undefined),
                                             maps:get(id, Stored, undefined)),
            {ok, Stored};
        Revocation ->
            {ok, Revocation}
    end.

revocation_object(Certificate, Reason) ->
    CertificateId = maps:get(id, Certificate, undefined),
    Id = revocation_id(CertificateId),
    #{id => Id,
      kind => certificate_revocation,
      source => certificate_revocation_demo,
      import_id => Id,
      certificate_id => CertificateId,
      reason => ias_html:text(Reason),
      status => completed,
      created_at => created_at(),
      private_key_stored => false,
      certificate_body_stored => false}.

revocation_id(CertificateId) ->
    ias_html:join([<<"certificate_revocation_">>,
                   ias_html:text(CertificateId), <<"_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
