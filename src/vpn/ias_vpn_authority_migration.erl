%%%-------------------------------------------------------------------
%% @doc Explicit migration of OTP-dependent VPN authority digests.
%%
%% Migration is never performed during IAS boot. Legacy schema version 1
%% records whose digest can still be reproduced may be migrated with
%% migrate_legacy_digests/0. Cross-OTP records require the deliberately
%% explicit confirmation atom accepted by migrate_legacy_digests/1 after the
%% operator has backed up the Mnesia directory.
%%%-------------------------------------------------------------------
-module(ias_vpn_authority_migration).

-export([inspect/0,
         migrate_legacy_digests/0,
         migrate_legacy_digests/1]).

-include("ias_vpn_authority.hrl").

-define(TABLE, ias_vpn_device_state).
-define(LEGACY_SCHEMA_VERSION, 1).
-define(CURRENT_SCHEMA_VERSION, 2).

inspect() ->
    case read_records() of
        {ok, Records} -> inspect_records(Records);
        {error, _} = Error -> Error
    end.

migrate_legacy_digests() ->
    migrate(verified_only).

migrate_legacy_digests(accept_unverifiable_legacy_digests) ->
    migrate(allow_unverifiable);
migrate_legacy_digests(_Confirmation) ->
    {error, invalid_migration_confirmation}.

migrate(Mode) ->
    case application:which_applications() of
        Apps when is_list(Apps) ->
            case lists:keymember(ias, 1, Apps) of
                true -> {error, ias_application_must_be_stopped};
                false -> migrate_stopped_ias(Mode)
            end
    end.

migrate_stopped_ias(Mode) ->
    case ias_kvs_transaction:ensure() of
        ok ->
            case ias_kvs_transaction:run(fun() -> migrate_in_transaction(Mode) end) of
                {ok, Result} -> {ok, Result};
                {error, Reason} -> {error, normalize_abort(Reason)}
            end;
        {error, _} = Error -> Error
    end.

migrate_in_transaction(Mode) ->
    case read_records() of
        {ok, Records} ->
            Results = [migrate_record(Record, Mode) || Record <- Records],
            summarize(Results);
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

migrate_record(#ias_vpn_device_state{schema_version = ?CURRENT_SCHEMA_VERSION} = Record,
               _Mode) ->
    validate_current_or_abort(Record),
    current;
migrate_record(#ias_vpn_device_state{schema_version = ?LEGACY_SCHEMA_VERSION} = Record,
               Mode) ->
    validate_migration_or_abort(Record),
    Verified = legacy_digest_valid(Record),
    case {Mode, Verified} of
        {verified_only, false} ->
            ias_kvs_transaction:abort(
              {legacy_vpn_authority_digest_not_verifiable,
               Record#ias_vpn_device_state.device_id});
        _ ->
            Rewritten = rewrite_record(Record),
            put_or_abort(Rewritten),
            case Verified of
                true -> migrated_verified;
                false -> migrated_operator_accepted
            end
    end;
migrate_record(#ias_vpn_device_state{schema_version = Version}, _Mode) ->
    ias_kvs_transaction:abort(
      {unsupported_vpn_authority_schema_version, Version});
migrate_record(_Record, _Mode) ->
    ias_kvs_transaction:abort(invalid_vpn_authority_record).

inspect_records(Records) ->
    case inspect_entries(Records, []) of
        {ok, Entries} ->
            Sorted = lists:sort(
                       fun(A, B) -> maps:get(device_id, A) =< maps:get(device_id, B) end,
                       Entries),
            {ok, #{state => inspection,
                   total => length(Sorted),
                   current => count_state(current, Sorted),
                   legacy_verified => count_state(legacy_verified, Sorted),
                   legacy_unverifiable => count_state(legacy_unverifiable, Sorted),
                   records => Sorted}};
        {error, _} = Error -> Error
    end.

inspect_entries([], Acc) ->
    {ok, lists:reverse(Acc)};
inspect_entries([#ias_vpn_device_state{device_id = DeviceId,
                                       schema_version = ?CURRENT_SCHEMA_VERSION} = Record
                 | Rest], Acc) ->
    case ias_vpn_authority:validate_migration_record(Record) of
        ok ->
            case ias_vpn_authority:validate_record(Record) of
                ok -> inspect_entries(Rest, [#{device_id => DeviceId, state => current} | Acc]);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
inspect_entries([#ias_vpn_device_state{device_id = DeviceId,
                                       schema_version = ?LEGACY_SCHEMA_VERSION} = Record
                 | Rest], Acc) ->
    case ias_vpn_authority:validate_migration_record(Record) of
        ok ->
            State = case legacy_digest_valid(Record) of
                        true -> legacy_verified;
                        false -> legacy_unverifiable
                    end,
            inspect_entries(Rest, [#{device_id => DeviceId, state => State} | Acc]);
        {error, _} = Error -> Error
    end;
inspect_entries([#ias_vpn_device_state{schema_version = Version} | _], _Acc) ->
    {error, {unsupported_vpn_authority_schema_version, Version}};
inspect_entries([_ | _], _Acc) ->
    {error, invalid_vpn_authority_record}.

rewrite_record(#ias_vpn_device_state{canonical_command = Command} = Record) ->
    Digest = case map_size(Command) of
                 0 -> undefined;
                 _ -> ias_vpn_command_digest:digest(Command)
             end,
    Record#ias_vpn_device_state{schema_version = ?CURRENT_SCHEMA_VERSION,
                                command_digest = Digest}.

legacy_digest_valid(#ias_vpn_device_state{canonical_command = Command,
                                           command_digest = Digest})
  when is_map(Command), map_size(Command) > 0,
       is_binary(Digest), byte_size(Digest) =:= 32 ->
    secure_equal(Digest, ias_vpn_command_digest:legacy_digest(Command));
legacy_digest_valid(#ias_vpn_device_state{canonical_command = Command,
                                           command_digest = undefined})
  when is_map(Command), map_size(Command) =:= 0 ->
    true;
legacy_digest_valid(_) ->
    false.

validate_current_or_abort(Record) ->
    case ias_vpn_authority:validate_record(Record) of
        ok -> ok;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

validate_or_abort(Record) ->
    case ias_vpn_authority:validate_migration_record(Record) of
        ok -> ok;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

validate_migration_or_abort(Record) ->
    validate_or_abort(Record).

put_or_abort(Record) ->
    case catch kvs:put(Record) of
        ok -> ok;
        {ok, _} -> ok;
        {error, Reason} -> ias_kvs_transaction:abort({kvs_write_failed, Reason});
        {'EXIT', Reason} -> ias_kvs_transaction:abort({kvs_write_failed, Reason});
        Other -> ias_kvs_transaction:abort({unexpected_kvs_write_result, Other})
    end.

read_records() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> {ok, Records};
        {error, Reason} -> {error, {kvs_load_failed, Reason}};
        {'EXIT', Reason} -> {error, {kvs_load_failed, Reason}};
        Other -> {error, {unexpected_kvs_load_result, Other}}
    end.

summarize(Results) ->
    #{state => migrated,
      total => length(Results),
      already_current => count(current, Results),
      migrated_verified => count(migrated_verified, Results),
      migrated_operator_accepted => count(migrated_operator_accepted, Results)}.

count(Value, Values) ->
    length([Item || Item <- Values, Item =:= Value]).

count_state(State, Entries) ->
    length([Entry || Entry <- Entries, maps:get(state, Entry) =:= State]).

normalize_abort(Reason) -> Reason.

secure_equal(Left, Right)
  when is_binary(Left), is_binary(Right), byte_size(Left) =:= byte_size(Right) ->
    secure_equal(Left, Right, 0) =:= 0;
secure_equal(_Left, _Right) ->
    false.

secure_equal(<<>>, <<>>, Acc) ->
    Acc;
secure_equal(<<Left, LeftRest/binary>>, <<Right, RightRest/binary>>, Acc) ->
    secure_equal(LeftRest, RightRest, Acc bor (Left bxor Right)).
