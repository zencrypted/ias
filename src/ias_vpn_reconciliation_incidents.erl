%%%-------------------------------------------------------------------
%% @doc Durable fail-closed ledger for IAS/VPN divergence and orphan incidents.
%%
%% Storage access is KVS-only. Reconciliation reports remain read-only;
%% records are changed only by explicit scan/acknowledge/resolve operations.
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
-include_lib("kvs/include/metainfo.hrl").

-define(TABLE, ias_vpn_reconciliation_incident).
-define(SCHEMA_VERSION, 1).
-define(WAIT_TIMEOUT, 5000).

ensure() ->
    case ias_vpn_authority:ensure() of
        ok ->
            case ensure_storage() of
                ok ->
                    case ias_kvs_transaction:ensure() of
                        ok -> validate_all_records();
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, Reason} -> {error, {vpn_incident_authority_unavailable, Reason}}
    end.

reset() ->
    case transaction(fun reset_in_transaction/0) of
        {ok, ok} -> ok;
        {error, Reason} -> {error, {vpn_incident_reset_failed, Reason}}
    end.

scan(Entries) when is_list(Entries) ->
    Dangerous = [Entry || Entry <- Entries, dangerous(Entry)],
    case transaction(fun() -> [upsert_incident(Entry) || Entry <- Dangerous] end) of
        {ok, Records} -> {ok, [record_to_map(Record) || Record <- Records]};
        {error, Reason} -> {error, {vpn_incident_scan_failed, Reason}}
    end;
scan(_Entries) ->
    {error, invalid_reconciliation_entries}.

all() ->
    case ensure_storage() of
        ok ->
            case read_records() of
                {ok, Records} ->
                    case validate_records(Records) of
                        ok ->
                            {ok, lists:sort(fun compare_incidents/2,
                                            [record_to_map(Record)
                                             || Record <- Records])};
                        {error, Reason} ->
                            {error, {vpn_incident_read_failed, Reason}}
                    end;
                {error, Reason} -> {error, {vpn_incident_read_failed, Reason}}
            end;
        {error, Reason} -> {error, {vpn_incident_read_failed, Reason}}
    end.

get(DeviceId0) ->
    DeviceId = normalize_id(DeviceId0),
    case ensure_storage() of
        ok ->
            case kvs_get_record(DeviceId) of
                not_found -> not_found;
                {ok, Record} ->
                    case validate_record(Record) of
                        ok -> {ok, record_to_map(Record)};
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} -> {error, {vpn_incident_read_failed, Reason}}
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
                       Record0 = read_required(DeviceId),
                       validate_record_or_abort(Record0),
                       case Record0#ias_vpn_reconciliation_incident.token =:= Token of
                           false -> ias_kvs_transaction:abort(stale_incident_token);
                           true ->
                               Now = now_seconds(),
                               Record = Record0#ias_vpn_reconciliation_incident{
                                          status = acknowledged,
                                          acknowledged_by = Actor,
                                          acknowledged_note = Note,
                                          acknowledged_at = Now,
                                          updated_at = Now},
                               validate_record_or_abort(Record),
                               kvs_put_or_abort(Record),
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
                       Record0 = read_required(DeviceId),
                       validate_record_or_abort(Record0),
                       case Record0#ias_vpn_reconciliation_incident.token =:= Token of
                           false -> ias_kvs_transaction:abort(stale_incident_token);
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
                               validate_record_or_abort(Record),
                               kvs_put_or_abort(Record),
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
    case kvs_get_record(DeviceId) of
        not_found ->
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
            validate_record_or_abort(Record),
            kvs_put_or_abort(Record),
            Record;
        {ok, Record0} ->
            validate_record_or_abort(Record0),
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
                       acknowledged_by = reset_if_open(Status,
                                                       undefined,
                                                       Record0#ias_vpn_reconciliation_incident.acknowledged_by),
                       acknowledged_note = reset_if_open(Status,
                                                         undefined,
                                                         Record0#ias_vpn_reconciliation_incident.acknowledged_note),
                       acknowledged_at = reset_if_open(Status,
                                                       undefined,
                                                       Record0#ias_vpn_reconciliation_incident.acknowledged_at),
                       resolved_by = reset_if_open(Status,
                                                   undefined,
                                                   Record0#ias_vpn_reconciliation_incident.resolved_by),
                       resolved_note = reset_if_open(Status,
                                                     undefined,
                                                     Record0#ias_vpn_reconciliation_incident.resolved_note),
                       resolved_at = reset_if_open(Status,
                                                   undefined,
                                                   Record0#ias_vpn_reconciliation_incident.resolved_at),
                       updated_at = Now},
            validate_record_or_abort(Record),
            kvs_put_or_abort(Record),
            Record;
        {error, Reason0} ->
            ias_kvs_transaction:abort(Reason0)
    end.

reset_if_open(open, Value, _Existing) -> Value;
reset_if_open(_Status, _Value, Existing) -> Existing.

incident_snapshot(Entry) ->
    #{device_id => normalize_id(maps:get(device_id, Entry, undefined)),
      status => maps:get(status, Entry, undefined),
      reason => maps:get(reason, Entry, undefined),
      digest_match => maps:get(digest_match, Entry, undefined),
      recoverable => maps:get(recoverable, Entry, false),
      recovery => maps:get(recovery, Entry, undefined),
      ias => maps:get(ias, Entry, undefined),
      vpn => maps:get(vpn, Entry, undefined)}.

dangerous(#{status := divergence}) -> true;
dangerous(#{status := orphan}) -> true;
dangerous(_) -> false.

valid_clearance(#{state := synchronized}) -> true;
valid_clearance(#{state := absent}) -> true;
valid_clearance(_) -> false.

validate_all_records() ->
    case read_records() of
        {ok, Records} ->
            case validate_records(Records) of
                ok -> ok;
                {error, Reason} -> {error, {vpn_incident_validation_failed, Reason}}
            end;
        {error, Reason} -> {error, {vpn_incident_validation_failed, Reason}}
    end.

transaction(Fun) ->
    case ensure_storage() of
        ok -> ias_kvs_transaction:run(Fun);
        {error, Reason} -> {error, Reason}
    end.

reset_in_transaction() ->
    case read_records() of
        {ok, Records} ->
            lists:foreach(
              fun(#ias_vpn_reconciliation_incident{device_id = DeviceId}) ->
                      kvs_delete_or_abort(DeviceId);
                 (Invalid) ->
                      ias_kvs_transaction:abort({vpn_incident_reset_invalid_record,
                                                 Invalid})
              end,
              Records),
            ok;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

read_required(DeviceId) ->
    case kvs_get_record(DeviceId) of
        {ok, Record} -> Record;
        not_found -> ias_kvs_transaction:abort(incident_not_found);
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

validate_record_or_abort(Record) ->
    case validate_record(Record) of
        ok -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort({invalid_vpn_incident_record, Reason})
    end.

validate_records([]) -> ok;
validate_records([Record | Rest]) ->
    case validate_record(Record) of
        ok -> validate_records(Rest);
        {error, _} = Error -> Error
    end.

read_records() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> {ok, Records};
        {error, Reason} -> {error, {vpn_incident_kvs_read_failed, Reason}};
        {'EXIT', Reason} -> {error, {vpn_incident_kvs_read_failed, Reason}};
        Other -> {error, {vpn_incident_kvs_unexpected_result, Other}}
    end.

kvs_get_record(DeviceId) ->
    case catch kvs:get(?TABLE, DeviceId) of
        {ok, #ias_vpn_reconciliation_incident{} = Record} -> {ok, Record};
        {error, not_found} -> not_found;
        {error, Reason} -> {error, {vpn_incident_kvs_read_failed, Reason}};
        {'EXIT', Reason} -> {error, {vpn_incident_kvs_read_failed, Reason}};
        Other -> {error, {vpn_incident_kvs_unexpected_result, Other}}
    end.

kvs_put_or_abort(Record) ->
    case catch kvs:put(Record) of
        ok -> ok;
        {ok, _} -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort({vpn_incident_kvs_write_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort({vpn_incident_kvs_write_failed, Reason});
        Other ->
            ias_kvs_transaction:abort({vpn_incident_kvs_unexpected_result, Other})
    end.

kvs_delete_or_abort(DeviceId) ->
    case catch kvs:delete(?TABLE, DeviceId) of
        ok -> ok;
        {ok, _} -> ok;
        {error, not_found} -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort({vpn_incident_kvs_delete_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort({vpn_incident_kvs_delete_failed, Reason});
        Other ->
            ias_kvs_transaction:abort({vpn_incident_kvs_unexpected_result, Other})
    end.

ensure_storage() ->
    case application:ensure_all_started(kvs) of
        {ok, _Started} ->
            ok = ensure_kvs_schema_modules(),
            case validate_kvs_metadata() of
                ok -> ensure_kvs_table();
                {error, _} = Error -> Error
            end;
        {error, Reason} -> {error, {vpn_incident_kvs_start_failed, Reason}}
    end.

ensure_kvs_schema_modules() ->
    Existing = application:get_env(kvs, schema, []),
    Required = [kvs, kvs_stream, ias_kvs],
    application:set_env(kvs, schema, lists:usort(Existing ++ Required)).

validate_kvs_metadata() ->
    ExpectedFields = record_info(fields, ias_vpn_reconciliation_incident),
    case kvs:table(?TABLE) of
        #table{fields = ExpectedFields, type = set, copy_type = disc_copies} -> ok;
        false -> {error, {vpn_incident_kvs_schema_missing, ?TABLE}};
        #table{} = Table ->
            {error,
             {invalid_vpn_incident_kvs_metadata,
              #{fields => Table#table.fields,
                type => Table#table.type,
                copy_type => Table#table.copy_type}}}
    end.

ensure_kvs_table() ->
    case validate_kvs_access() of
        ok -> ok;
        {error, _} ->
            case catch kvs:join() of
                {'EXIT', Reason} -> {error, {vpn_incident_kvs_join_failed, Reason}};
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
                true -> {error, {vpn_incident_kvs_table_unavailable, ?TABLE}};
                false ->
                    timer:sleep(10),
                    wait_for_kvs_table(Timeout, StartedAt)
            end
    end.

validate_kvs_access() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> ok;
        {error, Reason} -> {error, Reason};
        {'EXIT', Reason} -> {error, Reason};
        Other -> {error, {unexpected_kvs_access_result, Other}}
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
