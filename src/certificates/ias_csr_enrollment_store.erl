-module(ias_csr_enrollment_store).

-export([ensure/0,
         put/1,
         get/1,
         all/0,
         count/0,
         validate_all/0,
         reset/0]).

-include("ias_csr_enrollment_record.hrl").
-include_lib("kvs/include/metainfo.hrl").

-define(TABLE, ias_csr_enrollment_record).
-define(SCHEMA_VERSION, 1).
-define(WAIT_TIMEOUT, 5000).

ensure() ->
    case ensure_storage() of
        ok ->
            case ias_kvs_transaction:ensure() of
                ok -> validate_all();
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

put(State0) when is_map(State0) ->
    State = normalize_payload(State0),
    case validate_payload(State) of
        ok ->
            case ensure_storage() of
                ok ->
                    case ias_kvs_transaction:run(
                           fun() -> put_in_transaction(State) end) of
                        {ok, {Record, Change}} ->
                            {ok, record_to_map(Record), Change};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
put(_State) ->
    {error, invalid_csr_enrollment_state}.

get(Fingerprint0) ->
    Fingerprint = normalize_id(Fingerprint0),
    case ensure_storage() of
        ok -> read_payload(Fingerprint);
        {error, _} = Error -> Error
    end.

all() ->
    case ensure_storage() of
        ok -> read_all();
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

reset() ->
    case ensure_storage() of
        ok ->
            case ias_kvs_transaction:run(fun reset_in_transaction/0) of
                {ok, ok} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

put_in_transaction(State) ->
    Fingerprint = maps:get(csr_fingerprint, State),
    case kvs_get_record(Fingerprint) of
        not_found -> write_record_in_transaction(State, undefined);
        {ok, #ias_csr_enrollment_record{} = Old} ->
            validate_record_or_abort(Old),
            write_record_in_transaction(State, Old);
        {error, Reason} ->
            ias_kvs_transaction:abort(Reason)
    end.

write_record_in_transaction(State, undefined) ->
    Now = erlang:system_time(second),
    Record = #ias_csr_enrollment_record{
                csr_fingerprint = maps:get(csr_fingerprint, State),
                status = maps:get(status, State),
                retryable = maps:get(retryable, State),
                payload = State,
                created_at = Now,
                updated_at = Now},
    validate_record_or_abort(Record),
    kvs_put_or_abort(Record),
    {Record, changed};
write_record_in_transaction(State, #ias_csr_enrollment_record{} = Old) ->
    case Old#ias_csr_enrollment_record.payload =:= State of
        true ->
            {Old, unchanged};
        false ->
            Record = Old#ias_csr_enrollment_record{
                       status = maps:get(status, State),
                       retryable = maps:get(retryable, State),
                       payload = State,
                       revision = Old#ias_csr_enrollment_record.revision + 1,
                       updated_at = erlang:system_time(second)},
            validate_record_or_abort(Record),
            kvs_put_or_abort(Record),
            {Record, changed}
    end.

read_payload(Fingerprint) ->
    case kvs_get_record(Fingerprint) of
        not_found -> not_found;
        {ok, Record} ->
            case validate_record(Record) of
                ok -> {ok, record_to_map(Record)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

read_all() ->
    case read_records() of
        {ok, Records} ->
            case validate_records(Records) of
                ok ->
                    Sorted = lists:sort(fun compare/2, Records),
                    {ok, [record_to_map(Record) || Record <- Sorted]};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

read_records() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> {ok, Records};
        {error, Reason} ->
            {error, {csr_enrollment_kvs_read_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {csr_enrollment_kvs_read_failed, Reason}};
        Other ->
            {error, {csr_enrollment_kvs_unexpected_result, Other}}
    end.

kvs_get_record(Fingerprint) ->
    case catch kvs:get(?TABLE, Fingerprint) of
        {ok, #ias_csr_enrollment_record{} = Record} -> {ok, Record};
        {error, not_found} -> not_found;
        {error, Reason} ->
            {error, {csr_enrollment_kvs_read_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {csr_enrollment_kvs_read_failed, Reason}};
        Other ->
            {error, {csr_enrollment_kvs_unexpected_result, Other}}
    end.

reset_in_transaction() ->
    case read_records() of
        {ok, Records} ->
            lists:foreach(
              fun(#ias_csr_enrollment_record{csr_fingerprint = Fingerprint}) ->
                      kvs_delete_or_abort(Fingerprint);
                 (Invalid) ->
                      ias_kvs_transaction:abort(
                        {csr_enrollment_reset_invalid_record, Invalid})
              end,
              Records),
            ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(Reason)
    end.

record_to_map(#ias_csr_enrollment_record{payload = Payload}) ->
    Payload.

validate_records([]) -> ok;
validate_records([Record | Rest]) ->
    case validate_record(Record) of
        ok -> validate_records(Rest);
        {error, _} = Error -> Error
    end.

validate_record(
  #ias_csr_enrollment_record{
     schema_version = ?SCHEMA_VERSION,
     csr_fingerprint = Fingerprint,
     status = Status,
     retryable = Retryable,
     payload = Payload,
     revision = Revision,
     created_at = CreatedAt,
     updated_at = UpdatedAt}) ->
    case usable_id(Fingerprint) andalso
         valid_status(Status) andalso
         is_boolean(Retryable) andalso
         valid_retryable(Status, Retryable) andalso
         is_integer(Revision) andalso Revision > 0 andalso
         is_integer(CreatedAt) andalso CreatedAt >= 0 andalso
         is_integer(UpdatedAt) andalso UpdatedAt >= CreatedAt andalso
         payload_matches_record(Payload, Fingerprint, Status, Retryable) of
        true -> validate_payload(Payload);
        false -> {error, invalid_csr_enrollment_record}
    end;
validate_record(#ias_csr_enrollment_record{schema_version = Version}) ->
    {error, {unsupported_csr_enrollment_schema_version, Version}};
validate_record(_) ->
    {error, invalid_csr_enrollment_record}.

payload_matches_record(Payload, Fingerprint, Status, Retryable)
  when is_map(Payload) ->
    normalize_id(maps:get(csr_fingerprint, Payload, undefined)) =:=
        Fingerprint andalso
    maps:get(status, Payload, undefined) =:= Status andalso
    maps:get(retryable, Payload, undefined) =:= Retryable;
payload_matches_record(_Payload, _Fingerprint, _Status, _Retryable) ->
    false.

validate_payload(#{csr_fingerprint := Fingerprint0,
                   status := Status,
                   retryable := Retryable} = Payload) ->
    Fingerprint = normalize_id(Fingerprint0),
    case usable_id(Fingerprint) andalso
         valid_status(Status) andalso
         is_boolean(Retryable) andalso
         valid_retryable(Status, Retryable) of
        false -> {error, invalid_csr_enrollment_state};
        true ->
            case forbidden_path(Payload, []) of
                none -> ok;
                Path ->
                    {error,
                     {forbidden_csr_enrollment_material,
                      lists:reverse(Path)}}
            end
    end;
validate_payload(_) ->
    {error, invalid_csr_enrollment_state}.

normalize_payload(Payload) ->
    case maps:find(csr_fingerprint, Payload) of
        {ok, Fingerprint} ->
            Payload#{csr_fingerprint => normalize_id(Fingerprint)};
        error -> Payload
    end.

forbidden_path(Map, Path) when is_map(Map) ->
    forbidden_pairs(maps:to_list(Map), Path);
forbidden_path(List, Path) when is_list(List) ->
    forbidden_list(List, Path, 1);
forbidden_path(Tuple, Path) when is_tuple(Tuple) ->
    forbidden_list(tuple_to_list(Tuple), Path, 1);
forbidden_path(Value, Path) when is_binary(Value) ->
    case contains_pem_material(Value) of
        true -> [pem_material | Path];
        false -> none
    end;
forbidden_path(_, _) ->
    none.

forbidden_pairs([], _) -> none;
forbidden_pairs([{Key, Value} | Rest], Path) ->
    case forbidden_key(Key) of
        true -> [Key | Path];
        false ->
            case forbidden_path(Value, [Key | Path]) of
                none -> forbidden_pairs(Rest, Path);
                Found -> Found
            end
    end.

forbidden_list([], _, _) -> none;
forbidden_list([Value | Rest], Path, Index) ->
    case forbidden_path(Value, [Index | Path]) of
        none -> forbidden_list(Rest, Path, Index + 1);
        Found -> Found
    end.

forbidden_key(Key) ->
    Text = string:lowercase(binary_to_list(ias_html:text(Key))),
    IsReference = string:find(Text, "reference") =/= nomatch orelse
                  string:find(Text, "_ref") =/= nomatch,
    case IsReference of
        true -> false;
        false ->
            lists:any(
              fun(Fragment) -> string:find(Text, Fragment) =/= nomatch end,
              ["private_key", "privatekey", "key_pem", "pem_body",
               "certificate_body", "certificate_pem", "certificate_der",
               "cert_pem", "ca_body", "ca_pem", "csr_body", "csr_pem",
               "csr_der", "csr_data", "raw_csr", "raw_cmp", "cmp_body",
               "cmp_result", "cmp_response", "secret", "password",
               "passphrase"])
    end.

contains_pem_material(Value) ->
    Markers = [<<"-----BEGIN PRIVATE KEY-----">>,
               <<"-----BEGIN RSA PRIVATE KEY-----">>,
               <<"-----BEGIN EC PRIVATE KEY-----">>,
               <<"-----BEGIN ENCRYPTED PRIVATE KEY-----">>,
               <<"-----BEGIN CERTIFICATE-----">>,
               <<"-----BEGIN CERTIFICATE REQUEST-----">>],
    lists:any(fun(Marker) -> binary:match(Value, Marker) =/= nomatch end,
              Markers).

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
              {csr_enrollment_kvs_write_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {csr_enrollment_kvs_write_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {csr_enrollment_kvs_write_failed, Other})
    end.

kvs_delete_or_abort(Fingerprint) ->
    case catch kvs:delete(?TABLE, Fingerprint) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {csr_enrollment_kvs_delete_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {csr_enrollment_kvs_delete_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {csr_enrollment_kvs_delete_failed, Other})
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
            {error, {csr_enrollment_kvs_start_failed, Reason}}
    end.

ensure_kvs_schema_modules() ->
    Existing = application:get_env(kvs, schema, []),
    Required = [kvs, kvs_stream, ias_kvs],
    application:set_env(kvs, schema, lists:usort(Existing ++ Required)).

validate_kvs_metadata() ->
    ExpectedFields = record_info(fields, ias_csr_enrollment_record),
    case kvs:table(?TABLE) of
        #table{fields = ExpectedFields,
               type = set,
               copy_type = disc_copies} ->
            ok;
        false ->
            {error, {csr_enrollment_kvs_schema_missing, ?TABLE}};
        #table{} = Table ->
            {error,
             {invalid_csr_enrollment_kvs_metadata,
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
                    {error, {csr_enrollment_kvs_join_failed, Reason}};
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
                    {error, {csr_enrollment_kvs_table_unavailable, ?TABLE}};
                false ->
                    timer:sleep(10),
                    wait_for_kvs_table(Timeout, StartedAt)
            end
    end.

validate_kvs_access() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> ok;
        {error, Reason} ->
            {error, {csr_enrollment_kvs_unavailable, Reason}};
        {'EXIT', Reason} ->
            {error, {csr_enrollment_kvs_unavailable, Reason}};
        Other ->
            {error, {csr_enrollment_kvs_unexpected_result, Other}}
    end.

valid_status(submitted) -> true;
valid_status(issued) -> true;
valid_status(failed) -> true;
valid_status(_) -> false.

valid_retryable(failed, Retryable) -> is_boolean(Retryable);
valid_retryable(_, false) -> true;
valid_retryable(_, _) -> false.

compare(A, B) ->
    A#ias_csr_enrollment_record.csr_fingerprint =<
        B#ias_csr_enrollment_record.csr_fingerprint.

normalize_id(undefined) -> undefined;
normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
normalize_id(Id) -> ias_html:text(Id).

usable_id(Id) -> is_binary(Id) andalso byte_size(Id) > 0.
