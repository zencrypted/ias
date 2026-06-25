-module(ias_domain_store).

-export([ensure/0,
         put/1,
         get/2,
         delete/2,
         all/0,
         transaction/1,
         validate_all/0,
         reset/0]).

-include("ias_domain_object.hrl").

-define(TABLE, ias_domain_object).
-define(SCHEMA_VERSION, 1).
-define(WAIT_TIMEOUT, 5000).
-define(TRANSACTION_FLAG, ias_domain_store_transaction).

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

get(Kind0, ObjectId0) ->
    case normalize_identity(Kind0, ObjectId0) of
        {ok, Kind, ObjectId} ->
            Key = {Kind, ObjectId},
            case transaction(fun() -> mnesia:read(?TABLE, Key, read) end) of
                {ok, []} ->
                    not_found;
                {ok, [Record]} ->
                    case validate_record(Record) of
                        ok -> {ok, record_to_map(Record)};
                        {error, Reason} -> {error, Reason}
                    end;
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
                       mnesia:delete({?TABLE, Key}),
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
               Records = mnesia:foldl(
                           fun(Record, Acc) ->
                               ok = validate_record_or_abort(Record),
                               [Record | Acc]
                           end,
                           [],
                           ?TABLE),
               lists:foreach(fun validate_relationship_references_or_abort/1,
                             Records),
               [record_to_map(Record) || Record <- Records]
           end) of
        {ok, Records} ->
            {ok, lists:sort(fun compare_records/2, Records)};
        {error, _} = Error ->
            Error
    end.

transaction(Fun) when is_function(Fun, 0) ->
    case erlang:get(?TRANSACTION_FLAG) of
        true ->
            {ok, Fun()};
        _ ->
            case ensure_storage() of
                ok ->
                    case mnesia:sync_transaction(
                           fun() ->
                               erlang:put(?TRANSACTION_FLAG, true),
                               try Fun()
                               after
                                   erlang:erase(?TRANSACTION_FLAG)
                               end
                           end) of
                        {atomic, Result} -> {ok, Result};
                        {aborted, Reason} -> {error, normalize_abort(Reason)}
                    end;
                {error, _} = Error ->
                    Error
            end
    end;
transaction(_Fun) ->
    {error, invalid_domain_transaction}.

validate_all() ->
    case transaction(
           fun() ->
               Records = mnesia:foldl(
                           fun(Record, Acc) ->
                               ok = validate_record_or_abort(Record),
                               [Record | Acc]
                           end,
                           [],
                           ?TABLE),
               lists:foreach(fun validate_relationship_references_or_abort/1,
                             Records),
               ok
           end) of
        {ok, ok} -> ok;
        {error, _} = Error -> Error
    end.

reset() ->
    case ensure_storage() of
        ok ->
            case mnesia:clear_table(?TABLE) of
                {atomic, ok} -> ok;
                {aborted, Reason} ->
                    {error, {domain_store_reset_failed, Reason}}
            end;
        {error, _} = Error ->
            Error
    end.

write_projection(Projection) ->
    Kind = maps:get(kind, Projection),
    ObjectId = maps:get(id, Projection),
    Key = {Kind, ObjectId},
    ok = validate_relationship_projection_or_abort(Projection),
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
            ok = validate_record_or_abort(Record),
            mnesia:write(Record),
            {Record, changed};
        [Record0] ->
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
                    mnesia:write(Record),
                    {Record, changed}
            end
    end.

persistent_projection(#{kind := Kind0, id := ObjectId0} = Object) ->
    case requested_schema_version(Object) of
        ok ->
            case normalize_identity(Kind0, ObjectId0) of
                {ok, Kind, ObjectId} ->
                    case forbidden_material_path(Object) of
                        none ->
                            Fields = lists:usort(common_fields() ++ kind_fields(Kind)),
                            Projection0 = maps:with(Fields, Object),
                            Projection = normalize_projection(
                                           Kind,
                                           Projection0#{kind => Kind,
                                                        id => ObjectId}),
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
    Projection#{source_id => normalize_id(maps:get(source_id, Projection, undefined)),
                target_id => normalize_id(maps:get(target_id, Projection, undefined))};
normalize_projection(_Kind, Projection) ->
    Projection.

validate_projection(#{kind := Kind, id := ObjectId} = Projection) ->
    Checks = [supported_kind(Kind),
              nonempty_binary(ObjectId),
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
              nonempty_binary(SourceId),
              supported_kind(TargetKind),
              nonempty_binary(TargetId)],
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
            case mnesia:read(?TABLE, {Kind, ObjectId}, read) of
                [_Record] -> ok;
                [] -> mnesia:abort(
                        {domain_store_invalid_record,
                         {missing_domain_reference, Kind, ObjectId}})
            end
    end.

ensure_not_referenced_or_abort(relationship, _ObjectId) ->
    ok;
ensure_not_referenced_or_abort(Kind, ObjectId) ->
    References = mnesia:foldl(
                   fun(#ias_domain_object{kind = relationship,
                                          object_id = RelationshipId,
                                          payload = Projection}, Acc) ->
                           case relationship_references(Projection, Kind, ObjectId) of
                               true -> [RelationshipId | Acc];
                               false -> Acc
                           end;
                      (_Record, Acc) ->
                           Acc
                   end,
                   [],
                   ?TABLE),
    case References of
        [] -> ok;
        _ -> mnesia:abort(
               {domain_store_invalid_record,
                {domain_object_referenced, Kind, ObjectId,
                 lists:sort(References)}})
    end.

relationship_references(Projection, Kind, ObjectId) ->
    {maps:get(source_kind, Projection, undefined),
     maps:get(source_id, Projection, undefined)} =:= {Kind, ObjectId}
        orelse
    {maps:get(target_kind, Projection, undefined),
     maps:get(target_id, Projection, undefined)} =:= {Kind, ObjectId}.

validate_record_or_abort(Record) ->
    case validate_record(Record) of
        ok -> ok;
        {error, Reason} ->
            mnesia:abort({domain_store_invalid_record, Reason})
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
              maps:get(id, Projection, undefined) =:= ObjectId,
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
    case ensure_mnesia_running() of
        ok ->
            case ensure_disc_schema() of
                ok -> ensure_table();
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

ensure_mnesia_running() ->
    case catch mnesia:system_info(is_running) of
        yes -> ok;
        starting -> wait_for_mnesia(?WAIT_TIMEOUT);
        no -> start_mnesia();
        stopping -> {error, {domain_store_mnesia_unavailable, stopping}};
        {'EXIT', _} -> start_mnesia();
        State -> {error, {domain_store_mnesia_unavailable, State}}
    end.

start_mnesia() ->
    case ensure_mnesia_schema() of
        ok ->
            case application:ensure_all_started(mnesia) of
                {ok, _Started} -> wait_for_mnesia(?WAIT_TIMEOUT);
                {error, Reason} ->
                    {error, {domain_store_mnesia_start_failed, Reason}}
            end;
        {error, _} = Error ->
            Error
    end.

ensure_mnesia_schema() ->
    case mnesia:create_schema([node()]) of
        ok -> ok;
        {error, Reason} ->
            case contains_already_exists(Reason) of
                true -> ok;
                false -> {error, {domain_store_schema_create_failed, Reason}}
            end
    end.

wait_for_mnesia(Timeout) ->
    wait_for_mnesia(Timeout, erlang:monotonic_time(millisecond)).

wait_for_mnesia(Timeout, StartedAt) ->
    case catch mnesia:system_info(is_running) of
        yes -> ok;
        State ->
            Elapsed = erlang:monotonic_time(millisecond) - StartedAt,
            case Elapsed >= Timeout of
                true -> {error, {domain_store_mnesia_start_timeout, State}};
                false ->
                    timer:sleep(10),
                    wait_for_mnesia(Timeout, StartedAt)
            end
    end.

ensure_disc_schema() ->
    case catch mnesia:table_info(schema, storage_type) of
        disc_copies -> ok;
        ram_copies ->
            case mnesia:change_table_copy_type(schema, node(), disc_copies) of
                {atomic, ok} -> ok;
                {aborted, Reason} ->
                    case contains_already_exists(Reason) of
                        true -> ok;
                        false ->
                            {error, {domain_store_schema_persistence_failed, Reason}}
                    end
            end;
        {'EXIT', Reason} ->
            {error, {domain_store_schema_unavailable, Reason}};
        StorageType ->
            {error, {domain_store_invalid_schema_storage, StorageType}}
    end.

ensure_table() ->
    case lists:member(?TABLE, mnesia:system_info(tables)) of
        true -> wait_and_validate_table();
        false -> create_table()
    end.

create_table() ->
    Options = [{attributes, record_info(fields, ias_domain_object)},
               {type, set},
               {disc_copies, [node()]}],
    case mnesia:create_table(?TABLE, Options) of
        {atomic, ok} -> wait_and_validate_table();
        {aborted, Reason} ->
            case contains_already_exists(Reason) of
                true -> wait_and_validate_table();
                false -> {error, {domain_store_table_create_failed, Reason}}
            end
    end.

wait_and_validate_table() ->
    case mnesia:wait_for_tables([?TABLE], ?WAIT_TIMEOUT) of
        ok -> validate_table();
        {timeout, Tables} ->
            {error, {domain_store_table_unavailable, Tables}};
        {error, Reason} ->
            {error, {domain_store_table_unavailable, Reason}}
    end.

validate_table() ->
    ExpectedAttributes = record_info(fields, ias_domain_object),
    ActualAttributes = mnesia:table_info(?TABLE, attributes),
    StorageType = mnesia:table_info(?TABLE, storage_type),
    TableType = mnesia:table_info(?TABLE, type),
    case {ActualAttributes, StorageType, TableType} of
        {ExpectedAttributes, disc_copies, set} -> ok;
        _ ->
            {error,
             {invalid_domain_store_table,
              #{attributes => ActualAttributes,
                storage_type => StorageType,
                type => TableType}}}
    end.

normalize_abort({domain_store_invalid_record, Reason}) -> Reason;
normalize_abort(Reason) -> {domain_store_transaction_failed, Reason}.

contains_already_exists(already_exists) -> true;
contains_already_exists(Term) when is_tuple(Term) ->
    lists:any(fun contains_already_exists/1, tuple_to_list(Term));
contains_already_exists(Term) when is_list(Term) ->
    lists:any(fun contains_already_exists/1, Term);
contains_already_exists(_) -> false.

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
    case forbidden_key(Key) of
        true -> lists:reverse([Key | Path]);
        false ->
            case forbidden_material_path(Value, [Key | Path]) of
                none -> forbidden_map_entries(Rest, Path);
                Found -> Found
            end
    end.

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

forbidden_key(Key) when is_atom(Key) ->
    forbidden_key_name(atom_to_binary(Key, utf8));
forbidden_key(Key) when is_binary(Key) ->
    forbidden_key_name(Key);
forbidden_key(Key) when is_list(Key) ->
    forbidden_key_name(unicode:characters_to_binary(Key));
forbidden_key(_Key) ->
    false.

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
    [owner, user_id, type, endpoint, transport, tunnel_device,
     private_key_provider, private_key_ref, private_key_stored,
     certificate_body_stored, ca_body_stored, profile_id,
     security_profile_id, certificate_id, vpn_service_id,
     ca_certificate_id, certificate_status, device_status, serial,
     manufacturer, model, public_key_fingerprint];
kind_fields(certificate) ->
    [user, user_id, user_name, profile, profile_id, subject, subject_cn,
     issuer, issuer_cn, serial, not_before, not_after, fingerprint_sha256,
     public_key_fingerprint, csr_fingerprint, csr_public_key_fingerprint,
     certificate_public_key_fingerprint, role, services, attributes,
     trust_level, device_lock, two_factor, source_certificate_id, peer_id,
     trusted, key_match, material_type, certificate_role,
     certificate_status, device_id, enrollment_id, private_key_reference,
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
     certificate_id, ca_certificate_id, security_profile_id];
kind_fields(verification) ->
    [certificate_id, certificate_subject, verification_status,
     authorization_status, resolved_profile, resolved_policy, trusted,
     key_match];
kind_fields(security_policy) ->
    [policy_id, profile_id, decision, rules, requirements, services,
     attributes, trust_level, device_lock, two_factor, status];
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
    [username, display_name, email, role, profile_id, status, attributes];
kind_fields(security_profile) ->
    [profile_id, role, services, attributes, trust_level, device_lock,
     two_factor, policies, status];
kind_fields(ovpn_provisioning) ->
    [provisioning_id, mode, subject_kind, subject_id, device_id,
     certificate_id, vpn_service_id, ca_certificate_id, authorization,
     authorization_reason, status, material_status, material_requirements,
     material_sources, material_components, assembly_status,
     assembly_reason, next_step, artifact_status, delivery_status,
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

nonempty_binary(Value) when is_binary(Value) -> byte_size(Value) > 0;
nonempty_binary(_) -> false.

now_seconds() -> erlang:system_time(second).
