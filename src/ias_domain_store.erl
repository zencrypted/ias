-module(ias_domain_store).

-export([ensure/0,
         put/1,
         get/2,
         delete/2,
         all/0,
         transaction/1,
         put_in_transaction/1,
         validate_all/0,
         reset/0]).

-include("ias_domain_object.hrl").
-include_lib("kvs/include/metainfo.hrl").

-define(TABLE, ias_domain_object).
-define(SCHEMA_VERSION, 1).
-define(WAIT_TIMEOUT, 5000).
-define(TRANSACTION_CONTEXT, ias_domain_store_kvs_transaction).

ensure() ->
    case ensure_storage() of
        ok -> validate_all();
        {error, _} = Error -> Error
    end.

put(Object) when is_map(Object) ->
    case persistent_projection(Object) of
        {ok, Projection} ->
            case transaction(fun() -> write_projection(Projection) end) of
                {ok, {Record, Change}} ->
                    {ok, record_to_map(Record), Change};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
put(_Object) ->
    {error, invalid_domain_object}.

%% Internal cross-store transaction hook. The caller must already be inside a
%% Mnesia transaction that owns the ias_domain_object table lock boundary.
%% No ETS projection is performed here.
put_in_transaction(Object) when is_map(Object) ->
    case persistent_projection(Object) of
        {ok, Projection} ->
            write_projection_in_transaction(Projection);
        {error, Reason} ->
            mnesia:abort(Reason)
    end;
put_in_transaction(_Object) ->
    mnesia:abort(invalid_domain_object).

get(Kind0, ObjectId0) ->
    case normalize_identity(Kind0, ObjectId0) of
        {ok, Kind, ObjectId} ->
            case read_record({Kind, ObjectId}) of
                not_found ->
                    not_found;
                {ok, #ias_domain_object{} = Record} ->
                    {ok, record_to_map(Record)};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

delete(Kind0, ObjectId0) ->
    case normalize_identity(Kind0, ObjectId0) of
        {ok, Kind, ObjectId} ->
            Key = {Kind, ObjectId},
            case transaction(
                   fun() ->
                       ok = ensure_not_referenced_or_abort(Kind, ObjectId),
                       stage_delete(Key),
                       ok
                   end) of
                {ok, ok} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

all() ->
    case transaction(
           fun() ->
               Records = current_records(),
               ok = validate_record_set_or_abort(Records),
               [record_to_map(Record) || Record <- Records]
           end) of
        {ok, Records} ->
            {ok, lists:sort(fun compare_records/2, Records)};
        {error, _} = Error ->
            Error
    end.

transaction(Fun) when is_function(Fun, 0) ->
    case erlang:get(?TRANSACTION_CONTEXT) of
        #{current := _} ->
            {ok, Fun()};
        undefined ->
            outer_transaction(Fun)
    end;
transaction(_Fun) ->
    {error, invalid_domain_transaction}.

validate_all() ->
    case transaction(
           fun() ->
               ok = validate_record_set_or_abort(current_records()),
               ok
           end) of
        {ok, ok} -> ok;
        {error, _} = Error -> Error
    end.

reset() ->
    case ensure_storage() of
        ok -> reset_kvs_records();
        {error, _} = Error -> Error
    end.

outer_transaction(Fun) ->
    case ensure_storage() of
        ok ->
            case load_kvs_record_map() of
                {ok, Original} ->
                    erlang:put(?TRANSACTION_CONTEXT,
                               #{original => Original, current => Original}),
                    try
                        Result = Fun(),
                        case Result of
                            {error, AbortReason} ->
                                {error, AbortReason};
                            _ ->
                                Current = current_record_map(),
                                ok = validate_record_set_or_abort(maps:values(Current)),
                                case commit_kvs_changes(Original, Current) of
                                    ok -> {ok, Result};
                                    {error, _} = Error -> Error
                                end
                        end
                    catch
                        throw:{domain_store_abort, Reason} ->
                            {error, Reason};
                        Class:Reason:Stacktrace ->
                            {error,
                             {domain_store_transaction_failed,
                              {Class, Reason, Stacktrace}}}
                    after
                        erlang:erase(?TRANSACTION_CONTEXT)
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

write_projection(Projection) ->
    Kind = maps:get(kind, Projection),
    ObjectId = normalize_id(maps:get(id, Projection)),
    Key = {Kind, ObjectId},
    ok = validate_relationship_projection_or_abort(Projection),
    Now = now_seconds(),
    case lookup_record(Key) of
        not_found ->
            Record = #ias_domain_object{key = Key,
                                        kind = Kind,
                                        object_id = ObjectId,
                                        payload = Projection,
                                        revision = 1,
                                        created_at = Now,
                                        updated_at = Now},
            ok = validate_record_or_abort(Record),
            stage_record(Record),
            {Record, changed};
        #ias_domain_object{} = Record0 ->
            ok = validate_record_or_abort(Record0),
            case Record0#ias_domain_object.payload =:= Projection of
                true ->
                    {Record0, unchanged};
                false ->
                    Record = Record0#ias_domain_object{
                               payload = Projection,
                               revision = Record0#ias_domain_object.revision + 1,
                               updated_at = Now},
                    ok = validate_record_or_abort(Record),
                    stage_record(Record),
                    {Record, changed}
            end
    end.

write_projection_in_transaction(Projection) ->
    Kind = maps:get(kind, Projection),
    ObjectId = normalize_id(maps:get(id, Projection)),
    Key = {Kind, ObjectId},
    ok = validate_relationship_projection_in_transaction(Projection),
    Now = now_seconds(),
    case mnesia:read(?TABLE, Key, write) of
        [] ->
            Record = #ias_domain_object{key = Key,
                                        kind = Kind,
                                        object_id = ObjectId,
                                        payload = Projection,
                                        revision = 1,
                                        created_at = Now,
                                        updated_at = Now},
            ok = validate_record_in_transaction(Record),
            mnesia:write(Record),
            {record_to_map(Record), changed};
        [#ias_domain_object{} = Record0] ->
            ok = validate_record_in_transaction(Record0),
            case Record0#ias_domain_object.payload =:= Projection of
                true ->
                    {record_to_map(Record0), unchanged};
                false ->
                    Record = Record0#ias_domain_object{
                               payload = Projection,
                               revision = Record0#ias_domain_object.revision + 1,
                               updated_at = Now},
                    ok = validate_record_in_transaction(Record),
                    mnesia:write(Record),
                    {record_to_map(Record), changed}
            end;
        Records ->
            mnesia:abort({invalid_domain_record_set, Key, Records})
    end.

validate_relationship_projection_in_transaction(
  #{kind := relationship} = Projection) ->
    validate_reference_in_transaction(maps:get(source_kind, Projection),
                                      maps:get(source_id, Projection)),
    validate_reference_in_transaction(maps:get(target_kind, Projection),
                                      maps:get(target_id, Projection)),
    ok;
validate_relationship_projection_in_transaction(_Projection) ->
    ok.

validate_reference_in_transaction(Kind, ObjectId) ->
    case catalog_kind(Kind) of
        true ->
            ok;
        false ->
            Key = {Kind, normalize_id(ObjectId)},
            case mnesia:read(?TABLE, Key, read) of
                [#ias_domain_object{} = Record] ->
                    validate_record_in_transaction(Record);
                [] ->
                    mnesia:abort({missing_domain_reference, Kind, ObjectId});
                Records ->
                    mnesia:abort({invalid_domain_record_set, Key, Records})
            end
    end.

validate_record_in_transaction(Record) ->
    case validate_record(Record) of
        ok -> ok;
        {error, Reason} -> mnesia:abort(Reason)
    end.

persistent_projection(#{kind := Kind0, id := ObjectId0} = Object) ->
    case requested_schema_version(Object) of
        ok ->
            case normalize_identity(Kind0, ObjectId0) of
                {ok, Kind, _ObjectId} ->
                    case forbidden_material_path(Object) of
                        none ->
                            Fields = lists:usort(common_fields() ++ kind_fields(Kind)),
                            Projection0 = maps:with(Fields, Object),
                            Projection = normalize_projection(
                                           Kind,
                                           Projection0#{kind => Kind,
                                                        id => normalize_payload_id(ObjectId0)}),
                            case validate_projection(Projection) of
                                ok -> {ok, Projection};
                                {error, _} = Error -> Error
                            end;
                        Path ->
                            {error, {forbidden_domain_material, Path}}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
persistent_projection(_Object) ->
    {error, invalid_domain_object}.

requested_schema_version(Object) ->
    case maps:get(schema_version, Object, ?SCHEMA_VERSION) of
        ?SCHEMA_VERSION -> ok;
        Version -> {error, {unsupported_domain_schema_version, Version}}
    end.

normalize_identity(Kind, ObjectId0) ->
    case supported_kind(Kind) of
        false ->
            {error, {unsupported_domain_kind, Kind}};
        true ->
            ObjectId = normalize_id(ObjectId0),
            case nonempty_binary(ObjectId) of
                true -> {ok, Kind, ObjectId};
                false -> {error, invalid_domain_object_id}
            end
    end.

normalize_projection(relationship, Projection) ->
    Projection#{source_id => normalize_payload_id(
                                maps:get(source_id, Projection, undefined)),
                target_id => normalize_payload_id(
                                maps:get(target_id, Projection, undefined))};
normalize_projection(_Kind, Projection) ->
    Projection.

validate_projection(#{kind := Kind, id := ObjectId} = Projection) ->
    Checks = [supported_kind(Kind),
              usable_payload_id(ObjectId),
              safe_term(Projection)],
    case lists:all(fun(Check) -> Check =:= true end, Checks) of
        false -> {error, invalid_domain_payload};
        true -> validate_kind_projection(Kind, Projection)
    end;
validate_projection(_Projection) ->
    {error, invalid_domain_payload}.

validate_kind_projection(relationship, Projection) ->
    RelationType = maps:get(relation_type, Projection, undefined),
    SourceKind = maps:get(source_kind, Projection, undefined),
    SourceId = maps:get(source_id, Projection, undefined),
    TargetKind = maps:get(target_kind, Projection, undefined),
    TargetId = maps:get(target_id, Projection, undefined),
    Checks = [ias_relationship_graph:known_relationship_type(RelationType),
              supported_kind(SourceKind),
              usable_payload_id(SourceId),
              supported_kind(TargetKind),
              usable_payload_id(TargetId)],
    case lists:all(fun(Check) -> Check =:= true end, Checks) of
        true -> ok;
        false -> {error, invalid_domain_relationship}
    end;
validate_kind_projection(_Kind, _Projection) ->
    ok.

validate_relationship_projection_or_abort(#{kind := relationship} = Projection) ->
    validate_reference_or_abort(maps:get(source_kind, Projection),
                                maps:get(source_id, Projection)),
    validate_reference_or_abort(maps:get(target_kind, Projection),
                                maps:get(target_id, Projection)),
    ok;
validate_relationship_projection_or_abort(_Projection) ->
    ok.

validate_relationship_references_or_abort(
  #ias_domain_object{kind = relationship, payload = Projection}) ->
    validate_relationship_projection_or_abort(Projection);
validate_relationship_references_or_abort(_Record) ->
    ok.

validate_reference_or_abort(Kind, ObjectId) ->
    case catalog_kind(Kind) of
        true ->
            ok;
        false ->
            case lookup_record({Kind, normalize_id(ObjectId)}) of
                #ias_domain_object{} -> ok;
                not_found ->
                    abort({missing_domain_reference, Kind, ObjectId})
            end
    end.

ensure_not_referenced_or_abort(relationship, _ObjectId) ->
    ok;
ensure_not_referenced_or_abort(Kind, ObjectId) ->
    References =
        [RelationshipId
         || #ias_domain_object{kind = relationship,
                               object_id = RelationshipId,
                               payload = Projection} <- current_records(),
            relationship_references(Projection, Kind, ObjectId)],
    case References of
        [] -> ok;
        _ -> abort({domain_object_referenced, Kind, ObjectId,
                    lists:sort(References)})
    end.

relationship_references(Projection, Kind, ObjectId) ->
    {maps:get(source_kind, Projection, undefined),
     normalize_id(maps:get(source_id, Projection, undefined))} =:=
        {Kind, ObjectId}
        orelse
    {maps:get(target_kind, Projection, undefined),
     normalize_id(maps:get(target_id, Projection, undefined))} =:=
        {Kind, ObjectId}.

validate_record_or_abort(Record) ->
    case validate_record(Record) of
        ok -> ok;
        {error, Reason} -> abort(Reason)
    end.

validate_record(#ias_domain_object{
                   key = {Kind, ObjectId},
                   schema_version = ?SCHEMA_VERSION,
                   kind = Kind,
                   object_id = ObjectId,
                   payload = Projection,
                   revision = Revision,
                   created_at = CreatedAt,
                   updated_at = UpdatedAt}) ->
    Checks = [supported_kind(Kind),
              nonempty_binary(ObjectId),
              is_map(Projection),
              maps:get(kind, Projection, undefined) =:= Kind,
              normalize_id(maps:get(id, Projection, undefined)) =:= ObjectId,
              is_integer(Revision) andalso Revision > 0,
              is_integer(CreatedAt) andalso CreatedAt >= 0,
              is_integer(UpdatedAt) andalso UpdatedAt >= CreatedAt,
              safe_term(Projection)],
    case lists:all(fun(Check) -> Check =:= true end, Checks) of
        false -> {error, invalid_domain_record};
        true -> validate_kind_projection(Kind, Projection)
    end;
validate_record(#ias_domain_object{schema_version = Version}) ->
    {error, {unsupported_domain_schema_version, Version}};
validate_record(_Record) ->
    {error, invalid_domain_record}.

record_to_map(#ias_domain_object{} = Record) ->
    #{key => Record#ias_domain_object.key,
      schema_version => Record#ias_domain_object.schema_version,
      kind => Record#ias_domain_object.kind,
      object_id => Record#ias_domain_object.object_id,
      payload => Record#ias_domain_object.payload,
      revision => Record#ias_domain_object.revision,
      created_at => Record#ias_domain_object.created_at,
      updated_at => Record#ias_domain_object.updated_at}.

compare_records(A, B) ->
    maps:get(key, A) =< maps:get(key, B).

ensure_storage() ->
    case ensure_kvs_started() of
        ok ->
            ok = ensure_kvs_schema_modules(),
            case validate_kvs_metadata() of
                ok -> ensure_kvs_table();
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

ensure_kvs_started() ->
    case application:ensure_all_started(kvs) of
        {ok, _Started} -> ok;
        {error, Reason} -> {error, {domain_store_kvs_start_failed, Reason}}
    end.

ensure_kvs_schema_modules() ->
    Existing = application:get_env(kvs, schema, []),
    Required = [kvs, kvs_stream, ias_kvs],
    Modules = lists:usort(Existing ++ Required),
    application:set_env(kvs, schema, Modules).

validate_kvs_metadata() ->
    ExpectedFields = record_info(fields, ias_domain_object),
    case kvs:table(?TABLE) of
        #table{fields = ExpectedFields, type = set, copy_type = disc_copies} ->
            ok;
        false ->
            {error, {domain_store_kvs_schema_missing, ?TABLE}};
        #table{} = Table ->
            {error,
             {invalid_domain_store_kvs_metadata,
              #{fields => Table#table.fields,
                type => Table#table.type,
                copy_type => Table#table.copy_type}}}
    end.

ensure_kvs_table() ->
    case validate_kvs_access() of
        ok ->
            ok;
        {error, _} ->
            case catch kvs:join() of
                {'EXIT', Reason} ->
                    {error, {domain_store_kvs_join_failed, Reason}};
                _ ->
                    wait_for_kvs_table(?WAIT_TIMEOUT)
            end
    end.

wait_for_kvs_table(Timeout) ->
    wait_for_kvs_table(Timeout, erlang:monotonic_time(millisecond)).

wait_for_kvs_table(Timeout, StartedAt) ->
    case validate_kvs_access() of
        ok ->
            ok;
        {error, _} ->
            Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
            case Elapsed >= Timeout of
                true -> {error, {domain_store_kvs_table_unavailable, ?TABLE}};
                false ->
                    timer:sleep(10),
                    wait_for_kvs_table(Timeout, StartedAt)
            end
    end.

validate_kvs_access() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> ok;
        {error, Reason} -> {error, {domain_store_kvs_unavailable, Reason}};
        {'EXIT', Reason} -> {error, {domain_store_kvs_unavailable, Reason}};
        Other -> {error, {domain_store_kvs_unexpected_result, Other}}
    end.

load_kvs_record_map() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> records_to_map(Records, #{});
        {error, Reason} -> {error, {domain_store_kvs_read_failed, Reason}};
        {'EXIT', Reason} -> {error, {domain_store_kvs_read_failed, Reason}};
        Other -> {error, {domain_store_kvs_unexpected_result, Other}}
    end.

records_to_map([], Acc) ->
    {ok, Acc};
records_to_map([Record | Rest], Acc) ->
    case validate_record(Record) of
        ok ->
            Key = Record#ias_domain_object.key,
            case maps:is_key(Key, Acc) of
                true -> {error, {duplicate_domain_record, Key}};
                false -> records_to_map(Rest, Acc#{Key => Record})
            end;
        {error, Reason} ->
            {error, Reason}
    end.

current_record_map() ->
    #{current := Current} = erlang:get(?TRANSACTION_CONTEXT),
    Current.

current_records() ->
    maps:values(current_record_map()).

read_record(Key) ->
    case erlang:get(?TRANSACTION_CONTEXT) of
        #{current := _} ->
            case lookup_record(Key) of
                not_found -> not_found;
                #ias_domain_object{} = Record -> {ok, Record}
            end;
        undefined ->
            case ensure_storage() of
                ok -> kvs_get_record(Key);
                {error, _} = Error -> Error
            end
    end.

kvs_get_record(Key) ->
    case catch kvs:get(?TABLE, Key) of
        {ok, #ias_domain_object{} = Record} ->
            case validate_record(Record) of
                ok -> {ok, Record};
                {error, Reason} -> {error, Reason}
            end;
        {error, not_found} ->
            not_found;
        {error, Reason} ->
            {error, {domain_store_kvs_read_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {domain_store_kvs_read_failed, Reason}};
        Other ->
            {error, {domain_store_kvs_unexpected_result, Other}}
    end.

lookup_record(Key) ->
    maps:get(Key, current_record_map(), not_found).

stage_record(#ias_domain_object{key = Key} = Record) ->
    update_current(fun(Current) -> Current#{Key => Record} end).

stage_delete(Key) ->
    update_current(fun(Current) -> maps:remove(Key, Current) end).

update_current(Fun) ->
    Context0 = erlang:get(?TRANSACTION_CONTEXT),
    Current0 = maps:get(current, Context0),
    Context = Context0#{current => Fun(Current0)},
    erlang:put(?TRANSACTION_CONTEXT, Context),
    ok.

validate_record_set_or_abort(Records) ->
    lists:foreach(fun validate_record_or_abort/1, Records),
    lists:foreach(fun validate_relationship_references_or_abort/1, Records),
    ok.

commit_kvs_changes(Original, Current) ->
    Puts = [Record
            || {Key, Record} <- maps:to_list(Current),
               maps:get(Key, Original, undefined) =/= Record],
    Deletes = [Key
               || Key <- maps:keys(Original),
                  not maps:is_key(Key, Current)],
    case kvs_put_records(Puts) of
        ok ->
            case kvs_delete_keys(Deletes) of
                ok -> ok;
                {error, _} = Error -> rollback_after_commit_error(Original, Current, Error)
            end;
        {error, _} = Error ->
            Error
    end.

kvs_put_records([]) ->
    ok;
kvs_put_records(Records) ->
    normalize_kvs_write_result(kvs:put(Records), domain_store_kvs_write_failed).

kvs_delete_keys([]) ->
    ok;
kvs_delete_keys([Key | Rest]) ->
    case normalize_kvs_write_result(kvs:delete(?TABLE, Key),
                                    domain_store_kvs_delete_failed) of
        ok -> kvs_delete_keys(Rest);
        {error, _} = Error -> Error
    end.

normalize_kvs_write_result(ok, _Tag) ->
    ok;
normalize_kvs_write_result(Results, _Tag) when is_list(Results) ->
    case lists:all(fun(Result) -> Result =:= ok end, Results) of
        true -> ok;
        false -> {error, {domain_store_kvs_batch_failed, Results}}
    end;
normalize_kvs_write_result({error, Reason}, Tag) ->
    {error, {Tag, Reason}};
normalize_kvs_write_result(Other, Tag) ->
    {error, {Tag, Other}}.

rollback_after_commit_error(Original, Current, CommitError) ->
    Affected = lists:usort(maps:keys(Original) ++ maps:keys(Current)),
    RollbackResults = [restore_kvs_key(Key, Original) || Key <- Affected],
    case lists:all(fun(Result) -> Result =:= ok end, RollbackResults) of
        true -> CommitError;
        false -> {error, {domain_store_kvs_commit_and_rollback_failed,
                          CommitError, RollbackResults}}
    end.

restore_kvs_key(Key, Original) ->
    case maps:find(Key, Original) of
        {ok, Record} ->
            normalize_kvs_write_result(kvs:put(Record),
                                       domain_store_kvs_rollback_write_failed);
        error ->
            normalize_kvs_write_result(kvs:delete(?TABLE, Key),
                                       domain_store_kvs_rollback_delete_failed)
    end.

reset_kvs_records() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) ->
            reset_kvs_records(Records);
        {error, Reason} ->
            {error, {domain_store_reset_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {domain_store_reset_failed, Reason}};
        Other ->
            {error, {domain_store_reset_failed, Other}}
    end.

reset_kvs_records([]) ->
    ok;
reset_kvs_records([#ias_domain_object{key = Key} | Rest]) ->
    case kvs:delete(?TABLE, Key) of
        ok -> reset_kvs_records(Rest);
        {error, Reason} -> {error, {domain_store_reset_failed, Reason}};
        Other -> {error, {domain_store_reset_failed, Other}}
    end;
reset_kvs_records([Invalid | _Rest]) ->
    {error, {domain_store_reset_failed, {invalid_domain_record, Invalid}}}.

abort(Reason) ->
    throw({domain_store_abort, Reason}).

forbidden_material_path(Term) ->
    forbidden_material_path(Term, []).

forbidden_material_path(Map, Path) when is_map(Map) ->
    forbidden_map_entries(maps:to_list(Map), Path);
forbidden_material_path(List, Path) when is_list(List) ->
    case byte_string(List) of
        true -> forbidden_material_path(list_to_binary(List), Path);
        false -> forbidden_list_entries(List, Path, 1)
    end;
forbidden_material_path(Tuple, Path) when is_tuple(Tuple) ->
    forbidden_list_entries(tuple_to_list(Tuple), Path, 1);
forbidden_material_path(Binary, Path) when is_binary(Binary) ->
    case sensitive_binary(Binary) of
        true -> lists:reverse([sensitive_value | Path]);
        false -> none
    end;
forbidden_material_path(_Term, _Path) ->
    none.

forbidden_map_entries([], _Path) ->
    none;
forbidden_map_entries([{Key, Value} | Rest], Path) ->
    case forbidden_key(Key) andalso
         not safe_material_metadata_entry(Key, Value, Path) of
        true ->
            lists:reverse([Key | Path]);
        false ->
            case forbidden_material_path(Value, [Key | Path]) of
                none -> forbidden_map_entries(Rest, Path);
                Found -> Found
            end
    end.

safe_material_metadata_entry(Key, Value, [Container]) ->
    normalized_key_name(Key) =:= <<"private_key">> andalso
        safe_private_key_metadata_value(normalized_key_name(Container), Value);
safe_material_metadata_entry(_Key, _Value, _Path) ->
    false.

safe_private_key_metadata_value(<<"material_requirements">>, Value) ->
    lists:member(Value, [pending_one_time_generation, device_owned, undefined]);
safe_private_key_metadata_value(<<"material_sources">>, Value) ->
    lists:member(Value, [provisioning_transaction, device, undefined]);
safe_private_key_metadata_value(<<"material_components">>, Value) ->
    lists:member(Value,
                 [pending_one_time_generation, available_on_device,
                  missing_private_key_ref, unsupported_private_key_provider,
                  invalid_private_key_ref, unavailable, blocked, device_owned]);
safe_private_key_metadata_value(_Container, _Value) ->
    false.

forbidden_list_entries([], _Path, _Index) ->
    none;
forbidden_list_entries([Value | Rest], Path, Index) ->
    case forbidden_material_path(Value, [Index | Path]) of
        none -> forbidden_list_entries(Rest, Path, Index + 1);
        Found -> Found
    end.

byte_string([]) -> false;
byte_string(List) ->
    lists:all(fun(Value) -> is_integer(Value) andalso Value >= 0 andalso Value =< 255 end,
              List).

sensitive_binary(Binary) ->
    Markers = [<<"-----BEGIN PRIVATE KEY">>,
               <<"-----BEGIN RSA PRIVATE KEY">>,
               <<"-----BEGIN EC PRIVATE KEY">>,
               <<"<key>">>,
               <<"<tls-auth>">>,
               <<"<tls-crypt>">>],
    lists:any(fun(Marker) -> binary:match(Binary, Marker) =/= nomatch end,
              Markers).

safe_term(Term) when is_map(Term) ->
    lists:all(fun({Key, Value}) -> safe_term(Key) andalso safe_term(Value) end,
              maps:to_list(Term));
safe_term(Term) when is_list(Term) ->
    lists:all(fun safe_term/1, Term);
safe_term(Term) when is_tuple(Term) ->
    safe_term(tuple_to_list(Term));
safe_term(Term) when is_pid(Term); is_port(Term); is_reference(Term); is_function(Term) ->
    false;
safe_term(_Term) ->
    true.

forbidden_key(Key) ->
    forbidden_key_name(normalized_key_name(Key)).

normalized_key_name(Key) when is_atom(Key) ->
    atom_to_binary(Key, utf8);
normalized_key_name(Key) when is_binary(Key) ->
    Key;
normalized_key_name(Key) when is_list(Key) ->
    unicode:characters_to_binary(Key);
normalized_key_name(_Key) ->
    <<>>.

forbidden_key_name(Name) ->
    lists:member(Name,
                 [<<"private_key">>,
                  <<"private_key_body">>,
                  <<"private_key_pem">>,
                  <<"private_key_path">>,
                  <<"key_pem">>,
                  <<"certificate_body">>,
                  <<"certificate_pem">>,
                  <<"cert_pem">>,
                  <<"ca_body">>,
                  <<"ca_pem">>,
                  <<"ca_certificate_body">>,
                  <<"ca_certificate_pem">>,
                  <<"csr_body">>,
                  <<"csr_pem">>,
                  <<"tls_auth_body">>,
                  <<"tls_crypt_body">>,
                  <<"shared_secret">>,
                  <<"psk">>,
                  <<"session_key">>,
                  <<"session_keys">>,
                  <<"ecdh_private">>,
                  <<"runtime_config">>,
                  <<"ovpn">>,
                  <<"ovpn_body">>,
                  <<"ovpn_profile">>,
                  <<"artifact_body">>]).

supported_kind(device) -> true;
supported_kind(certificate) -> true;
supported_kind(certificate_replacement) -> true;
supported_kind(certificate_revocation) -> true;
supported_kind(vpn_service) -> true;
supported_kind(verification) -> true;
supported_kind(security_policy) -> true;
supported_kind(relationship) -> true;
supported_kind(cmp_enrollment_result) -> true;
supported_kind(user) -> true;
supported_kind(security_profile) -> true;
supported_kind(ovpn_provisioning) -> true;
supported_kind(_) -> false.

catalog_kind(user) -> true;
catalog_kind(security_profile) -> true;
catalog_kind(security_policy) -> true;
catalog_kind(_) -> false.

common_fields() ->
    [id, kind, source, import_id, created_at, updated_at, name, description].

kind_fields(device) ->
    [owner, user_id, type, endpoint, remote_host, common_name,
     device_name, hostname, imported_ovpn_device_name, service_name,
     transport, tunnel_device,
     private_key_provider, private_key_ref, private_key_stored,
     certificate_body_stored, ca_body_stored, profile_id,
     security_profile_id, security_policy_id, certificate,
     certificate_id, certificate_ids,
     vpn_service_id, vpn_service_ids, ca_certificate_id,
     certificate_status, device_status, status, serial, manufacturer,
     model, services, peer_id, public_key_fingerprint,
     runtime_peer_id, vpn_peer, vpn_allocation_id,
     vpn_allocator_instance_id, vpn_client_peer_id, vpn_gateway_peer_id,
     vpn_allocation_slot, vpn_allocation_generation, vpn_allocation_state,
     vpn_allocation_persistence, vpn_allocation_created_at,
     vpn_dynamic_pair_state, vpn_dynamic_pair_reconciled_at,
     vpn_runtime_certificate_fingerprint, vpn_last_decommission,
     vpn_decommission_history, vpn_decommissioned_at];
kind_fields(certificate) ->
    [user, user_id, user_name, profile, profile_id, subject, subject_cn,
     issuer, issuer_cn, serial, not_before, not_after, fingerprint_sha256,
     requested_cn, enrollment_cn, cmp_server,
     public_key_fingerprint, csr_fingerprint, csr_public_key_fingerprint,
     certificate_public_key_fingerprint, role, services, attributes,
     trust_level, device_lock, two_factor, source_certificate_id, peer_id,
     trusted, key_match, material_type, certificate_role,
     certificate_status, status, security_policy_id, owner, device,
     device_id, enrollment_id,
     private_key_reference,
     key_rotation, issued_via, ca_present, client_certificate_present,
     private_key_present, tls_auth_present, private_key_stored,
     certificate_body_stored, ca_body_stored];
kind_fields(certificate_replacement) ->
    [device_id, old_certificate_id, new_certificate_id, status,
     private_key_stored, certificate_body_stored];
kind_fields(certificate_revocation) ->
    [certificate_id, reason, status, private_key_stored,
     certificate_body_stored];
kind_fields(vpn_service) ->
    [service, remote, remote_host, remote_port, protocol, cipher,
     compression, routes, tls_auth, endpoint, port, transport,
     certificate_id, certificate_ids, ca_certificate_id,
     security_profile_id, security_policy_id, service_name, owners];
kind_fields(verification) ->
    [certificate_id, certificate_subject, verification_status,
     authorization_status, resolved_profile, resolved_policy, trusted,
     key_match];
kind_fields(security_policy) ->
    [policy_id, profile, profile_id, decision, rules, requirements,
     services, attributes, trust_level, device_lock, two_factor,
     enforcement_mode, status];
kind_fields(relationship) ->
    [relationship_id, relation_type, source_kind, source_id, target_kind,
     target_id, score, warnings];
kind_fields(cmp_enrollment_result) ->
    [enrollment_id, subject, issuer, not_before, not_after, requested_cn,
     enrollment_cn, profile, cmp_server, device_id, csr_fingerprint,
     csr_public_key_fingerprint, certificate_public_key_fingerprint,
     private_key_reference, key_rotation, public_key_fingerprint,
     issued_via, private_key_stored, certificate_body_stored];
kind_fields(user) ->
    [username, display_name, email, role, profile_id, devices, status,
     attributes];
kind_fields(security_profile) ->
    [profile_id, role, certificate_role, services, attributes, trust_level,
     device_lock, two_factor, policies, enforcement_mode, status];
kind_fields(ovpn_provisioning) ->
    [provisioning_id, mode, subject_kind, subject_id, device_id,
     certificate_id, vpn_service_id, ca_certificate_id, authorization,
     authorization_reason, status, material_status, material_requirements,
     material_sources, material_components, assembly_status,
     assembly_reason, next_step, artifact_status, artifact_filename,
     delivery_status,
     private_key_policy, private_key_provider, private_key_ref,
     certificate_validation_mode, certificate_validation_bypass,
     downloaded, expires_at, private_key_stored, certificate_body_stored,
     ca_body_stored];
kind_fields(_) ->
    [].

normalize_id(undefined) -> <<>>;
normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
normalize_id(Id) -> ias_html:text(Id).

normalize_payload_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_payload_id(Id) -> Id.

usable_payload_id(Value) when is_binary(Value) -> byte_size(Value) > 0;
usable_payload_id(Value) when is_atom(Value) -> Value =/= undefined;
usable_payload_id(_Value) -> false.

nonempty_binary(Value) when is_binary(Value) -> byte_size(Value) > 0;
nonempty_binary(_) -> false.

now_seconds() -> erlang:system_time(second).
