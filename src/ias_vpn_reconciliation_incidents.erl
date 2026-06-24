%%%-------------------------------------------------------------------
%% @doc Durable fail-closed ledger for IAS/VPN divergence and orphan incidents.
%%
%% Reconciliation reports remain read-only. Records are created or refreshed
%% only by an explicit scan, acknowledged against a current snapshot token, and
%% resolved only after a caller has verified that the dangerous state cleared.
%%%-------------------------------------------------------------------
-module(ias_vpn_reconciliation_incidents).

-export([ensure/0,
         reset/0,
         scan/1,
         all/0,
         get/1,
         acknowledge/5,
         resolve/5,
         token/1]).

-include("ias_vpn_reconciliation_incident.hrl").

-define(TABLE, ias_vpn_reconciliation_incident).
-define(SCHEMA_VERSION, 1).
-define(WAIT_TIMEOUT, 5000).

ensure() ->
    case ias_vpn_authority:ensure() of
        ok ->
            case ensure_table() of
                ok -> validate_all_records();
                {error, _} = Error -> Error
            end;
        {error, Reason} -> {error, {vpn_incident_authority_unavailable, Reason}}
    end.

reset() ->
    case ensure() of
        ok ->
            case mnesia:clear_table(?TABLE) of
                {atomic, ok} -> ok;
                {aborted, Reason} -> {error, {vpn_incident_reset_failed, Reason}}
            end;
        {error, _} = Error -> Error
    end.

scan(Entries) when is_list(Entries) ->
    Dangerous = [Entry || Entry <- Entries, dangerous(Entry)],
    case transaction(
           fun() ->
               [upsert_incident(Entry) || Entry <- Dangerous]
           end) of
        {ok, Records} -> {ok, [record_to_map(Record) || Record <- Records]};
        {error, Reason} -> {error, {vpn_incident_scan_failed, Reason}}
    end;
scan(_Entries) ->
    {error, invalid_reconciliation_entries}.

all() ->
    case transaction(
           fun() ->
               mnesia:foldl(
                 fun(Record, Acc) ->
                     ok = validate_record_or_abort(Record),
                     [Record | Acc]
                 end,
                 [],
                 ?TABLE)
           end) of
        {ok, Records} ->
            {ok, lists:sort(fun compare_incidents/2,
                            [record_to_map(Record) || Record <- Records])};
        {error, Reason} -> {error, {vpn_incident_read_failed, Reason}}
    end.

get(DeviceId0) ->
    DeviceId = normalize_id(DeviceId0),
    case transaction(fun() -> mnesia:read(?TABLE, DeviceId, read) end) of
        {ok, []} -> not_found;
        {ok, [Record]} ->
            case validate_record(Record) of
                ok -> {ok, record_to_map(Record)};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, {vpn_incident_read_failed, Reason}}
    end.

acknowledge(DeviceId0, Token, Actor0, Note0, CurrentEntry) ->
    DeviceId = normalize_id(DeviceId0),
    Actor = normalize_text(Actor0, <<"ias-ui-admin">>),
    Note = normalize_text(Note0, <<>>),
    CurrentToken = token(CurrentEntry),
    case dangerous(CurrentEntry) andalso valid_token(Token)
         andalso Token =:= CurrentToken of
        false -> {error, stale_or_invalid_incident_token};
        true ->
            case transaction(
                   fun() ->
                       Record0 = read_required(DeviceId, write),
                       ok = validate_record_or_abort(Record0),
                       case Record0#ias_vpn_reconciliation_incident.token =:= Token of
                           false -> mnesia:abort(stale_incident_token);
                           true ->
                               Now = now_seconds(),
                               Record = Record0#ias_vpn_reconciliation_incident{
                                          status = acknowledged,
                                          acknowledged_by = Actor,
                                          acknowledged_note = Note,
                                          acknowledged_at = Now,
                                          updated_at = Now},
                               ok = validate_record_or_abort(Record),
                               mnesia:write(Record),
                               Record
                       end
                   end) of
                {ok, Record} -> {ok, record_to_map(Record)};
                {error, Reason} -> {error, {vpn_incident_acknowledge_failed, Reason}}
            end
    end.

resolve(DeviceId0, Token, Actor0, Note0, Clearance) when is_map(Clearance) ->
    DeviceId = normalize_id(DeviceId0),
    Actor = normalize_text(Actor0, <<"ias-ui-admin">>),
    Note = normalize_text(Note0, <<>>),
    case valid_token(Token) andalso valid_clearance(Clearance) of
        false -> {error, invalid_incident_resolution};
        true ->
            case transaction(
                   fun() ->
                       Record0 = read_required(DeviceId, write),
                       ok = validate_record_or_abort(Record0),
                       case Record0#ias_vpn_reconciliation_incident.token =:= Token of
                           false -> mnesia:abort(stale_incident_token);
                           true ->
                               Now = now_seconds(),
                               Snapshot = maps:get(snapshot, Clearance, #{}),
                               Record = Record0#ias_vpn_reconciliation_incident{
                                          status = resolved,
                                          snapshot = Snapshot,
                                          resolved_by = Actor,
                                          resolved_note = Note,
                                          resolved_at = Now,
                                          updated_at = Now},
                               ok = validate_record_or_abort(Record),
                               mnesia:write(Record),
                               Record
                       end
                   end) of
                {ok, Record} -> {ok, record_to_map(Record)};
                {error, Reason} -> {error, {vpn_incident_resolve_failed, Reason}}
            end
    end;
resolve(_DeviceId, _Token, _Actor, _Note, _Clearance) ->
    {error, invalid_incident_resolution}.

token(Entry) when is_map(Entry) ->
    Snapshot = incident_snapshot(Entry),
    crypto:hash(sha256, term_to_binary(Snapshot, [deterministic]));
token(_Entry) ->
    undefined.

upsert_incident(Entry) ->
    DeviceId = normalize_id(maps:get(device_id, Entry)),
    Kind = maps:get(status, Entry),
    Reason = maps:get(reason, Entry, undefined),
    Token = token(Entry),
    Snapshot = incident_snapshot(Entry),
    Now = now_seconds(),
    case mnesia:read(?TABLE, DeviceId, write) of
        [] ->
            Record = #ias_vpn_reconciliation_incident{
                        device_id = DeviceId,
                        kind = Kind,
                        reason = Reason,
                        token = Token,
                        status = open,
                        snapshot = Snapshot,
                        first_seen = Now,
                        last_seen = Now,
                        occurrences = 1,
                        updated_at = Now},
            ok = validate_record_or_abort(Record),
            mnesia:write(Record),
            Record;
        [Record0] ->
            ok = validate_record_or_abort(Record0),
            Changed = Record0#ias_vpn_reconciliation_incident.token =/= Token,
            Reopened = Record0#ias_vpn_reconciliation_incident.status =:= resolved,
            Occurrences = case Changed orelse Reopened of
                              true -> Record0#ias_vpn_reconciliation_incident.occurrences + 1;
                              false -> Record0#ias_vpn_reconciliation_incident.occurrences
                          end,
            Status = case Changed orelse Reopened of
                         true -> open;
                         false -> Record0#ias_vpn_reconciliation_incident.status
                     end,
            Record = Record0#ias_vpn_reconciliation_incident{
                       kind = Kind,
                       reason = Reason,
                       token = Token,
                       status = Status,
                       snapshot = Snapshot,
                       last_seen = Now,
                       occurrences = Occurrences,
                       acknowledged_by = case Status of open -> undefined; _ -> Record0#ias_vpn_reconciliation_incident.acknowledged_by end,
                       acknowledged_note = case Status of open -> undefined; _ -> Record0#ias_vpn_reconciliation_incident.acknowledged_note end,
                       acknowledged_at = case Status of open -> undefined; _ -> Record0#ias_vpn_reconciliation_incident.acknowledged_at end,
                       resolved_by = case Status of open -> undefined; _ -> Record0#ias_vpn_reconciliation_incident.resolved_by end,
                       resolved_note = case Status of open -> undefined; _ -> Record0#ias_vpn_reconciliation_incident.resolved_note end,
                       resolved_at = case Status of open -> undefined; _ -> Record0#ias_vpn_reconciliation_incident.resolved_at end,
                       updated_at = Now},
            ok = validate_record_or_abort(Record),
            mnesia:write(Record),
            Record
    end.

incident_snapshot(Entry) ->
    #{device_id => normalize_id(maps:get(device_id, Entry, undefined)),
      status => maps:get(status, Entry, undefined),
      reason => maps:get(reason, Entry, undefined),
      digest_match => maps:get(digest_match, Entry, undefined),
      ias => maps:get(ias, Entry, undefined),
      vpn => maps:get(vpn, Entry, undefined)}.

dangerous(#{status := divergence}) -> true;
dangerous(#{status := orphan}) -> true;
dangerous(_) -> false.

valid_clearance(#{state := synchronized}) -> true;
valid_clearance(#{state := absent}) -> true;
valid_clearance(_) -> false.

validate_all_records() ->
    case mnesia:sync_transaction(
           fun() ->
               mnesia:foldl(
                 fun(Record, ok) -> validate_record_or_abort(Record) end,
                 ok,
                 ?TABLE)
           end) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, {vpn_incident_validation_failed, Reason}}
    end.

transaction(Fun) ->
    case ensure() of
        ok ->
            case mnesia:sync_transaction(Fun) of
                {atomic, Value} -> {ok, Value};
                {aborted, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

ensure_table() ->
    case lists:member(?TABLE, mnesia:system_info(tables)) of
        true -> wait_and_validate_table();
        false -> create_table()
    end.

create_table() ->
    Options = [{attributes, record_info(fields, ias_vpn_reconciliation_incident)},
               {disc_copies, [node()]},
               {type, set}],
    case mnesia:create_table(?TABLE, Options) of
        {atomic, ok} -> wait_and_validate_table();
        {aborted, Reason} ->
            case contains_already_exists(Reason) of
                true -> wait_and_validate_table();
                false -> {error, {vpn_incident_table_create_failed, Reason}}
            end
    end.

wait_and_validate_table() ->
    case mnesia:wait_for_tables([?TABLE], ?WAIT_TIMEOUT) of
        ok -> validate_table();
        {timeout, Tables} -> {error, {vpn_incident_table_unavailable, Tables}};
        {error, Reason} -> {error, {vpn_incident_table_unavailable, Reason}}
    end.

validate_table() ->
    Expected = record_info(fields, ias_vpn_reconciliation_incident),
    case {mnesia:table_info(?TABLE, attributes),
          mnesia:table_info(?TABLE, storage_type),
          mnesia:table_info(?TABLE, type)} of
        {Expected, disc_copies, set} -> ok;
        {Attributes, Storage, Type} ->
            {error, {vpn_incident_table_mismatch,
                     #{attributes => Attributes,
                       storage_type => Storage,
                       type => Type}}}
    end.

contains_already_exists(already_exists) -> true;
contains_already_exists(Term) when is_tuple(Term) ->
    lists:any(fun contains_already_exists/1, tuple_to_list(Term));
contains_already_exists(Term) when is_list(Term) ->
    lists:any(fun contains_already_exists/1, Term);
contains_already_exists(_) -> false.

read_required(DeviceId, Lock) ->
    case mnesia:read(?TABLE, DeviceId, Lock) of
        [Record] -> Record;
        [] -> mnesia:abort(incident_not_found)
    end.

validate_record_or_abort(Record) ->
    case validate_record(Record) of
        ok -> ok;
        {error, Reason} -> mnesia:abort({invalid_vpn_incident_record, Reason})
    end.

validate_record(#ias_vpn_reconciliation_incident{
                   device_id = DeviceId,
                   schema_version = ?SCHEMA_VERSION,
                   kind = Kind,
                   reason = Reason,
                   token = Token,
                   status = Status,
                   snapshot = Snapshot,
                   occurrences = Occurrences}) ->
    Valid = is_binary(DeviceId) andalso byte_size(DeviceId) > 0
        andalso lists:member(Kind, [divergence, orphan])
        andalso Reason =/= undefined
        andalso valid_token(Token)
        andalso lists:member(Status, [open, acknowledged, resolved])
        andalso is_map(Snapshot)
        andalso is_integer(Occurrences) andalso Occurrences > 0,
    case Valid of
        true -> ok;
        false -> {error, invalid_fields}
    end;
validate_record(#ias_vpn_reconciliation_incident{schema_version = Version}) ->
    {error, {unsupported_schema_version, Version}};
validate_record(_Record) ->
    {error, invalid_record}.

valid_token(Token) when is_binary(Token) -> byte_size(Token) =:= 32;
valid_token(_) -> false.

record_to_map(Record) ->
    #{device_id => Record#ias_vpn_reconciliation_incident.device_id,
      schema_version => Record#ias_vpn_reconciliation_incident.schema_version,
      kind => Record#ias_vpn_reconciliation_incident.kind,
      reason => Record#ias_vpn_reconciliation_incident.reason,
      token => Record#ias_vpn_reconciliation_incident.token,
      status => Record#ias_vpn_reconciliation_incident.status,
      snapshot => Record#ias_vpn_reconciliation_incident.snapshot,
      first_seen => Record#ias_vpn_reconciliation_incident.first_seen,
      last_seen => Record#ias_vpn_reconciliation_incident.last_seen,
      occurrences => Record#ias_vpn_reconciliation_incident.occurrences,
      acknowledged_by => Record#ias_vpn_reconciliation_incident.acknowledged_by,
      acknowledged_note => Record#ias_vpn_reconciliation_incident.acknowledged_note,
      acknowledged_at => Record#ias_vpn_reconciliation_incident.acknowledged_at,
      resolved_by => Record#ias_vpn_reconciliation_incident.resolved_by,
      resolved_note => Record#ias_vpn_reconciliation_incident.resolved_note,
      resolved_at => Record#ias_vpn_reconciliation_incident.resolved_at,
      updated_at => Record#ias_vpn_reconciliation_incident.updated_at}.

compare_incidents(A, B) ->
    maps:get(device_id, A) =< maps:get(device_id, B).

normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) -> ias_html:text(Id).

normalize_text(undefined, Default) -> Default;
normalize_text(<<>>, Default) -> Default;
normalize_text([], Default) -> Default;
normalize_text(Value, _Default) -> ias_html:text(Value).

now_seconds() -> erlang:system_time(second).
