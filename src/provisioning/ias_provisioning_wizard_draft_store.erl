-module(ias_provisioning_wizard_draft_store).

-export([ensure/0,
         put/1,
         put_in_transaction/1,
         replace_in_transaction/2,
         get/1,
         delete/1,
         all/0,
         validate_all/0,
         reset/0]).

-include("ias_provisioning_wizard_draft.hrl").
-include_lib("kvs/include/metainfo.hrl").

-define(TABLE, ias_provisioning_wizard_draft).
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

put(Draft) when is_map(Draft) ->
    case validate_payload(Draft) of
        ok -> write(Draft);
        {error, _} = Error -> Error
    end;
put(_) ->
    {error, invalid_wizard_draft}.

get(Id0) ->
    Id = normalize_id(Id0),
    case ensure_storage() of
        ok -> read_payload(Id);
        {error, _} = Error -> Error
    end.

delete(Id0) ->
    Id = normalize_id(Id0),
    case ensure_storage() of
        ok ->
            case ias_kvs_transaction:run(
                   fun() -> delete_in_transaction(Id) end) of
                {ok, ok} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

all() ->
    case ensure_storage() of
        ok -> read_all();
        {error, _} = Error -> Error
    end.

validate_all() ->
    case read_all() of
        {ok, _} -> ok;
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

write(Draft) ->
    case ensure_storage() of
        ok ->
            case ias_kvs_transaction:run(
                   fun() -> put_in_transaction(Draft) end) of
                {ok, {Record, Change}} ->
                    {ok, Record#ias_provisioning_wizard_draft.payload, Change};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

%% Internal cross-store transaction hooks. The configured transaction provider
%% owns the durable boundary; all record access still goes through KVS.
put_in_transaction(Draft) when is_map(Draft) ->
    validate_payload_or_abort(Draft),
    Id = normalize_id(maps:get(id, Draft)),
    case kvs_get_record(Id) of
        not_found -> write_record_in_transaction(Draft, undefined);
        {ok, #ias_provisioning_wizard_draft{} = Old} ->
            validate_record_or_abort(Old),
            write_record_in_transaction(Draft, Old);
        {error, Reason} ->
            ias_kvs_transaction:abort(Reason)
    end;
put_in_transaction(_Draft) ->
    ias_kvs_transaction:abort(invalid_wizard_draft).

replace_in_transaction(Expected, Draft)
  when is_map(Expected), is_map(Draft) ->
    validate_payload_or_abort(Expected),
    validate_payload_or_abort(Draft),
    ExpectedId = normalize_id(maps:get(id, Expected)),
    DraftId = normalize_id(maps:get(id, Draft)),
    case ExpectedId =:= DraftId of
        false ->
            ias_kvs_transaction:abort(
              {wizard_draft_identity_mismatch, ExpectedId, DraftId});
        true ->
            case kvs_get_record(DraftId) of
                {ok, #ias_provisioning_wizard_draft{} = Old} ->
                    validate_record_or_abort(Old),
                    case Old#ias_provisioning_wizard_draft.payload =:= Expected of
                        true -> write_record_in_transaction(Draft, Old);
                        false ->
                            ias_kvs_transaction:abort(
                              {wizard_draft_conflict, DraftId})
                    end;
                not_found ->
                    ias_kvs_transaction:abort(
                      {wizard_draft_not_found, DraftId});
                {error, Reason} ->
                    ias_kvs_transaction:abort(Reason)
            end
    end;
replace_in_transaction(_Expected, _Draft) ->
    ias_kvs_transaction:abort(invalid_wizard_draft).

write_record_in_transaction(Draft, undefined) ->
    Id = normalize_id(maps:get(id, Draft)),
    Now = erlang:system_time(second),
    Record = #ias_provisioning_wizard_draft{
                draft_id = Id,
                status = lifecycle_status(Draft),
                payload = Draft,
                created_at = Now,
                updated_at = Now,
                completed_at = maps:get(completed_at, Draft, undefined),
                abandoned_at = maps:get(abandoned_at, Draft, undefined)},
    validate_record_or_abort(Record),
    kvs_put_or_abort(Record),
    {Record, changed};
write_record_in_transaction(Draft,
                            #ias_provisioning_wizard_draft{} = Old) ->
    case Old#ias_provisioning_wizard_draft.payload =:= Draft of
        true ->
            {Old, unchanged};
        false ->
            Record = Old#ias_provisioning_wizard_draft{
                       status = lifecycle_status(Draft),
                       payload = Draft,
                       revision = Old#ias_provisioning_wizard_draft.revision + 1,
                       updated_at = erlang:system_time(second),
                       completed_at = maps:get(completed_at, Draft, undefined),
                       abandoned_at = maps:get(abandoned_at, Draft, undefined)},
            validate_record_or_abort(Record),
            kvs_put_or_abort(Record),
            {Record, changed}
    end.

read_payload(Id) ->
    case kvs_get_record(Id) of
        not_found -> not_found;
        {ok, Record} ->
            case validate_record(Record) of
                ok -> {ok, Record#ias_provisioning_wizard_draft.payload};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

read_all() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) ->
            case validate_records(Records) of
                ok ->
                    Sorted = lists:sort(fun compare/2, Records),
                    {ok, [R#ias_provisioning_wizard_draft.payload
                          || R <- Sorted]};
                {error, _} = Error -> Error
            end;
        {error, Reason} ->
            {error, {wizard_draft_kvs_read_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {wizard_draft_kvs_read_failed, Reason}};
        Other ->
            {error, {wizard_draft_kvs_unexpected_result, Other}}
    end.

kvs_get_record(Id) ->
    case catch kvs:get(?TABLE, Id) of
        {ok, #ias_provisioning_wizard_draft{} = Record} -> {ok, Record};
        {error, not_found} -> not_found;
        {error, Reason} -> {error, {wizard_draft_kvs_read_failed, Reason}};
        {'EXIT', Reason} -> {error, {wizard_draft_kvs_read_failed, Reason}};
        Other -> {error, {wizard_draft_kvs_unexpected_result, Other}}
    end.

kvs_put_or_abort(Record) ->
    case catch kvs:put(Record) of
        ok -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {wizard_draft_kvs_write_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {wizard_draft_kvs_write_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {wizard_draft_kvs_write_failed, Other})
    end.

delete_in_transaction(Id) ->
    case catch kvs:delete(?TABLE, Id) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {wizard_draft_kvs_delete_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {wizard_draft_kvs_delete_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {wizard_draft_kvs_delete_failed, Other})
    end.

reset_in_transaction() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) ->
            lists:foreach(
              fun(#ias_provisioning_wizard_draft{draft_id = Id}) ->
                      delete_in_transaction(Id);
                 (Invalid) ->
                      ias_kvs_transaction:abort(
                        {wizard_draft_reset_invalid_record, Invalid})
              end,
              Records),
            ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {wizard_draft_reset_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {wizard_draft_reset_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {wizard_draft_reset_failed, Other})
    end.

validate_payload_or_abort(Draft) ->
    case validate_payload(Draft) of
        ok -> ok;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

validate_record_or_abort(Record) ->
    case validate_record(Record) of
        ok -> ok;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
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
            {error, {wizard_draft_kvs_start_failed, Reason}}
    end.

ensure_kvs_schema_modules() ->
    Existing = application:get_env(kvs, schema, []),
    Required = [kvs, kvs_stream, ias_kvs],
    application:set_env(kvs, schema, lists:usort(Existing ++ Required)).

validate_kvs_metadata() ->
    ExpectedFields = record_info(fields, ias_provisioning_wizard_draft),
    case kvs:table(?TABLE) of
        #table{fields = ExpectedFields,
               type = set,
               copy_type = disc_copies} ->
            ok;
        false ->
            {error, {wizard_draft_kvs_schema_missing, ?TABLE}};
        #table{} = Table ->
            {error,
             {invalid_wizard_draft_kvs_metadata,
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
                    {error, {wizard_draft_kvs_join_failed, Reason}};
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
                     {wizard_draft_kvs_table_unavailable, ?TABLE}};
                false ->
                    timer:sleep(10),
                    wait_for_kvs_table(Timeout, StartedAt)
            end
    end.

validate_kvs_access() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> ok;
        {error, Reason} ->
            {error, {wizard_draft_kvs_unavailable, Reason}};
        {'EXIT', Reason} ->
            {error, {wizard_draft_kvs_unavailable, Reason}};
        Other ->
            {error, {wizard_draft_kvs_unexpected_result, Other}}
    end.

validate_records([]) -> ok;
validate_records([R | Rest]) ->
    case validate_record(R) of ok -> validate_records(Rest); Error -> Error end.

validate_record(#ias_provisioning_wizard_draft{schema_version = ?SCHEMA_VERSION,
                                                draft_id = Id, status = Status,
                                                payload = Draft, revision = Revision}) ->
    case usable_id(Id) andalso lists:member(Status, [active, completed, abandoned])
         andalso is_integer(Revision) andalso Revision > 0 of
        true -> validate_payload(Draft);
        false -> {error, invalid_wizard_draft_record}
    end;
validate_record(#ias_provisioning_wizard_draft{schema_version = Version}) ->
    {error, {unsupported_wizard_draft_schema_version, Version}};
validate_record(_) -> {error, invalid_wizard_draft_record}.

validate_payload(#{id := Id} = Draft) ->
    case usable_id(normalize_id(Id)) of
        false -> {error, invalid_wizard_draft_id};
        true ->
            case forbidden_path(Draft, []) of
                none -> ok;
                Path -> {error, {forbidden_wizard_draft_material, lists:reverse(Path)}}
            end
    end;
validate_payload(_) -> {error, invalid_wizard_draft}.

forbidden_path(Map, Path) when is_map(Map) ->
    forbidden_pairs(maps:to_list(Map), Path);
forbidden_path(List, Path) when is_list(List) -> forbidden_list(List, Path, 1);
forbidden_path(Tuple, Path) when is_tuple(Tuple) -> forbidden_list(tuple_to_list(Tuple), Path, 1);
forbidden_path(_, _) -> none.

forbidden_pairs([], _) -> none;
forbidden_pairs([{Key, Value} | Rest], Path) ->
    case forbidden_key(Key) of
        true -> [Key | Path];
        false -> case forbidden_path(Value, [Key | Path]) of none -> forbidden_pairs(Rest, Path); Found -> Found end
    end.

forbidden_list([], _, _) -> none;
forbidden_list([Value | Rest], Path, Index) ->
    case forbidden_path(Value, [Index | Path]) of
        none -> forbidden_list(Rest, Path, Index + 1);
        Found -> Found
    end.

forbidden_key(Key) ->
    Text = string:lowercase(binary_to_list(normalize_id(Key))),
    case string:find(Text, "reference") =/= nomatch orelse string:find(Text, "_ref") =/= nomatch of
        true -> false;
        false -> lists:any(fun(Fragment) -> string:find(Text, Fragment) =/= nomatch end,
              ["private_key", "privatekey", "key_pem", "pem_body",
               "certificate_body", "certificate_pem", "cert_pem", "ca_pem",
               "csr_body", "csr_pem", "secret", "password", "passphrase"])
    end.

lifecycle_status(Draft) ->
    case maps:get(abandoned, Draft, false) of
        true -> abandoned;
        false -> case maps:get(completed, Draft, false) of true -> completed; false -> active end
    end.

compare(A, B) -> A#ias_provisioning_wizard_draft.draft_id =< B#ias_provisioning_wizard_draft.draft_id.
normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
normalize_id(Id) -> ias_html:text(Id).
usable_id(Id) -> is_binary(Id) andalso byte_size(Id) > 0.
