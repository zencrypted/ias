-module(ias_vpn_authority).

-export([ensure/0,
         get/1,
         all/0,
         prepare/2,
         recover_in_transaction/3,
         ensure_minimum_revision/2,
         current_revision/1,
         last_command/1,
         sync_device/1,
         overlay_device/1,
         delete/1,
         reset/0,
         reset_provisioning/0,
         status/0,
         validate_record/1,
         validate_migration_record/1]).

-include("ias_vpn_authority.hrl").
-include_lib("kvs/include/metainfo.hrl").

-define(TABLE, ias_vpn_device_state).
-define(SCHEMA_VERSION, 2).
-define(LEGACY_SCHEMA_VERSION, 1).
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

get(DeviceId0) ->
    DeviceId = normalize_id(DeviceId0),
    case ensure_storage() of
        ok ->
            case kvs_get_record(DeviceId) of
                not_found -> not_found;
                {ok, Record} ->
                    case validate_record(Record) of
                        ok -> {ok, record_to_map(Record)};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

all() ->
    case ensure_storage() of
        ok ->
            case read_records() of
                {ok, Records} ->
                    case validate_records(Records) of
                        ok ->
                            Sorted = lists:sort(
                                       fun(A, B) ->
                                           A#ias_vpn_device_state.device_id =<
                                               B#ias_vpn_device_state.device_id
                                       end,
                                       Records),
                            {ok, [record_to_map(Record) || Record <- Sorted]};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

prepare(DeviceId0, Command0) when is_map(Command0) ->
    DeviceId = normalize_id(DeviceId0),
    case safe_term(Command0) of
        false -> {error, unsafe_vpn_provisioning_command};
        true ->
            Digest = ias_vpn_command_digest:digest(Command0),
            case transaction(
                   fun() ->
                       Record0 = read_or_default(DeviceId),
                       validate_record_or_abort(Record0),
                       case {Record0#ias_vpn_device_state.command_digest,
                             Record0#ias_vpn_device_state.canonical_command} of
                           {Digest, Command} when is_map(Command), map_size(Command) > 0 ->
                               {unchanged, Command};
                           _ ->
                               Revision = Record0#ias_vpn_device_state.revision + 1,
                               Command = Command0#{revision => Revision},
                               Record = Record0#ias_vpn_device_state{
                                          schema_version = ?SCHEMA_VERSION,
                                          revision = Revision,
                                          command_digest = Digest,
                                          canonical_command = Command,
                                          lifecycle_state = command_lifecycle(
                                                              Command0,
                                                              Record0#ias_vpn_device_state.lifecycle_state),
                                          updated_at = now_seconds()},
                               validate_record_or_abort(Record),
                               kvs_put_or_abort(Record),
                               {changed, Command}
                       end
                   end) of
                {ok, {unchanged, Command}} -> {ok, Command, unchanged};
                {ok, {changed, Command}} -> {ok, Command, changed};
                {error, Reason} -> {error, normalize_abort(Reason)}
            end
    end;
prepare(_DeviceId, _Command) ->
    {error, invalid_command}.

%% Internal Stage 7C hook. The caller owns the wider KVS transaction that
%% atomically restores the domain graph, authority and recovery ledger.
recover_in_transaction(DeviceId0, Command, Binding0)
  when is_map(Command), is_map(Binding0) ->
    DeviceId = normalize_id(DeviceId0),
    Revision = maps:get(revision, Command, undefined),
    Desired = maps:get(desired_state, Command, #{}),
    Binding = maps:with(binding_fields(), Binding0),
    Valid = nonempty_binary(DeviceId)
        andalso is_integer(Revision) andalso Revision > 0
        andalso normalize_id(maps:get(device_id, Desired, undefined)) =:= DeviceId
        andalso is_ias_source(maps:get(source, Command, undefined))
        andalso valid_binding(Binding)
        andalso safe_term(Command),
    case Valid of
        false -> ias_kvs_transaction:abort(invalid_recovered_vpn_authority);
        true ->
            Digest = ias_vpn_command_digest:digest(Command),
            case kvs_get_record(DeviceId) of
                not_found ->
                    Record = #ias_vpn_device_state{
                               device_id = DeviceId,
                               schema_version = ?SCHEMA_VERSION,
                               revision = Revision,
                               command_digest = Digest,
                               canonical_command = Command,
                               binding = Binding,
                               lifecycle_state = command_lifecycle(Command, unbound),
                               updated_at = now_seconds()},
                    validate_record_or_abort(Record),
                    kvs_put_or_abort(Record),
                    {record_to_map(Record), changed};
                {ok, #ias_vpn_device_state{} = Record0} ->
                    validate_record_or_abort(Record0),
                    Same = Record0#ias_vpn_device_state.revision =:= Revision
                        andalso Record0#ias_vpn_device_state.command_digest =:= Digest
                        andalso Record0#ias_vpn_device_state.canonical_command =:= Command
                        andalso Record0#ias_vpn_device_state.binding =:= Binding,
                    case Same of
                        true -> {record_to_map(Record0), unchanged};
                        false ->
                            ias_kvs_transaction:abort(
                              vpn_authority_recovery_conflict)
                    end;
                {error, Reason} -> ias_kvs_transaction:abort(Reason)
            end
    end;
recover_in_transaction(_DeviceId, _Command, _Binding) ->
    ias_kvs_transaction:abort(invalid_recovered_vpn_authority).

ensure_minimum_revision(DeviceId0, Revision)
  when is_integer(Revision), Revision >= 0 ->
    DeviceId = normalize_id(DeviceId0),
    case transaction(
           fun() ->
               Record0 = read_or_default(DeviceId),
               validate_record_or_abort(Record0),
               case Record0#ias_vpn_device_state.revision >= Revision of
                   true -> unchanged;
                   false ->
                       Record = Record0#ias_vpn_device_state{
                                  schema_version = ?SCHEMA_VERSION,
                                  revision = Revision,
                                  command_digest = undefined,
                                  canonical_command = #{},
                                  updated_at = now_seconds()},
                       validate_record_or_abort(Record),
                       kvs_put_or_abort(Record),
                       changed
               end
           end) of
        {ok, _} -> ok;
        {error, Reason} -> {error, normalize_abort(Reason)}
    end;
ensure_minimum_revision(_DeviceId, _Revision) ->
    {error, invalid_revision}.

current_revision(DeviceId) ->
    case ?MODULE:get(DeviceId) of
        {ok, State} -> maps:get(revision, State, 0);
        not_found -> 0;
        {error, Reason} -> exit({vpn_authority_read_failed, Reason})
    end.

last_command(DeviceId) ->
    case ?MODULE:get(DeviceId) of
        {ok, #{canonical_command := Command}} when is_map(Command), map_size(Command) > 0 ->
            {ok, Command};
        {ok, _} -> not_found;
        not_found -> not_found;
        {error, Reason} -> {error, Reason}
    end.

sync_device(#{kind := device, id := DeviceId0} = Device) ->
    DeviceId = normalize_id(DeviceId0),
    Binding = maps:with(binding_fields(), Device),
    LastDecommission = maps:get(vpn_last_decommission, Device, undefined),
    History = maps:get(vpn_decommission_history, Device, []),
    DecommissionedAt = maps:get(vpn_decommissioned_at, Device, undefined),
    case has_vpn_state(Binding, LastDecommission, History, DecommissionedAt) of
        false -> ok;
        true ->
            case valid_device_projection(Binding,
                                         LastDecommission,
                                         History,
                                         DecommissionedAt) of
                false -> {error, invalid_vpn_device_authority_state};
                true ->
                    case transaction(
                           fun() ->
                               Record0 = read_or_default(DeviceId),
                               validate_record_or_abort(Record0),
                               Record = (upgrade_record(Record0))#ias_vpn_device_state{
                                          binding = Binding,
                                          lifecycle_state = device_lifecycle(
                                                              Binding,
                                                              LastDecommission,
                                                              Record0#ias_vpn_device_state.lifecycle_state),
                                          last_decommission = LastDecommission,
                                          decommission_history = History,
                                          decommissioned_at = DecommissionedAt,
                                          updated_at = now_seconds()},
                               validate_record_or_abort(Record),
                               kvs_put_or_abort(Record),
                               ok
                           end) of
                        {ok, ok} -> ok;
                        {error, Reason} -> {error, normalize_abort(Reason)}
                    end
            end
    end;
sync_device(_Object) ->
    ok.

overlay_device(#{kind := device, id := DeviceId} = Device) ->
    case ?MODULE:get(DeviceId) of
        {ok, State} -> overlay_state(Device, State);
        not_found -> Device;
        {error, Reason} -> exit({vpn_authority_overlay_failed, Reason})
    end;
overlay_device(Object) ->
    Object.

delete(DeviceId0) ->
    DeviceId = normalize_id(DeviceId0),
    case transaction(fun() -> kvs_delete_or_abort(DeviceId), ok end) of
        {ok, ok} -> ok;
        {error, Reason} -> {error, normalize_abort(Reason)}
    end.

reset() ->
    case transaction(fun reset_in_transaction/0) of
        {ok, ok} -> ok;
        {error, Reason} -> {error, {vpn_authority_reset_failed,
                                    normalize_abort(Reason)}}
    end.

reset_provisioning() ->
    case transaction(
           fun() ->
               case read_records() of
                   {ok, Records} ->
                       lists:foreach(fun reset_provisioning_record/1, Records),
                       ok;
                   {error, Reason} -> ias_kvs_transaction:abort(Reason)
               end
           end) of
        {ok, ok} -> ok;
        {error, Reason} -> {error, normalize_abort(Reason)}
    end.

reset_provisioning_record(#ias_vpn_device_state{} = Record0) ->
    validate_record_or_abort(Record0),
    Record = Record0#ias_vpn_device_state{
               schema_version = ?SCHEMA_VERSION,
               revision = 0,
               command_digest = undefined,
               canonical_command = #{},
               lifecycle_state = stored_device_lifecycle(Record0),
               updated_at = now_seconds()},
    validate_record_or_abort(Record),
    kvs_put_or_abort(Record).

status() ->
    case all() of
        {ok, Records} ->
            #{devices => length(Records),
              persistence => durable,
              backend => kvs,
              revisions => maps:from_list([{maps:get(device_id, Entry),
                                             maps:get(revision, Entry)}
                                            || Entry <- Records]),
              lifecycle => maps:from_list([{maps:get(device_id, Entry),
                                            maps:get(lifecycle_state, Entry)}
                                           || Entry <- Records])};
        {error, Reason} -> exit({vpn_authority_status_failed, Reason})
    end.

validate_all() ->
    case read_records() of
        {ok, Records} -> validate_records(Records);
        {error, _} = Error -> Error
    end.

transaction(Fun) ->
    case ensure_storage() of
        ok -> ias_kvs_transaction:run(Fun);
        {error, _} = Error -> Error
    end.

reset_in_transaction() ->
    case read_records() of
        {ok, Records} ->
            lists:foreach(
              fun(#ias_vpn_device_state{device_id = DeviceId}) ->
                      kvs_delete_or_abort(DeviceId);
                 (Invalid) ->
                      ias_kvs_transaction:abort(
                        {vpn_authority_reset_invalid_record, Invalid})
              end,
              Records),
            ok;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

read_or_default(DeviceId) ->
    case kvs_get_record(DeviceId) of
        not_found -> #ias_vpn_device_state{device_id = DeviceId,
                                            updated_at = now_seconds()};
        {ok, Record} -> Record;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

validate_records([]) -> ok;
validate_records([Record | Rest]) ->
    case validate_record(Record) of
        ok -> validate_records(Rest);
        {error, _} = Error -> Error
    end.

validate_record_or_abort(Record) ->
    case validate_record(Record) of
        ok -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort({vpn_authority_invalid_record, Reason})
    end.

read_records() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> {ok, Records};
        {error, Reason} -> {error, {vpn_authority_kvs_read_failed, Reason}};
        {'EXIT', Reason} -> {error, {vpn_authority_kvs_read_failed, Reason}};
        Other -> {error, {vpn_authority_kvs_unexpected_result, Other}}
    end.

kvs_get_record(DeviceId) ->
    case catch kvs:get(?TABLE, DeviceId) of
        {ok, #ias_vpn_device_state{} = Record} -> {ok, Record};
        {error, not_found} -> not_found;
        {error, Reason} -> {error, {vpn_authority_kvs_read_failed, Reason}};
        {'EXIT', Reason} -> {error, {vpn_authority_kvs_read_failed, Reason}};
        Other -> {error, {vpn_authority_kvs_unexpected_result, Other}}
    end.

kvs_put_or_abort(Record) ->
    case catch kvs:put(Record) of
        ok -> ok;
        {ok, _} -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort({vpn_authority_kvs_write_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort({vpn_authority_kvs_write_failed, Reason});
        Other ->
            ias_kvs_transaction:abort({vpn_authority_kvs_unexpected_result, Other})
    end.

kvs_delete_or_abort(DeviceId) ->
    case catch kvs:delete(?TABLE, DeviceId) of
        ok -> ok;
        {ok, _} -> ok;
        {error, not_found} -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort({vpn_authority_kvs_delete_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort({vpn_authority_kvs_delete_failed, Reason});
        Other ->
            ias_kvs_transaction:abort({vpn_authority_kvs_unexpected_result, Other})
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
            {error, {vpn_authority_kvs_start_failed, Reason}}
    end.

ensure_kvs_schema_modules() ->
    Existing = application:get_env(kvs, schema, []),
    Required = [kvs, kvs_stream, ias_kvs],
    application:set_env(kvs, schema, lists:usort(Existing ++ Required)).

validate_kvs_metadata() ->
    ExpectedFields = record_info(fields, ias_vpn_device_state),
    case kvs:table(?TABLE) of
        #table{fields = ExpectedFields, type = set, copy_type = disc_copies} -> ok;
        false -> {error, {vpn_authority_kvs_schema_missing, ?TABLE}};
        #table{} = Table ->
            {error,
             {invalid_vpn_authority_kvs_metadata,
              #{fields => Table#table.fields,
                type => Table#table.type,
                copy_type => Table#table.copy_type}}}
    end.

ensure_kvs_table() ->
    case validate_kvs_access() of
        ok -> ok;
        {error, _} ->
            case catch kvs:join() of
                {'EXIT', Reason} -> {error, {vpn_authority_kvs_join_failed, Reason}};
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
                true -> {error, {vpn_authority_kvs_table_unavailable, ?TABLE}};
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

normalize_abort({vpn_authority_invalid_record, Reason}) -> Reason;
normalize_abort(Reason) -> Reason.

validate_record(#ias_vpn_device_state{schema_version = SchemaVersion} = Record)
  when SchemaVersion =:= ?SCHEMA_VERSION;
       SchemaVersion =:= ?LEGACY_SCHEMA_VERSION ->
    validate_record_fields(Record, true);
validate_record(#ias_vpn_device_state{schema_version = Version}) ->
    {error, {unsupported_vpn_authority_schema_version, Version}};
validate_record(_) ->
    {error, invalid_vpn_authority_record}.

%% Used only by the explicit checksum migration tool. It validates every
%% durable field and the digest shape, but deliberately does not assert digest
%% equality because that is the property being migrated across OTP releases.
validate_migration_record(#ias_vpn_device_state{} = Record) ->
    validate_record_fields(Record, false);
validate_migration_record(_) ->
    {error, invalid_vpn_authority_record}.

validate_record_fields(#ias_vpn_device_state{
                          device_id = DeviceId,
                          schema_version = SchemaVersion,
                          revision = Revision,
                          command_digest = Digest,
                          canonical_command = Command,
                          binding = Binding,
                          lifecycle_state = Lifecycle,
                          last_decommission = Last,
                          decommission_history = History,
                          decommissioned_at = DecommissionedAt,
                          updated_at = UpdatedAt}, CheckDigest) ->
    DigestValid = case CheckDigest of
                      true -> valid_command_projection(SchemaVersion,
                                                       Revision,
                                                       Digest,
                                                       Command);
                      false -> valid_command_projection_shape(Revision,
                                                              Digest,
                                                              Command)
                  end,
    Checks = [nonempty_binary(DeviceId),
              (SchemaVersion =:= ?SCHEMA_VERSION orelse
               SchemaVersion =:= ?LEGACY_SCHEMA_VERSION),
              is_integer(Revision) andalso Revision >= 0,
              DigestValid,
              valid_binding(Binding),
              valid_lifecycle(Lifecycle),
              valid_optional_map(Last),
              valid_history(History),
              valid_optional_timestamp(DecommissionedAt),
              is_integer(UpdatedAt) andalso UpdatedAt >= 0],
    case lists:all(fun(Value) -> Value =:= true end, Checks) of
        true -> ok;
        false -> {error, invalid_vpn_authority_record}
    end.

valid_command_projection(SchemaVersion, Revision, Digest, Command)
  when is_map(Command) ->
    valid_digest(Digest)
        andalso valid_command_revision(Revision, Command)
        andalso valid_command_digest(SchemaVersion, Digest, Command)
        andalso safe_term(Command);
valid_command_projection(_SchemaVersion, _Revision, _Digest, _Command) -> false.

valid_command_projection_shape(Revision, Digest, Command) when is_map(Command) ->
    valid_digest(Digest)
        andalso valid_command_revision(Revision, Command)
        andalso valid_empty_digest_pair(Digest, Command)
        andalso safe_term(Command);
valid_command_projection_shape(_Revision, _Digest, _Command) -> false.

valid_empty_digest_pair(undefined, Command) -> map_size(Command) =:= 0;
valid_empty_digest_pair(Digest, Command) when is_binary(Digest) ->
    map_size(Command) > 0;
valid_empty_digest_pair(_Digest, _Command) -> false.

valid_command_revision(_Revision, Command) when map_size(Command) =:= 0 -> true;
valid_command_revision(Revision, Command) ->
    maps:get(revision, Command, undefined) =:= Revision.

valid_digest(undefined) -> true;
valid_digest(Digest) when is_binary(Digest) -> byte_size(Digest) =:= 32;
valid_digest(_) -> false.

valid_command_digest(_SchemaVersion, undefined, Command)
  when map_size(Command) =:= 0 -> true;
valid_command_digest(?SCHEMA_VERSION, Digest, Command)
  when is_binary(Digest), map_size(Command) > 0 ->
    secure_equal(Digest, ias_vpn_command_digest:digest(Command));
valid_command_digest(?LEGACY_SCHEMA_VERSION, Digest, Command)
  when is_binary(Digest), map_size(Command) > 0 ->
    secure_equal(Digest, ias_vpn_command_digest:legacy_digest(Command));
valid_command_digest(_SchemaVersion, _Digest, _Command) -> false.

valid_optional_map(undefined) -> true;
valid_optional_map(Map) when is_map(Map) -> safe_term(Map);
valid_optional_map(_) -> false.

valid_binding(Binding) when is_map(Binding) ->
    (maps:keys(Binding) -- binding_fields()) =:= [] andalso safe_term(Binding);
valid_binding(_Binding) -> false.

valid_history(History) when is_list(History) ->
    lists:all(fun(Entry) -> is_map(Entry) andalso safe_term(Entry) end, History);
valid_history(_History) -> false.

valid_optional_timestamp(undefined) -> true;
valid_optional_timestamp(Value) -> is_integer(Value) andalso Value >= 0.

valid_lifecycle(unbound) -> true;
valid_lifecycle(allocated) -> true;
valid_lifecycle(enabled) -> true;
valid_lifecycle(established) -> true;
valid_lifecycle(disabled) -> true;
valid_lifecycle(revoked) -> true;
valid_lifecycle(removed) -> true;
valid_lifecycle(decommissioned) -> true;
valid_lifecycle(_) -> false.

valid_device_projection(Binding, Last, History, DecommissionedAt) ->
    valid_binding(Binding)
        andalso valid_optional_map(Last)
        andalso valid_history(History)
        andalso valid_optional_timestamp(DecommissionedAt).

has_vpn_state(Binding, Last, History, DecommissionedAt) ->
    map_size(Binding) > 0 orelse Last =/= undefined orelse History =/= []
        orelse DecommissionedAt =/= undefined.

device_lifecycle(Binding, Last, Current) ->
    case active_allocation(Binding) of
        true -> active_device_lifecycle(Binding, Current);
        false when is_map(Last) -> decommissioned;
        false -> unbound
    end.

active_device_lifecycle(_Binding, disabled) -> disabled;
active_device_lifecycle(_Binding, revoked) -> revoked;
active_device_lifecycle(_Binding, removed) -> removed;
active_device_lifecycle(Binding, _Current) ->
    case maps:get(vpn_dynamic_pair_state, Binding, undefined) of
        established -> established;
        _ -> allocated
    end.

active_allocation(Binding) ->
    case maps:get(vpn_allocation_id, Binding, undefined) of
        AllocationId when is_binary(AllocationId) -> byte_size(AllocationId) > 0;
        _ -> false
    end.

stored_device_lifecycle(#ias_vpn_device_state{binding = Binding,
                                               last_decommission = Last}) ->
    device_lifecycle(Binding, Last, unbound).

command_lifecycle(#{operation := upsert}, _Current) -> enabled;
command_lifecycle(#{operation := enable}, _Current) -> enabled;
command_lifecycle(#{operation := disable}, _Current) -> disabled;
command_lifecycle(#{operation := revoke}, _Current) -> revoked;
command_lifecycle(#{operation := remove}, _Current) -> removed;
command_lifecycle(_Command, Current) -> Current.

upgrade_record(#ias_vpn_device_state{canonical_command = Command} = Record) ->
    Digest = case map_size(Command) of
                 0 -> undefined;
                 _ -> ias_vpn_command_digest:digest(Command)
             end,
    Record#ias_vpn_device_state{schema_version = ?SCHEMA_VERSION,
                                command_digest = Digest}.

secure_equal(Left, Right)
  when is_binary(Left), is_binary(Right), byte_size(Left) =:= byte_size(Right) ->
    secure_equal(Left, Right, 0) =:= 0;
secure_equal(_Left, _Right) ->
    false.

secure_equal(<<>>, <<>>, Acc) ->
    Acc;
secure_equal(<<Left, LeftRest/binary>>, <<Right, RightRest/binary>>, Acc) ->
    secure_equal(LeftRest, RightRest, Acc bor (Left bxor Right)).

overlay_state(Device, State) ->
    Binding = maps:get(binding, State, #{}),
    Last = maps:get(last_decommission, State, undefined),
    History = maps:get(decommission_history, State, []),
    Base = case {map_size(Binding), Last, History} of
               {0, undefined, []} -> Device;
               _ -> maps:without(authority_device_fields(), Device)
           end,
    WithBinding = maps:merge(Base, Binding),
    WithLast = maybe_put(vpn_last_decommission, Last, WithBinding),
    WithHistory = case History of
                      [] -> WithLast;
                      _ -> WithLast#{vpn_decommission_history => History}
                  end,
    maybe_put(vpn_decommissioned_at,
              maps:get(decommissioned_at, State, undefined),
              WithHistory).

record_to_map(#ias_vpn_device_state{} = Record) ->
    #{device_id => Record#ias_vpn_device_state.device_id,
      schema_version => Record#ias_vpn_device_state.schema_version,
      revision => Record#ias_vpn_device_state.revision,
      command_digest => Record#ias_vpn_device_state.command_digest,
      canonical_command => Record#ias_vpn_device_state.canonical_command,
      binding => Record#ias_vpn_device_state.binding,
      lifecycle_state => Record#ias_vpn_device_state.lifecycle_state,
      last_decommission => Record#ias_vpn_device_state.last_decommission,
      decommission_history => Record#ias_vpn_device_state.decommission_history,
      decommissioned_at => Record#ias_vpn_device_state.decommissioned_at,
      updated_at => Record#ias_vpn_device_state.updated_at}.

record_status(Record, Acc) ->
    case validate_record(Record) of
        ok ->
            [#{device_id => Record#ias_vpn_device_state.device_id,
               revision => Record#ias_vpn_device_state.revision,
               lifecycle_state => Record#ias_vpn_device_state.lifecycle_state} | Acc];
        {error, Reason} -> ias_kvs_transaction:abort({vpn_authority_invalid_record, Reason})
    end.

binding_fields() ->
    [runtime_peer_id,
     vpn_peer,
     vpn_allocation_id,
     vpn_allocator_instance_id,
     vpn_client_peer_id,
     vpn_gateway_peer_id,
     vpn_allocation_slot,
     vpn_allocation_generation,
     vpn_allocation_state,
     vpn_allocation_persistence,
     vpn_allocation_created_at,
     vpn_dynamic_pair_state,
     vpn_dynamic_pair_reconciled_at,
     vpn_runtime_certificate_fingerprint].

authority_device_fields() ->
    binding_fields() ++ [vpn_last_decommission,
                         vpn_decommission_history,
                         vpn_decommissioned_at].

safe_term(Term) when is_map(Term) ->
    lists:all(fun({Key, Value}) -> not forbidden_key(Key) andalso safe_term(Value) end,
              maps:to_list(Term));
safe_term(Term) when is_list(Term) -> lists:all(fun safe_term/1, Term);
safe_term(Term) when is_tuple(Term) -> safe_term(tuple_to_list(Term));
safe_term(Term) when is_pid(Term); is_port(Term); is_reference(Term); is_function(Term) -> false;
safe_term(_Term) -> true.

forbidden_key(private_key) -> true;
forbidden_key(private_key_path) -> true;
forbidden_key(private_key_body) -> true;
forbidden_key(private_key_pem) -> true;
forbidden_key(psk) -> true;
forbidden_key(shared_secret) -> true;
forbidden_key(session_key) -> true;
forbidden_key(session_keys) -> true;
forbidden_key(ecdh_private) -> true;
forbidden_key(replay_window) -> true;
forbidden_key(runtime_config) -> true;
forbidden_key(ovpn) -> true;
forbidden_key(ovpn_body) -> true;
forbidden_key(_) -> false.

is_ias_source(ias) -> true;
is_ias_source(<<"ias">>) -> true;
is_ias_source("ias") -> true;
is_ias_source(_) -> false.

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

nonempty_binary(Value) when is_binary(Value) -> byte_size(Value) > 0;
nonempty_binary(_) -> false.

normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) -> ias_html:text(Id).

now_seconds() -> erlang:system_time(second).
