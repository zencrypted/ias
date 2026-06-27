-module(ias_provisioning_wizard_draft_store).

-export([ensure/0, put/1, get/1, delete/1, all/0, validate_all/0, reset/0]).

-include("ias_provisioning_wizard_draft.hrl").

-define(TABLE, ias_provisioning_wizard_draft).
-define(SCHEMA_VERSION, 1).
-define(WAIT_TIMEOUT, 5000).

ensure() ->
    case ensure_storage() of
        ok -> validate_all();
        {error, _} = Error -> Error
    end.

put(Draft) when is_map(Draft) ->
    case validate_payload(Draft) of
        ok -> write(Draft);
        {error, _} = Error -> Error
    end;
put(_) -> {error, invalid_wizard_draft}.

get(Id0) ->
    Id = normalize_id(Id0),
    case transaction(fun() -> mnesia:read(?TABLE, Id, read) end) of
        {ok, []} -> not_found;
        {ok, [Record]} ->
            case validate_record(Record) of
                ok -> {ok, Record#ias_provisioning_wizard_draft.payload};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

delete(Id0) ->
    Id = normalize_id(Id0),
    case transaction(fun() -> mnesia:delete({?TABLE, Id}) end) of
        {ok, ok} -> ok;
        {error, _} = Error -> Error
    end.

all() ->
    case transaction(fun() -> mnesia:match_object(#ias_provisioning_wizard_draft{_ = '_'}) end) of
        {ok, Records} ->
            case validate_records(Records) of
                ok -> {ok, [R#ias_provisioning_wizard_draft.payload || R <- lists:sort(fun compare/2, Records)]};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_all() ->
    case all() of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

reset() ->
    case ensure_storage() of
        ok ->
            case mnesia:clear_table(?TABLE) of
                {atomic, ok} -> ok;
                {aborted, Reason} -> {error, {wizard_draft_reset_failed, Reason}}
            end;
        {error, _} = Error -> Error
    end.

write(Draft) ->
    Id = normalize_id(maps:get(id, Draft)),
    Now = erlang:system_time(second),
    Status = lifecycle_status(Draft),
    Fun = fun() ->
        case mnesia:read(?TABLE, Id, write) of
            [] ->
                Record = #ias_provisioning_wizard_draft{
                    draft_id = Id, status = Status, payload = Draft,
                    created_at = Now, updated_at = Now,
                    completed_at = maps:get(completed_at, Draft, undefined),
                    abandoned_at = maps:get(abandoned_at, Draft, undefined)},
                mnesia:write(Record),
                {Record, changed};
            [Old] ->
                ok = validate_record_or_abort(Old),
                case Old#ias_provisioning_wizard_draft.payload =:= Draft of
                    true -> {Old, unchanged};
                    false ->
                        Record = Old#ias_provisioning_wizard_draft{
                            status = Status, payload = Draft,
                            revision = Old#ias_provisioning_wizard_draft.revision + 1,
                            updated_at = Now,
                            completed_at = maps:get(completed_at, Draft, undefined),
                            abandoned_at = maps:get(abandoned_at, Draft, undefined)},
                        mnesia:write(Record),
                        {Record, changed}
                end
        end
    end,
    case transaction(Fun) of
        {ok, {Record, Change}} -> {ok, Record#ias_provisioning_wizard_draft.payload, Change};
        {error, _} = Error -> Error
    end.

ensure_storage() ->
    case catch mnesia:system_info(is_running) of
        yes -> ensure_disc_schema_and_table();
        _ ->
            case mnesia:create_schema([node()]) of
                ok -> ok;
                {error, Reason0} ->
                    case contains_already_exists(Reason0) of
                        true -> ok;
                        false -> throw({wizard_draft_schema_create_failed, Reason0})
                    end
            end,
            case application:ensure_all_started(mnesia) of
                {ok, _} -> ensure_disc_schema_and_table();
                {error, Reason1} -> {error, {wizard_draft_mnesia_start_failed, Reason1}}
            end
    end.

ensure_disc_schema_and_table() ->
    case catch mnesia:table_info(schema, storage_type) of
        disc_copies -> ensure_table();
        ram_copies ->
            case mnesia:change_table_copy_type(schema, node(), disc_copies) of
                {atomic, ok} -> ensure_table();
                {aborted, Reason} ->
                    case contains_already_exists(Reason) of
                        true -> ensure_table();
                        false -> {error, {wizard_draft_schema_persistence_failed, Reason}}
                    end
            end;
        {'EXIT', Reason} -> {error, {wizard_draft_schema_unavailable, Reason}};
        Storage -> {error, {wizard_draft_invalid_schema_storage, Storage}}
    end.

ensure_table() ->
    Attrs = record_info(fields, ias_provisioning_wizard_draft),
    case mnesia:create_table(?TABLE, [{attributes, Attrs}, {record_name, ?TABLE},
                                      {type, set}, {disc_copies, [node()]}]) of
        {atomic, ok} -> wait_table();
        {aborted, Reason} ->
            case contains_already_exists(Reason) of
                true -> wait_table();
                false -> {error, {wizard_draft_table_create_failed, Reason}}
            end
    end.

wait_table() ->
    case mnesia:wait_for_tables([?TABLE], ?WAIT_TIMEOUT) of
        ok -> validate_table();
        {timeout, Tables} -> {error, {wizard_draft_table_timeout, Tables}};
        {error, Reason} -> {error, {wizard_draft_table_unavailable, Reason}}
    end.

validate_table() ->
    Expected = record_info(fields, ias_provisioning_wizard_draft),
    case {mnesia:table_info(?TABLE, attributes),
          mnesia:table_info(?TABLE, storage_type),
          mnesia:table_info(?TABLE, type)} of
        {Expected, disc_copies, set} -> ok;
        {Attributes, Storage, Type} ->
            {error, {invalid_wizard_draft_table,
                     #{attributes => Attributes, storage_type => Storage, type => Type}}}
    end.

transaction(Fun) ->
    case mnesia:transaction(Fun) of
        {atomic, Value} -> {ok, Value};
        {aborted, Reason} -> {error, normalize_abort(Reason)}
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

validate_record_or_abort(Record) ->
    case validate_record(Record) of ok -> ok; {error, Reason} -> mnesia:abort(Reason) end.

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
              ["private_key", "privatekey", "pem_body", "certificate_body",
               "csr_body", "secret", "password", "passphrase"])
    end.

lifecycle_status(Draft) ->
    case maps:get(abandoned, Draft, false) of
        true -> abandoned;
        false -> case maps:get(completed, Draft, false) of true -> completed; false -> active end
    end.

compare(A, B) -> A#ias_provisioning_wizard_draft.draft_id =< B#ias_provisioning_wizard_draft.draft_id.
normalize_abort({aborted, Reason}) -> Reason;
normalize_abort(Reason) -> Reason.
normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
normalize_id(Id) -> ias_html:text(Id).
usable_id(Id) -> is_binary(Id) andalso byte_size(Id) > 0.

contains_already_exists(already_exists) -> true;
contains_already_exists({already_exists, _}) -> true;
contains_already_exists({_, {already_exists, _}}) -> true;
contains_already_exists(Tuple) when is_tuple(Tuple) ->
    lists:any(fun contains_already_exists/1, tuple_to_list(Tuple));
contains_already_exists(List) when is_list(List) ->
    lists:any(fun contains_already_exists/1, List);
contains_already_exists(_) -> false.
