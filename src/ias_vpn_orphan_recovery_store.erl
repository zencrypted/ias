%%%-------------------------------------------------------------------
%% @doc Durable Stage 7C operation ledger for orphan recovery sagas.
%%
%% One latest operation is retained per Device. The immutable recovery plan is
%% bound to the incident token. Graph and authority commit are marked from the
%% same KVS transaction that creates the recovered IAS records.
%%%-------------------------------------------------------------------
-module(ias_vpn_orphan_recovery_store).

-export([ensure/0,
         reset/0,
         all/0,
         get/1,
         start_or_resume/5,
         mark_graph_committed_in_transaction/3,
         mark_reconciliation_confirmed/3,
         mark_completed/3,
         record_error/3]).

-include("ias_vpn_orphan_recovery_operation.hrl").
-include_lib("kvs/include/metainfo.hrl").

-define(TABLE, ias_vpn_orphan_recovery_operation).
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

reset() ->
    case transaction(fun reset_in_transaction/0) of
        {ok, ok} -> ok;
        {error, Reason} -> {error, {vpn_orphan_recovery_reset_failed, Reason}}
    end.

all() ->
    case ensure_storage() of
        ok ->
            case read_records() of
                {ok, Records} ->
                    case validate_records(Records) of
                        ok -> {ok, lists:sort(fun compare_operations/2,
                                             [record_to_map(R) || R <- Records])};
                        {error, Reason} ->
                            {error, {vpn_orphan_recovery_read_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {vpn_orphan_recovery_read_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {vpn_orphan_recovery_read_failed, Reason}}
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
                {error, Reason} ->
                    {error, {vpn_orphan_recovery_read_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {vpn_orphan_recovery_read_failed, Reason}}
    end.

start_or_resume(DeviceId0, Token, Plan, Actor0, Note0) when is_map(Plan) ->
    DeviceId = normalize_id(DeviceId0),
    Actor = normalize_text(Actor0, <<"ias-ui-admin">>),
    Note = normalize_text(Note0, <<>>),
    case valid_id(DeviceId) andalso valid_token(Token)
         andalso ias_vpn_orphan_recovery:validate_plan(Plan) =:= ok of
        false -> {error, invalid_vpn_orphan_recovery_operation};
        true ->
            case transaction(
                   fun() -> start_or_resume_in_transaction(DeviceId, Token,
                                                           Plan, Actor, Note)
                   end) of
                {ok, Record} -> {ok, record_to_map(Record)};
                {error, Reason} ->
                    {error, {vpn_orphan_recovery_start_failed, Reason}}
            end
    end;
start_or_resume(_DeviceId, _Token, _Plan, _Actor, _Note) ->
    {error, invalid_vpn_orphan_recovery_operation}.

%% Must be called from the wider graph+authority transaction.
mark_graph_committed_in_transaction(DeviceId0, Token, CommitSummary)
  when is_map(CommitSummary) ->
    DeviceId = normalize_id(DeviceId0),
    Record0 = read_required(DeviceId),
    validate_record_or_abort(Record0),
    verify_token_or_abort(Record0, Token),
    case Record0#ias_vpn_orphan_recovery_operation.status of
        planned ->
            Record = Record0#ias_vpn_orphan_recovery_operation{
                       status = graph_committed,
                       commit_summary = CommitSummary,
                       last_error = undefined,
                       updated_at = now_seconds()},
            validate_record_or_abort(Record),
            kvs_put_or_abort(Record),
            record_to_map(Record);
        graph_committed -> record_to_map(Record0);
        Status ->
            ias_kvs_transaction:abort(
              {vpn_orphan_recovery_status_conflict, Status})
    end;
mark_graph_committed_in_transaction(_DeviceId, _Token, _Summary) ->
    ias_kvs_transaction:abort(invalid_vpn_orphan_recovery_commit).

mark_reconciliation_confirmed(DeviceId, Token, Clearance)
  when is_map(Clearance) ->
    transition(DeviceId, Token,
               [graph_committed, reconciliation_confirmed],
               reconciliation_confirmed,
               #{clearance => Clearance, last_error => undefined});
mark_reconciliation_confirmed(_DeviceId, _Token, _Clearance) ->
    {error, invalid_vpn_orphan_recovery_clearance}.

mark_completed(DeviceId, Token, ResolvedIncident)
  when is_map(ResolvedIncident) ->
    transition(DeviceId, Token,
               [reconciliation_confirmed, completed],
               completed,
               #{resolved_incident => ResolvedIncident,
                 completed_at => now_seconds(),
                 last_error => undefined});
mark_completed(_DeviceId, _Token, _ResolvedIncident) ->
    {error, invalid_vpn_orphan_recovery_completion}.

record_error(DeviceId0, Token, Reason0) ->
    DeviceId = normalize_id(DeviceId0),
    Reason = safe_reason(Reason0),
    case transaction(
           fun() ->
               Record0 = read_required(DeviceId),
               validate_record_or_abort(Record0),
               verify_token_or_abort(Record0, Token),
               Record = Record0#ias_vpn_orphan_recovery_operation{
                          attempts = Record0#ias_vpn_orphan_recovery_operation.attempts + 1,
                          last_error = Reason,
                          updated_at = now_seconds()},
               validate_record_or_abort(Record),
               kvs_put_or_abort(Record),
               Record
           end) of
        {ok, Record} -> {ok, record_to_map(Record)};
        {error, ErrorReason} ->
            {error, {vpn_orphan_recovery_error_record_failed, ErrorReason}}
    end.

start_or_resume_in_transaction(DeviceId, Token, Plan, Actor, Note) ->
    case kvs_get_record(DeviceId) of
        not_found -> create_record(DeviceId, Token, Plan, Actor, Note);
        {ok, Record0} ->
            validate_record_or_abort(Record0),
            Same = Record0#ias_vpn_orphan_recovery_operation.incident_token =:= Token
                andalso Record0#ias_vpn_orphan_recovery_operation.plan =:= Plan,
            case {Same, Record0#ias_vpn_orphan_recovery_operation.status} of
                {true, _Status} -> Record0;
                {false, completed} -> create_record(DeviceId, Token, Plan, Actor, Note);
                {false, _Status} ->
                    ias_kvs_transaction:abort(
                      vpn_orphan_recovery_operation_in_progress)
            end;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

create_record(DeviceId, Token, Plan, Actor, Note) ->
    Now = now_seconds(),
    Record = #ias_vpn_orphan_recovery_operation{
                device_id = DeviceId,
                operation_id = operation_id(DeviceId, Token),
                incident_token = Token,
                status = planned,
                plan = Plan,
                actor = Actor,
                note = Note,
                created_at = Now,
                updated_at = Now},
    validate_record_or_abort(Record),
    kvs_put_or_abort(Record),
    Record.

transition(DeviceId0, Token, ExpectedStatuses, NewStatus, Fields) ->
    DeviceId = normalize_id(DeviceId0),
    case valid_token(Token) andalso is_map(Fields) of
        false -> {error, invalid_vpn_orphan_recovery_transition};
        true ->
            case transaction(
                   fun() ->
                       Record0 = read_required(DeviceId),
                       validate_record_or_abort(Record0),
                       verify_token_or_abort(Record0, Token),
                       Current = Record0#ias_vpn_orphan_recovery_operation.status,
                       case lists:member(Current, ExpectedStatuses) of
                           false ->
                               ias_kvs_transaction:abort(
                                 {vpn_orphan_recovery_status_conflict, Current});
                           true ->
                               Record1 = apply_transition_fields(Fields, Record0),
                               Record = Record1#ias_vpn_orphan_recovery_operation{
                                          status = NewStatus,
                                          updated_at = now_seconds()},
                               validate_record_or_abort(Record),
                               kvs_put_or_abort(Record),
                               Record
                       end
                   end) of
                {ok, Record} -> {ok, record_to_map(Record)};
                {error, Reason} ->
                    {error, {vpn_orphan_recovery_transition_failed, Reason}}
            end
    end.

apply_transition_fields(Fields, Record0) ->
    Record1 = case maps:find(clearance, Fields) of
                  {ok, Value} ->
                      Record0#ias_vpn_orphan_recovery_operation{clearance = Value};
                  error -> Record0
              end,
    Record2 = case maps:find(resolved_incident, Fields) of
                  {ok, Value2} ->
                      Record1#ias_vpn_orphan_recovery_operation{
                        resolved_incident = Value2};
                  error -> Record1
              end,
    Record3 = case maps:find(completed_at, Fields) of
                  {ok, Value3} ->
                      Record2#ias_vpn_orphan_recovery_operation{
                        completed_at = Value3};
                  error -> Record2
              end,
    case maps:find(last_error, Fields) of
        {ok, Value4} ->
            Record3#ias_vpn_orphan_recovery_operation{last_error = Value4};
        error -> Record3
    end.

verify_token_or_abort(Record, Token) ->
    case valid_token(Token) andalso
         Record#ias_vpn_orphan_recovery_operation.incident_token =:= Token of
        true -> ok;
        false -> ias_kvs_transaction:abort(stale_or_invalid_incident_token)
    end.

validate_all() ->
    case read_records() of
        {ok, Records} ->
            case validate_records(Records) of
                ok -> ok;
                {error, Reason} ->
                    {error, {vpn_orphan_recovery_validation_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {vpn_orphan_recovery_validation_failed, Reason}}
    end.

validate_records([]) -> ok;
validate_records([Record | Rest]) ->
    case validate_record(Record) of
        ok -> validate_records(Rest);
        {error, _} = Error -> Error
    end.

validate_record(#ias_vpn_orphan_recovery_operation{
                   device_id = DeviceId,
                   schema_version = ?SCHEMA_VERSION,
                   operation_id = OperationId,
                   incident_token = Token,
                   status = Status,
                   plan = Plan,
                   actor = Actor,
                   note = Note,
                   commit_summary = CommitSummary,
                   clearance = Clearance,
                   resolved_incident = ResolvedIncident,
                   attempts = Attempts,
                   last_error = LastError,
                   created_at = CreatedAt,
                   updated_at = UpdatedAt,
                   completed_at = CompletedAt}) ->
    Valid = valid_id(DeviceId)
        andalso valid_id(OperationId)
        andalso valid_token(Token)
        andalso lists:member(Status,
                             [planned, graph_committed,
                              reconciliation_confirmed, completed])
        andalso ias_vpn_orphan_recovery:validate_plan(Plan) =:= ok
        andalso valid_audit_text(Actor)
        andalso valid_audit_text(Note)
        andalso valid_optional_map(CommitSummary)
        andalso valid_optional_map(Clearance)
        andalso valid_optional_map(ResolvedIncident)
        andalso valid_status_fields(Status,
                                    CommitSummary,
                                    Clearance,
                                    ResolvedIncident,
                                    CompletedAt)
        andalso is_integer(Attempts) andalso Attempts >= 0
        andalso valid_safe_optional(LastError)
        andalso is_integer(CreatedAt) andalso CreatedAt >= 0
        andalso is_integer(UpdatedAt) andalso UpdatedAt >= CreatedAt
        andalso valid_optional_timestamp(CompletedAt),
    case Valid of true -> ok; false -> {error, invalid_fields} end;
validate_record(#ias_vpn_orphan_recovery_operation{schema_version = Version}) ->
    {error, {unsupported_schema_version, Version}};
validate_record(_Record) -> {error, invalid_record}.

valid_audit_text(Value) when is_binary(Value) ->
    byte_size(Value) =< 4096 andalso forbidden_path(Value, []) =:= none;
valid_audit_text(_) -> false.

valid_optional_map(undefined) -> true;
valid_optional_map(Value) when is_map(Value) -> forbidden_path(Value, []) =:= none;
valid_optional_map(_) -> false.

valid_safe_optional(undefined) -> true;
valid_safe_optional(Value) -> forbidden_path(Value, []) =:= none.

valid_optional_timestamp(undefined) -> true;
valid_optional_timestamp(Value) when is_integer(Value) -> Value >= 0;
valid_optional_timestamp(_) -> false.

valid_status_fields(planned, undefined, undefined, undefined, undefined) -> true;
valid_status_fields(graph_committed, CommitSummary, undefined, undefined,
                    undefined) ->
    is_map(CommitSummary);
valid_status_fields(reconciliation_confirmed, CommitSummary, Clearance,
                    undefined, undefined) ->
    is_map(CommitSummary) andalso is_map(Clearance);
valid_status_fields(completed, CommitSummary, Clearance, ResolvedIncident,
                    CompletedAt) ->
    is_map(CommitSummary) andalso is_map(Clearance)
        andalso is_map(ResolvedIncident) andalso is_integer(CompletedAt)
        andalso CompletedAt >= 0;
valid_status_fields(_Status, _CommitSummary, _Clearance, _ResolvedIncident,
                    _CompletedAt) ->
    false.


valid_id(Value) when is_binary(Value) -> byte_size(Value) > 0;
valid_id(_) -> false.

valid_token(Token) when is_binary(Token) -> byte_size(Token) =:= 32;
valid_token(_) -> false.

forbidden_path(Map, Path) when is_map(Map) ->
    forbidden_pairs(maps:to_list(Map), Path);
forbidden_path(List, Path) when is_list(List) ->
    forbidden_list(List, Path, 1);
forbidden_path(Tuple, Path) when is_tuple(Tuple) ->
    forbidden_list(tuple_to_list(Tuple), Path, 1);
forbidden_path(Value, Path) when is_binary(Value) ->
    case contains_private_material(Value) of
        true -> [private_material | Path];
        false -> none
    end;
forbidden_path(Value, Path)
  when is_pid(Value); is_port(Value); is_reference(Value); is_function(Value) ->
    [runtime_term | Path];
forbidden_path(_Value, _Path) -> none.

forbidden_pairs([], _Path) -> none;
forbidden_pairs([{Key, Value} | Rest], Path) ->
    case forbidden_key(Key) of
        true -> [Key | Path];
        false ->
            case forbidden_path(Value, [Key | Path]) of
                none -> forbidden_pairs(Rest, Path);
                Found -> Found
            end
    end.

forbidden_list([], _Path, _Index) -> none;
forbidden_list([Value | Rest], Path, Index) ->
    case forbidden_path(Value, [Index | Path]) of
        none -> forbidden_list(Rest, Path, Index + 1);
        Found -> Found
    end.

forbidden_key(Key) ->
    Text = string:lowercase(binary_to_list(normalize_id(Key))),
    lists:any(fun(Fragment) -> string:find(Text, Fragment) =/= nomatch end,
              ["private_key", "privatekey", "key_pem", "certificate_pem",
               "certificate_body", "csr_pem", "csr_body", "ovpn_body",
               "ovpn_profile", "password", "passphrase", "secret",
               "shared_secret", "tls_auth", "tls_crypt"]).

contains_private_material(Value) ->
    Markers = [<<"-----BEGIN PRIVATE KEY-----">>,
               <<"-----BEGIN RSA PRIVATE KEY-----">>,
               <<"-----BEGIN EC PRIVATE KEY-----">>,
               <<"-----BEGIN ENCRYPTED PRIVATE KEY-----">>],
    lists:any(fun(Marker) -> binary:match(Value, Marker) =/= nomatch end,
              Markers).

safe_reason(Reason) ->
    case forbidden_path(Reason, []) of none -> Reason; _ -> redacted end.

record_to_map(Record) ->
    #{device_id => Record#ias_vpn_orphan_recovery_operation.device_id,
      schema_version => Record#ias_vpn_orphan_recovery_operation.schema_version,
      operation_id => Record#ias_vpn_orphan_recovery_operation.operation_id,
      incident_token => Record#ias_vpn_orphan_recovery_operation.incident_token,
      status => Record#ias_vpn_orphan_recovery_operation.status,
      plan => Record#ias_vpn_orphan_recovery_operation.plan,
      actor => Record#ias_vpn_orphan_recovery_operation.actor,
      note => Record#ias_vpn_orphan_recovery_operation.note,
      commit_summary => Record#ias_vpn_orphan_recovery_operation.commit_summary,
      clearance => Record#ias_vpn_orphan_recovery_operation.clearance,
      resolved_incident =>
          Record#ias_vpn_orphan_recovery_operation.resolved_incident,
      attempts => Record#ias_vpn_orphan_recovery_operation.attempts,
      last_error => Record#ias_vpn_orphan_recovery_operation.last_error,
      created_at => Record#ias_vpn_orphan_recovery_operation.created_at,
      updated_at => Record#ias_vpn_orphan_recovery_operation.updated_at,
      completed_at => Record#ias_vpn_orphan_recovery_operation.completed_at}.

compare_operations(A, B) ->
    {maps:get(updated_at, A, 0), maps:get(operation_id, A, <<>>)} =<
        {maps:get(updated_at, B, 0), maps:get(operation_id, B, <<>>)}.

operation_id(DeviceId, Token) ->
    Digest = crypto:hash(sha256,
                         term_to_binary({DeviceId, Token,
                                         erlang:unique_integer([positive,
                                                                monotonic])},
                                        [deterministic])),
    Hex = iolist_to_binary([io_lib:format("~2.16.0b", [Byte])
                            || <<Byte>> <= Digest]),
    <<"vpn_orphan_recovery_", Hex/binary>>.

transaction(Fun) ->
    case ensure_storage() of
        ok -> ias_kvs_transaction:run(Fun);
        {error, Reason} -> {error, Reason}
    end.

reset_in_transaction() ->
    case read_records() of
        {ok, Records} ->
            lists:foreach(
              fun(#ias_vpn_orphan_recovery_operation{device_id = DeviceId}) ->
                      kvs_delete_or_abort(DeviceId);
                 (Invalid) ->
                      ias_kvs_transaction:abort(
                        {vpn_orphan_recovery_reset_invalid_record, Invalid})
              end,
              Records),
            ok;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

read_required(DeviceId) ->
    case kvs_get_record(DeviceId) of
        {ok, Record} -> Record;
        not_found -> ias_kvs_transaction:abort(operation_not_found);
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

validate_record_or_abort(Record) ->
    case validate_record(Record) of
        ok -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {invalid_vpn_orphan_recovery_record, Reason})
    end.

read_records() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> {ok, Records};
        {error, Reason} ->
            {error, {vpn_orphan_recovery_kvs_read_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {vpn_orphan_recovery_kvs_read_failed, Reason}};
        Other ->
            {error, {vpn_orphan_recovery_kvs_unexpected_result, Other}}
    end.

kvs_get_record(DeviceId) ->
    case catch kvs:get(?TABLE, DeviceId) of
        {ok, #ias_vpn_orphan_recovery_operation{} = Record} -> {ok, Record};
        {error, not_found} -> not_found;
        {error, Reason} ->
            {error, {vpn_orphan_recovery_kvs_read_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {vpn_orphan_recovery_kvs_read_failed, Reason}};
        Other ->
            {error, {vpn_orphan_recovery_kvs_unexpected_result, Other}}
    end.

kvs_put_or_abort(Record) ->
    case catch kvs:put(Record) of
        ok -> ok;
        {ok, _} -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {vpn_orphan_recovery_kvs_write_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {vpn_orphan_recovery_kvs_write_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {vpn_orphan_recovery_kvs_unexpected_result, Other})
    end.

kvs_delete_or_abort(DeviceId) ->
    case catch kvs:delete(?TABLE, DeviceId) of
        ok -> ok;
        {ok, _} -> ok;
        {error, not_found} -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {vpn_orphan_recovery_kvs_delete_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {vpn_orphan_recovery_kvs_delete_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {vpn_orphan_recovery_kvs_unexpected_result, Other})
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
            {error, {vpn_orphan_recovery_kvs_start_failed, Reason}}
    end.

ensure_kvs_schema_modules() ->
    Existing = application:get_env(kvs, schema, []),
    Required = [kvs, kvs_stream, ias_kvs],
    application:set_env(kvs, schema, lists:usort(Existing ++ Required)).

validate_kvs_metadata() ->
    ExpectedFields = record_info(fields, ias_vpn_orphan_recovery_operation),
    case kvs:table(?TABLE) of
        #table{fields = ExpectedFields, type = set, copy_type = disc_copies} -> ok;
        false -> {error, {vpn_orphan_recovery_kvs_schema_missing, ?TABLE}};
        #table{} = Table ->
            {error,
             {invalid_vpn_orphan_recovery_kvs_metadata,
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
                    {error, {vpn_orphan_recovery_kvs_join_failed, Reason}};
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
                    {error, {vpn_orphan_recovery_kvs_table_unavailable, ?TABLE}};
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

normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
normalize_id(Id) -> ias_html:text(Id).

normalize_text(undefined, Default) -> Default;
normalize_text(<<>>, Default) -> Default;
normalize_text([], Default) -> Default;
normalize_text(Value, _Default) -> ias_html:text(Value).

now_seconds() -> erlang:system_time(second).
