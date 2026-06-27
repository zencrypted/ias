-module(ias_vpn_provisioning_delivery_store).

-export([ensure/0,
         append/1,
         all/0,
         count/0,
         validate_all/0,
         reset/0]).

-include("ias_vpn_provisioning_delivery_audit.hrl").
-include_lib("kvs/include/metainfo.hrl").

-define(TABLE, ias_vpn_provisioning_delivery_audit).
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

append(Delivery0) when is_map(Delivery0) ->
    case ensure_storage() of
        ok ->
            case validate_payload(Delivery0) of
                ok ->
                    ias_kvs_transaction:run(
                      fun() -> append_in_transaction(Delivery0) end);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
append(_Delivery) ->
    {error, invalid_vpn_delivery_audit_payload}.

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

append_in_transaction(Delivery0) ->
    DeviceId = normalize_id(maps:get(device_id, Delivery0, undefined)),
    case usable_id(DeviceId) of
        false -> ias_kvs_transaction:abort(invalid_vpn_delivery_audit_device_id);
        true -> ok
    end,
    Records = records_or_abort(),
    ok = validate_records_or_abort(Records),
    Attempt = next_attempt(DeviceId, Records),
    DeliveryId = delivery_id(),
    ProvisioningId = normalize_optional_id(
                       maps:get(provisioning_transaction_id,
                                Delivery0,
                                undefined)),
    Delivery1 = Delivery0#{delivery_id => DeliveryId,
                           device_id => DeviceId,
                           attempt => Attempt},
    Delivery = case ProvisioningId of
                   undefined -> maps:remove(provisioning_transaction_id,
                                            Delivery1);
                   _ -> Delivery1#{provisioning_transaction_id => ProvisioningId}
               end,
    Record = #ias_vpn_provisioning_delivery_audit{
                delivery_id = DeliveryId,
                device_id = DeviceId,
                provisioning_transaction_id = ProvisioningId,
                attempt = Attempt,
                delivery_status = maps:get(delivery_status, Delivery, undefined),
                operation = maps:get(operation, Delivery, undefined),
                revision = maps:get(revision, Delivery, undefined),
                delivered_at = maps:get(delivered_at, Delivery, undefined),
                payload = Delivery},
    ok = validate_record_or_abort(Record),
    ok = kvs_put_or_abort(Record),
    Delivery.

read_all() ->
    case read_records() of
        {ok, Records} ->
            case validate_records(Records) of
                ok ->
                    Maps = [record_to_map(Record) || Record <- Records],
                    {ok, lists:sort(fun compare_delivery_maps/2, Maps)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

read_records() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> {ok, Records};
        {error, Reason} ->
            {error, {vpn_delivery_audit_kvs_read_failed, Reason}};
        {'EXIT', Reason} ->
            {error, {vpn_delivery_audit_kvs_read_failed, Reason}};
        Other ->
            {error, {vpn_delivery_audit_kvs_unexpected_result, Other}}
    end.

records_or_abort() ->
    case read_records() of
        {ok, Records} -> Records;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

reset_in_transaction() ->
    Records = records_or_abort(),
    lists:foreach(
      fun(#ias_vpn_provisioning_delivery_audit{delivery_id = DeliveryId}) ->
              kvs_delete_or_abort(DeliveryId);
         (Invalid) ->
              ias_kvs_transaction:abort(
                {vpn_delivery_audit_reset_invalid_record, Invalid})
      end,
      Records),
    ok.

next_attempt(DeviceId, Records) ->
    Attempts = [Attempt
                || #ias_vpn_provisioning_delivery_audit{
                       device_id = Candidate,
                       attempt = Attempt} <- Records,
                   Candidate =:= DeviceId,
                   is_integer(Attempt),
                   Attempt > 0],
    case Attempts of
        [] -> 1;
        _ -> lists:max(Attempts) + 1
    end.

record_to_map(#ias_vpn_provisioning_delivery_audit{payload = Payload}) ->
    Payload.

compare_delivery_maps(A, B) ->
    DeviceA = maps:get(device_id, A, <<>>),
    DeviceB = maps:get(device_id, B, <<>>),
    case DeviceA =:= DeviceB of
        true -> maps:get(attempt, A, 0) > maps:get(attempt, B, 0);
        false -> DeviceA < DeviceB
    end.

validate_records([]) -> ok;
validate_records([Record | Rest]) ->
    case validate_record(Record) of
        ok -> validate_records(Rest);
        {error, _} = Error -> Error
    end.

validate_records_or_abort(Records) ->
    case validate_records(Records) of
        ok -> ok;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

validate_record_or_abort(Record) ->
    case validate_record(Record) of
        ok -> ok;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

validate_record(
  #ias_vpn_provisioning_delivery_audit{
     schema_version = ?SCHEMA_VERSION,
     delivery_id = DeliveryId,
     device_id = DeviceId,
     provisioning_transaction_id = ProvisioningId,
     attempt = Attempt,
     delivery_status = DeliveryStatus,
     operation = Operation,
     revision = Revision,
     delivered_at = DeliveredAt,
     payload = Payload}) ->
    case usable_id(DeliveryId) andalso
         usable_id(DeviceId) andalso
         valid_optional_id(ProvisioningId) andalso
         is_integer(Attempt) andalso Attempt > 0 andalso
         valid_delivery_status(DeliveryStatus) andalso
         valid_operation(Operation) andalso
         valid_revision(Revision) andalso
         usable_id(DeliveredAt) andalso
         payload_matches_record(Payload,
                                DeliveryId,
                                DeviceId,
                                ProvisioningId,
                                Attempt,
                                DeliveryStatus,
                                Operation,
                                Revision,
                                DeliveredAt) of
        true -> validate_payload(Payload);
        false -> {error, invalid_vpn_delivery_audit_record}
    end;
validate_record(#ias_vpn_provisioning_delivery_audit{schema_version = Version}) ->
    {error, {unsupported_vpn_delivery_audit_schema_version, Version}};
validate_record(_) ->
    {error, invalid_vpn_delivery_audit_record}.

payload_matches_record(Payload,
                       DeliveryId,
                       DeviceId,
                       ProvisioningId,
                       Attempt,
                       DeliveryStatus,
                       Operation,
                       Revision,
                       DeliveredAt) ->
    maps:get(delivery_id, Payload, undefined) =:= DeliveryId andalso
    normalize_id(maps:get(device_id, Payload, undefined)) =:= DeviceId andalso
    normalize_optional_id(maps:get(provisioning_transaction_id,
                                   Payload,
                                   undefined)) =:= ProvisioningId andalso
    maps:get(attempt, Payload, undefined) =:= Attempt andalso
    maps:get(delivery_status, Payload, undefined) =:= DeliveryStatus andalso
    maps:get(operation, Payload, undefined) =:= Operation andalso
    maps:get(revision, Payload, undefined) =:= Revision andalso
    maps:get(delivered_at, Payload, undefined) =:= DeliveredAt.

valid_delivery_status(applied) -> true;
valid_delivery_status(unchanged) -> true;
valid_delivery_status(rejected) -> true;
valid_delivery_status(timeout) -> true;
valid_delivery_status(node_unavailable) -> true;
valid_delivery_status(transport_error) -> true;
valid_delivery_status(unexpected_result) -> true;
valid_delivery_status(disabled) -> true;
valid_delivery_status(_) -> false.

valid_operation(upsert) -> true;
valid_operation(enable) -> true;
valid_operation(disable) -> true;
valid_operation(revoke) -> true;
valid_operation(remove) -> true;
valid_operation(_) -> false.

validate_payload(#{device_id := DeviceId,
                   delivery_status := DeliveryStatus,
                   operation := Operation,
                   delivered_at := DeliveredAt} = Payload) ->
    case usable_id(normalize_id(DeviceId)) andalso
         valid_delivery_status(DeliveryStatus) andalso
         valid_operation(Operation) andalso
         usable_id(normalize_id(DeliveredAt)) of
        false -> {error, invalid_vpn_delivery_audit_payload};
        true ->
            case forbidden_path(Payload, []) of
                none -> ok;
                Path ->
                    {error,
                     {forbidden_vpn_delivery_audit_material,
                      lists:reverse(Path)}}
            end
    end;
validate_payload(_) ->
    {error, invalid_vpn_delivery_audit_payload}.

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
    Text = string:lowercase(binary_to_list(normalize_id(Key))),
    lists:any(
      fun(Fragment) -> string:find(Text, Fragment) =/= nomatch end,
      ["private_key", "privatekey", "key_pem", "pem_body",
       "certificate_body", "certificate_pem", "cert_pem", "ca_body",
       "ca_pem", "csr_body", "csr_pem", "secret", "password",
       "passphrase", "ovpn_body", "ovpn_profile", "artifact_body",
       "tls_auth_body", "tls_crypt_body", "shared_secret"]).

contains_pem_material(Value) ->
    Markers = [<<"-----BEGIN PRIVATE KEY-----">>,
               <<"-----BEGIN RSA PRIVATE KEY-----">>,
               <<"-----BEGIN EC PRIVATE KEY-----">>,
               <<"-----BEGIN ENCRYPTED PRIVATE KEY-----">>,
               <<"-----BEGIN CERTIFICATE-----">>,
               <<"-----BEGIN CERTIFICATE REQUEST-----">>],
    lists:any(fun(Marker) -> binary:match(Value, Marker) =/= nomatch end,
              Markers).

kvs_put_or_abort(Record) ->
    case catch kvs:put(Record) of
        ok -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {vpn_delivery_audit_kvs_write_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {vpn_delivery_audit_kvs_write_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {vpn_delivery_audit_kvs_write_failed, Other})
    end.

kvs_delete_or_abort(DeliveryId) ->
    case catch kvs:delete(?TABLE, DeliveryId) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, Reason} ->
            ias_kvs_transaction:abort(
              {vpn_delivery_audit_kvs_delete_failed, Reason});
        {'EXIT', Reason} ->
            ias_kvs_transaction:abort(
              {vpn_delivery_audit_kvs_delete_failed, Reason});
        Other ->
            ias_kvs_transaction:abort(
              {vpn_delivery_audit_kvs_delete_failed, Other})
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
            {error, {vpn_delivery_audit_kvs_start_failed, Reason}}
    end.

ensure_kvs_schema_modules() ->
    Existing = application:get_env(kvs, schema, []),
    Required = [kvs, kvs_stream, ias_kvs],
    application:set_env(kvs, schema, lists:usort(Existing ++ Required)).

validate_kvs_metadata() ->
    ExpectedFields = record_info(fields, ias_vpn_provisioning_delivery_audit),
    case kvs:table(?TABLE) of
        #table{fields = ExpectedFields,
               type = set,
               copy_type = disc_copies} ->
            ok;
        false ->
            {error, {vpn_delivery_audit_kvs_schema_missing, ?TABLE}};
        #table{} = Table ->
            {error,
             {invalid_vpn_delivery_audit_kvs_metadata,
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
                    {error, {vpn_delivery_audit_kvs_join_failed, Reason}};
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
                     {vpn_delivery_audit_kvs_table_unavailable, ?TABLE}};
                false ->
                    timer:sleep(10),
                    wait_for_kvs_table(Timeout, StartedAt)
            end
    end.

validate_kvs_access() ->
    case catch kvs:all(?TABLE) of
        Records when is_list(Records) -> ok;
        {error, Reason} ->
            {error, {vpn_delivery_audit_kvs_unavailable, Reason}};
        {'EXIT', Reason} ->
            {error, {vpn_delivery_audit_kvs_unavailable, Reason}};
        Other ->
            {error, {vpn_delivery_audit_kvs_unexpected_result, Other}}
    end.

delivery_id() ->
    Random = binary:encode_hex(crypto:strong_rand_bytes(12)),
    ias_html:join([<<"vpn_delivery_">>,
                   integer_to_binary(erlang:system_time(microsecond)),
                   <<"_">>,
                   Random]).

valid_revision(undefined) -> true;
valid_revision(Revision) -> is_integer(Revision) andalso Revision >= 0.

valid_optional_id(undefined) -> true;
valid_optional_id(Id) -> usable_id(Id).

normalize_optional_id(undefined) -> undefined;
normalize_optional_id(<<>>) -> undefined;
normalize_optional_id([]) -> undefined;
normalize_optional_id(Id) -> normalize_id(Id).

normalize_id(undefined) -> undefined;
normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
normalize_id(Id) -> ias_html:text(Id).

usable_id(Id) -> is_binary(Id) andalso byte_size(Id) > 0.
