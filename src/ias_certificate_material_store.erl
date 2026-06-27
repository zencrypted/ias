-module(ias_certificate_material_store).

-export([ensure/0,
         put_certificate/4,
         stage_cmp/2,
         attach_staged/2,
         get_certificate/1,
         get_staged/1,
         all/0,
         count/0,
         validate_all/0,
         delete_certificate/1,
         reset/0,
         prune_expired/0]).

-include("ias_certificate_material_record.hrl").
-include_lib("kvs/include/metainfo.hrl").

-define(TABLE, ias_certificate_material_record).
-define(SCHEMA_VERSION, 1).
-define(WAIT_TIMEOUT, 5000).
-define(DEFAULT_STAGED_TTL_SECONDS, 86400).

ensure() ->
    case ready() of
        ok ->
            case validate_all() of
                ok -> prune_expired();
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

put_certificate(CertificateId0, MaterialType, Pem0, Source) ->
    CertificateId = normalize_id(CertificateId0),
    case normalize_material(MaterialType, Pem0) of
        {ok, Pem, Fingerprint} when is_binary(CertificateId),
                                    byte_size(CertificateId) > 0 ->
            Key = {certificate, CertificateId},
            write_material(Key,
                           certificate,
                           CertificateId,
                           MaterialType,
                           Pem,
                           Fingerprint,
                           Source,
                           undefined);
        {ok, _Pem, _Fingerprint} ->
            {error, invalid_certificate_material_identity};
        {error, _} = Error -> Error
    end.

stage_cmp(EnrollmentId0, Pem0) ->
    EnrollmentId = normalize_id(EnrollmentId0),
    case normalize_material(client_certificate, Pem0) of
        {ok, Pem, Fingerprint} when is_binary(EnrollmentId),
                                    byte_size(EnrollmentId) > 0 ->
            Key = {staged_cmp, EnrollmentId},
            ExpiresAt = now_seconds() + staged_ttl_seconds(),
            write_material(Key,
                           staged_cmp,
                           EnrollmentId,
                           client_certificate,
                           Pem,
                           Fingerprint,
                           cmp_response,
                           ExpiresAt);
        {ok, _Pem, _Fingerprint} ->
            {error, invalid_certificate_material_identity};
        {error, _} = Error -> Error
    end.

attach_staged(EnrollmentId0, CertificateId0) ->
    EnrollmentId = normalize_id(EnrollmentId0),
    CertificateId = normalize_id(CertificateId0),
    case ready() of
        ok ->
            case ias_kvs_transaction:run(
                   fun() ->
                       attach_staged_in_transaction(EnrollmentId,
                                                    CertificateId)
                   end) of
                {ok, {attached, Map}} -> {ok, Map};
                {ok, expired} -> {error, staged_cmp_material_expired};
                {error, not_found} -> not_found;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

get_certificate(CertificateId0) ->
    read_material({certificate, normalize_id(CertificateId0)}).

get_staged(EnrollmentId0) ->
    read_material({staged_cmp, normalize_id(EnrollmentId0)}).

all() ->
    case ready() of
        ok ->
            case read_records() of
                {ok, Records} ->
                    case validate_records(Records) of
                        ok ->
                            Active = [Record || Record <- Records,
                                               not expired(Record)],
                            {ok, [record_to_map(Record) ||
                                  Record <- lists:sort(fun compare/2, Active)]};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

count() ->
    case all() of
        {ok, Records} -> {ok, length(Records)};
        {error, _} = Error -> Error
    end.

validate_all() ->
    case read_records() of
        {ok, Records} -> validate_records(Records);
        {error, _} = Error -> Error
    end.

delete_certificate(CertificateId0) ->
    delete_key({certificate, normalize_id(CertificateId0)}).

reset() ->
    case ensure_storage() of
        ok ->
            case ias_kvs_transaction:run(fun reset_in_transaction/0) of
                {ok, ok} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

prune_expired() ->
    case ready() of
        ok ->
            case ias_kvs_transaction:run(fun prune_expired_in_transaction/0) of
                {ok, _Count} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

write_material(Key,
               SubjectKind,
               SubjectId,
               MaterialType,
               Pem,
               Fingerprint,
               Source,
               ExpiresAt) ->
    case ready() of
        ok ->
            case ias_kvs_transaction:run(
                   fun() ->
                       write_material_in_transaction(Key,
                                                     SubjectKind,
                                                     SubjectId,
                                                     MaterialType,
                                                     Pem,
                                                     Fingerprint,
                                                     Source,
                                                     ExpiresAt)
                   end) of
                {ok, {Record, Change}} ->
                    {ok, record_to_map(Record), Change};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

write_material_in_transaction(Key,
                              SubjectKind,
                              SubjectId,
                              MaterialType,
                              Pem,
                              Fingerprint,
                              Source,
                              ExpiresAt) ->
    case kvs_get_record(Key) of
        not_found ->
            New = new_record(Key,
                             SubjectKind,
                             SubjectId,
                             MaterialType,
                             Pem,
                             Fingerprint,
                             Source,
                             ExpiresAt,
                             1,
                             now_seconds()),
            validate_record_or_abort(New),
            kvs_put_or_abort(New),
            {New, changed};
        {ok, #ias_certificate_material_record{} = Old} ->
            validate_record_or_abort(Old),
            case same_material(Old,
                               MaterialType,
                               Pem,
                               Fingerprint,
                               Source) of
                true -> {Old, unchanged};
                false ->
                    Updated = new_record(Key,
                                         SubjectKind,
                                         SubjectId,
                                         MaterialType,
                                         Pem,
                                         Fingerprint,
                                         Source,
                                         ExpiresAt,
                                         Old#ias_certificate_material_record.revision + 1,
                                         Old#ias_certificate_material_record.created_at),
                    validate_record_or_abort(Updated),
                    kvs_put_or_abort(Updated),
                    {Updated, changed}
            end;
        {error, Reason} ->
            ias_kvs_transaction:abort(Reason)
    end.

new_record(Key,
           SubjectKind,
           SubjectId,
           MaterialType,
           Pem,
           Fingerprint,
           Source,
           ExpiresAt,
           Revision,
           CreatedAt) ->
    case ias_certificate_material_protection:protect(Key, Pem) of
        {ok, Envelope} ->
            #ias_certificate_material_record{
               key = Key,
               subject_kind = SubjectKind,
               subject_id = SubjectId,
               material_type = MaterialType,
               source = Source,
               fingerprint_sha256 = Fingerprint,
               body_envelope = Envelope,
               revision = Revision,
               created_at = CreatedAt,
               updated_at = now_seconds(),
               expires_at = ExpiresAt};
        {error, Reason} ->
            ias_kvs_transaction:abort(Reason)
    end.

same_material(Record, MaterialType, Pem, Fingerprint, Source) ->
    case unprotect_record(Record) of
        {ok, ExistingPem} ->
            Record#ias_certificate_material_record.material_type =:= MaterialType andalso
            ExistingPem =:= Pem andalso
            Record#ias_certificate_material_record.fingerprint_sha256 =:= Fingerprint andalso
            Record#ias_certificate_material_record.source =:= Source andalso
            envelope_algorithm(
              Record#ias_certificate_material_record.body_envelope) =:=
                ias_certificate_material_protection:mode();
        {error, Reason} ->
            ias_kvs_transaction:abort(Reason)
    end.

attach_staged_in_transaction(EnrollmentId, CertificateId) ->
    case {usable_id(EnrollmentId), usable_id(CertificateId)} of
        {true, true} ->
            StagedKey = {staged_cmp, EnrollmentId},
            case kvs_get_record(StagedKey) of
                not_found ->
                    ias_kvs_transaction:abort(not_found);
                {ok, #ias_certificate_material_record{} = Staged} ->
                    validate_record_or_abort(Staged),
                    case expired(Staged) of
                        true ->
                            kvs_delete_or_abort(StagedKey),
                            expired;
                        false ->
                            {ok, Pem} = unprotect_record(Staged),
                            CertificateKey = {certificate, CertificateId},
                            {CertificateRecord, _Change} =
                                write_material_in_transaction(
                                  CertificateKey,
                                  certificate,
                                  CertificateId,
                                  client_certificate,
                                  Pem,
                                  Staged#ias_certificate_material_record.fingerprint_sha256,
                                  cmp_response,
                                  undefined),
                            kvs_delete_or_abort(StagedKey),
                            {attached, record_to_map(CertificateRecord)}
                    end;
                {error, Reason} ->
                    ias_kvs_transaction:abort(Reason)
            end;
        _ ->
            ias_kvs_transaction:abort(invalid_certificate_material_identity)
    end.

read_material(Key) ->
    case ready() of
        ok ->
            case kvs_get_record(Key) of
                not_found -> not_found;
                {ok, Record} ->
                    case validate_record(Record) of
                        ok ->
                            case expired(Record) of
                                false -> {ok, record_to_map(Record)};
                                true -> {error, staged_cmp_material_expired}
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

delete_key(Key) ->
    case ensure_storage() of
        ok ->
            case ias_kvs_transaction:run(
                   fun() -> kvs_delete_or_abort(Key), ok end) of
                {ok, ok} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

record_to_map(#ias_certificate_material_record{} = Record) ->
    {ok, Pem} = unprotect_record(Record),
    Base = #{material_type => Record#ias_certificate_material_record.material_type,
             encoding => Record#ias_certificate_material_record.encoding,
             source => Record#ias_certificate_material_record.source,
             stored_at => rfc3339(Record#ias_certificate_material_record.updated_at),
             fingerprint_sha256 =>
                 Record#ias_certificate_material_record.fingerprint_sha256,
             body => Pem,
             revision => Record#ias_certificate_material_record.revision,
             protection_mode => envelope_algorithm(
                                  Record#ias_certificate_material_record.body_envelope)},
    case Record#ias_certificate_material_record.subject_kind of
        certificate ->
            Base#{certificate_id => Record#ias_certificate_material_record.subject_id};
        staged_cmp ->
            Base#{enrollment_id => Record#ias_certificate_material_record.subject_id,
                  expires_at => Record#ias_certificate_material_record.expires_at}
    end.

validate_records([]) -> ok;
validate_records([Record | Rest]) ->
    case validate_record(Record) of
        ok -> validate_records(Rest);
        {error, _} = Error -> Error
    end.

validate_record(
  #ias_certificate_material_record{
     key = Key,
     schema_version = ?SCHEMA_VERSION,
     subject_kind = SubjectKind,
     subject_id = SubjectId,
     material_type = MaterialType,
     encoding = pem,
     source = Source,
     fingerprint_sha256 = Fingerprint,
     body_envelope = Envelope,
     revision = Revision,
     created_at = CreatedAt,
     updated_at = UpdatedAt,
     expires_at = ExpiresAt} = Record) ->
    case valid_identity(Key, SubjectKind, SubjectId) andalso
         valid_material_type(MaterialType) andalso
         valid_subject_material(SubjectKind, MaterialType) andalso
         Source =/= undefined andalso
         usable_id(Fingerprint) andalso
         is_map(Envelope) andalso
         is_integer(Revision) andalso Revision > 0 andalso
         is_integer(CreatedAt) andalso CreatedAt >= 0 andalso
         is_integer(UpdatedAt) andalso UpdatedAt >= CreatedAt andalso
         valid_expiry(SubjectKind, ExpiresAt, CreatedAt) of
        false -> {error, invalid_certificate_material_record};
        true -> validate_record_body(Record)
    end;
validate_record(#ias_certificate_material_record{schema_version = Version}) ->
    {error, {unsupported_certificate_material_schema_version, Version}};
validate_record(_) ->
    {error, invalid_certificate_material_record}.

validate_record_body(Record) ->
    case unprotect_record(Record) of
        {ok, Pem} ->
            MaterialType = Record#ias_certificate_material_record.material_type,
            case normalize_material(MaterialType, Pem) of
                {ok, NormalizedPem, Fingerprint} ->
                    case NormalizedPem =:= Pem andalso
                         Fingerprint =:=
                           Record#ias_certificate_material_record.fingerprint_sha256 of
                        true -> ok;
                        false -> {error, certificate_material_fingerprint_mismatch}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

unprotect_record(#ias_certificate_material_record{key = Key,
                                                    body_envelope = Envelope}) ->
    ias_certificate_material_protection:unprotect(Key, Envelope).

reset_in_transaction() ->
    case read_records() of
        {ok, Records} ->
            lists:foreach(
              fun(#ias_certificate_material_record{key = Key}) ->
                      kvs_delete_or_abort(Key);
                 (Invalid) ->
                      ias_kvs_transaction:abort(
                        {certificate_material_reset_invalid_record, Invalid})
              end,
              Records),
            ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(Reason)
    end.

prune_expired_in_transaction() ->
    case read_records() of
        {ok, Records} ->
            lists:foldl(
              fun(#ias_certificate_material_record{key = Key} = Record, Count) ->
                      case validate_record(Record) of
                          ok ->
                              case expired(Record) of
                                  true -> kvs_delete_or_abort(Key), Count + 1;
                                  false -> Count
                              end;
                          {error, Reason} ->
                              ias_kvs_transaction:abort(Reason)
                      end;
                 (Invalid, _Count) ->
                      ias_kvs_transaction:abort(
                        {invalid_certificate_material_record, Invalid})
              end,
              0,
              Records);
        {error, Reason} ->
            ias_kvs_transaction:abort(Reason)
    end.

read_records() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> {ok, Records};
        {error, Reason} ->
            {error, {certificate_material_kvs_read_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {certificate_material_kvs_read_failed, Reason}};
        Other ->
            {error, {certificate_material_kvs_unexpected_result, Other}}
    end.

kvs_get_record(Key) ->
    case catch kvs:get(?TABLE, Key) of
        {ok, #ias_certificate_material_record{} = Record} -> {ok, Record};
        {error, not_found} -> not_found;
        {error, Reason} ->
            {error, {certificate_material_kvs_read_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {certificate_material_kvs_read_failed, Reason}};
        Other ->
            {error, {certificate_material_kvs_unexpected_result, Other}}
    end.

validate_record_or_abort(Record) ->
    case validate_record(Record) of
        ok -> ok;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

kvs_put_or_abort(Record) ->
    case catch kvs:put(Record) of
        ok -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {certificate_material_kvs_write_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {certificate_material_kvs_write_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {certificate_material_kvs_write_failed, Other})
    end.

kvs_delete_or_abort(Key) ->
    case catch kvs:delete(?TABLE, Key) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {certificate_material_kvs_delete_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {certificate_material_kvs_delete_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {certificate_material_kvs_delete_failed, Other})
    end.

ready() ->
    case ensure_storage() of
        ok -> ias_certificate_material_protection:ensure();
        {error, _} = Error -> Error
    end.

ensure_storage() ->
    case application:ensure_all_started(kvs) of
        {ok, _Started} ->
            ok = ensure_kvs_schema_modules(),
            case validate_kvs_metadata() of
                ok -> ensure_kvs_table();
                {error, _} = Error -> Error
            end;
        {error, Reason} ->
            {error, {certificate_material_kvs_start_failed, Reason}}
    end.

ensure_kvs_schema_modules() ->
    Existing = application:get_env(kvs, schema, []),
    Required = [kvs, kvs_stream, ias_kvs],
    application:set_env(kvs, schema, lists:usort(Existing ++ Required)).

validate_kvs_metadata() ->
    ExpectedFields = record_info(fields, ias_certificate_material_record),
    case kvs:table(?TABLE) of
        #table{fields = ExpectedFields,
               type = set,
               copy_type = disc_copies} ->
            ok;
        false ->
            {error, {certificate_material_kvs_schema_missing, ?TABLE}};
        #table{} = Table ->
            {error,
             {invalid_certificate_material_kvs_metadata,
              #{fields => Table#table.fields,
                type => Table#table.type,
                copy_type => Table#table.copy_type}}}
    end.

ensure_kvs_table() ->
    case validate_kvs_access() of
        ok -> ok;
        {error, _} ->
            case catch kvs:join() of
                {'EXIT', Reason} ->
                    {error, {certificate_material_kvs_join_failed, Reason}};
                _ -> wait_for_kvs_table(?WAIT_TIMEOUT)
            end
    end.

wait_for_kvs_table(Timeout) ->
    wait_for_kvs_table(Timeout, erlang:monotonic_time(millisecond)).

wait_for_kvs_table(Timeout, StartedAt) ->
    case validate_kvs_access() of
        ok -> ok;
        {error, _} ->
            Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
            case Elapsed >= Timeout of
                true ->
                    {error,
                     {certificate_material_kvs_table_unavailable, ?TABLE}};
                false ->
                    timer:sleep(10),
                    wait_for_kvs_table(Timeout, StartedAt)
            end
    end.

validate_kvs_access() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> ok;
        {error, Reason} ->
            {error, {certificate_material_kvs_unavailable, Reason}};
        {'EXIT', Reason} ->
            {error, {certificate_material_kvs_unavailable, Reason}};
        Other ->
            {error, {certificate_material_kvs_unexpected_result, Other}}
    end.

normalize_material(MaterialType, Pem0) when MaterialType =:= ca_certificate;
                                            MaterialType =:= client_certificate ->
    Pem = trim(ias_html:text(Pem0)),
    case contains_private_material(Pem) of
        true -> {error, private_key_material_rejected};
        false -> decode_single_certificate(Pem)
    end;
normalize_material(_, _) ->
    {error, unsupported_material_type}.

decode_single_certificate(<<>>) ->
    {error, empty_pem};
decode_single_certificate(Pem) ->
    try public_key:pem_decode(Pem) of
        [{'Certificate', Der, _}] ->
            NormalizedPem = ensure_newline(Pem),
            {ok, NormalizedPem, fingerprint(Der)};
        [] -> {error, invalid_certificate_pem};
        _ -> {error, exactly_one_certificate_required}
    catch
        _:_ -> {error, invalid_certificate_pem}
    end.

contains_private_material(Pem) ->
    Markers = [<<"BEGIN PRIVATE KEY">>, <<"BEGIN RSA PRIVATE KEY">>,
               <<"BEGIN EC PRIVATE KEY">>, <<"BEGIN ENCRYPTED PRIVATE KEY">>],
    lists:any(fun(Marker) -> binary:match(Pem, Marker) =/= nomatch end,
              Markers).

valid_identity({certificate, SubjectId}, certificate, SubjectId) ->
    usable_id(SubjectId);
valid_identity({staged_cmp, SubjectId}, staged_cmp, SubjectId) ->
    usable_id(SubjectId);
valid_identity(_, _, _) -> false.

valid_material_type(ca_certificate) -> true;
valid_material_type(client_certificate) -> true;
valid_material_type(_) -> false.

valid_subject_material(certificate, ca_certificate) -> true;
valid_subject_material(certificate, client_certificate) -> true;
valid_subject_material(staged_cmp, client_certificate) -> true;
valid_subject_material(_, _) -> false.

valid_expiry(certificate, undefined, _CreatedAt) -> true;
valid_expiry(staged_cmp, ExpiresAt, CreatedAt) ->
    is_integer(ExpiresAt) andalso ExpiresAt > CreatedAt;
valid_expiry(_, _, _) -> false.

expired(#ias_certificate_material_record{subject_kind = staged_cmp,
                                          expires_at = ExpiresAt}) ->
    is_integer(ExpiresAt) andalso ExpiresAt =< now_seconds();
expired(_) -> false.

staged_ttl_seconds() ->
    case application:get_env(ias,
                             certificate_material_staged_ttl_seconds,
                             ?DEFAULT_STAGED_TTL_SECONDS) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> ?DEFAULT_STAGED_TTL_SECONDS
    end.

envelope_algorithm(Envelope) ->
    maps:get(algorithm, Envelope, unknown).

compare(A, B) ->
    A#ias_certificate_material_record.key =<
        B#ias_certificate_material_record.key.

fingerprint(Der) ->
    Hash = crypto:hash(sha256, Der),
    ias_html:text(string:uppercase(binary_to_list(binary:encode_hex(Hash)))).

trim(Bin) ->
    ias_html:text(string:trim(binary_to_list(Bin))).

ensure_newline(<<>>) -> <<>>;
ensure_newline(Pem) ->
    case binary:last(Pem) of
        $\n -> Pem;
        _ -> <<Pem/binary, "\n">>
    end.

rfc3339(Seconds) ->
    iolist_to_binary(
      calendar:system_time_to_rfc3339(Seconds, [{unit, second}])).

now_seconds() ->
    erlang:system_time(second).

normalize_id(undefined) -> undefined;
normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
normalize_id(Id) -> ias_html:text(Id).

usable_id(Id) -> is_binary(Id) andalso byte_size(Id) > 0.
