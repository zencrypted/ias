-module(ias_demo_state).
-export([summary/0,
         clear/0,
         export/0,
         import/1]).

-define(FORMAT, <<"ias_demo_state_v1">>).

summary() ->
    Objects = runtime_objects(),
    Relationships = [Object || Object <- Objects,
                              maps:get(kind, Object, undefined) =:= relationship],
    DomainObjects = [Object || Object <- Objects,
                              maps:get(kind, Object, undefined) =/= relationship],
    #{objects => length(DomainObjects),
      relationships => length(Relationships),
      total_records => length(Objects)}.

clear() ->
    ias_demo_store:clear().

export() ->
    Objects = runtime_objects(),
    Relationships = [Object || Object <- Objects,
                              maps:get(kind, Object, undefined) =:= relationship],
    DomainObjects = [Object || Object <- Objects,
                              maps:get(kind, Object, undefined) =/= relationship],
    Snapshot = #{
        <<"format">> => ?FORMAT,
        <<"exported_at">> => created_at(),
        <<"objects">> => [record_to_json(Object) || Object <- DomainObjects],
        <<"relationships">> => [record_to_json(Relationship) || Relationship <- Relationships]
    },
    iolist_to_binary(jiffy:encode(Snapshot, [pretty])).

import(Json) ->
    case decode_snapshot(Json) of
        {ok, Snapshot} ->
            restore_snapshot(Snapshot);
        {error, Reason} ->
            {error, Reason}
    end.

runtime_objects() ->
    ias_demo_store:runtime_objects().

decode_snapshot(Json) ->
    try jiffy:decode(ias_html:text(Json), [return_maps]) of
        Snapshot when is_map(Snapshot) ->
            validate_snapshot(Snapshot);
        _ ->
            {error, malformed_snapshot}
    catch
        _:_ ->
            {error, malformed_snapshot}
    end.

validate_snapshot(#{<<"format">> := ?FORMAT,
                    <<"objects">> := Objects,
                    <<"relationships">> := Relationships} = Snapshot)
  when is_list(Objects), is_list(Relationships) ->
    {ok, Snapshot};
validate_snapshot(_) ->
    {error, invalid_snapshot_format}.

restore_snapshot(Snapshot) ->
    Objects = maps:get(<<"objects">>, Snapshot, []),
    Relationships = maps:get(<<"relationships">>, Snapshot, []),
    DecodedObjects = [decode_record(JsonRecord) || JsonRecord <- Objects],
    DecodedRelationships = [decode_record(JsonRecord) || JsonRecord <- Relationships],
    ValidObjects = [Object || {ok, Object} <- DecodedObjects,
                             valid_object(Object)],
    ValidRelationships = [Relationship || {ok, Relationship} <- DecodedRelationships,
                                         valid_relationship(Relationship)],
    Skipped = skipped_count(DecodedObjects, ValidObjects) +
        skipped_count(DecodedRelationships, ValidRelationships),
    ias_demo_store:clear(),
    [ias_demo_store:put_runtime_object(Object) || Object <- ValidObjects],
    UniqueRelationships = unique_relationships(ValidRelationships),
    [ias_demo_store:put_runtime_object(Relationship) || Relationship <- UniqueRelationships],
    #{imported_objects => length(ValidObjects),
      imported_relationships => length(UniqueRelationships),
      skipped_invalid_records => Skipped + length(ValidRelationships) - length(UniqueRelationships)}.

skipped_count(Decoded, Valid) ->
    length(Decoded) - length(Valid).

valid_object(#{kind := Kind, id := Id}) when Kind =/= relationship ->
    is_supported_kind(Kind) andalso usable_id(Id);
valid_object(_) ->
    false.

valid_relationship(#{kind := relationship,
                     id := Id,
                     relation_type := RelationType,
                     source_kind := SourceKind,
                     source_id := SourceId,
                     target_kind := TargetKind,
                     target_id := TargetId}) ->
    usable_id(Id) andalso
        ias_relationship_graph:known_relationship_type(RelationType) andalso
        is_supported_kind(SourceKind) andalso
        is_supported_kind(TargetKind) andalso
        usable_id(SourceId) andalso
        usable_id(TargetId);
valid_relationship(_) ->
    false.

is_supported_kind(device) -> true;
is_supported_kind(certificate) -> true;
is_supported_kind(vpn_service) -> true;
is_supported_kind(security_policy) -> true;
is_supported_kind(relationship) -> true;
is_supported_kind(cmp_enrollment_result) -> true;
is_supported_kind(user) -> true;
is_supported_kind(security_profile) -> true;
is_supported_kind(_) -> false.

usable_id(undefined) ->
    false;
usable_id(<<>>) ->
    false;
usable_id(_Id) ->
    true.

unique_relationships(Relationships) ->
    unique_relationships(Relationships, [], []).

unique_relationships([], _Seen, Acc) ->
    lists:reverse(Acc);
unique_relationships([Relationship | Rest], Seen, Acc) ->
    Key = relationship_key(Relationship),
    case lists:member(Key, Seen) of
        true -> unique_relationships(Rest, Seen, Acc);
        false -> unique_relationships(Rest, [Key | Seen], [Relationship | Acc])
    end.

relationship_key(Relationship) ->
    {maps:get(relation_type, Relationship, undefined),
     maps:get(source_kind, Relationship, undefined),
     maps:get(source_id, Relationship, undefined),
     maps:get(target_kind, Relationship, undefined),
     maps:get(target_id, Relationship, undefined)}.

record_to_json(Record) ->
    maps:from_list([{ias_html:text(Key), value_to_json(Value)}
                    || {Key, Value} <- maps:to_list(sanitize_record(Record))]).

sanitize_record(Record) ->
    Sanitized = maps:without(secret_keys(), Record),
    Sanitized#{
        private_key_stored => false,
        certificate_body_stored => false
    }.

secret_keys() ->
    [private_key, private_key_body, private_key_pem, key_pem,
     certificate_body, certificate_pem, cert_pem, csr_body, csr_pem,
     tls_auth_body, shared_secret].

decode_record(JsonRecord) when is_map(JsonRecord) ->
    try
        {ok, maps:from_list([{field_key(Key), json_to_value(Value)}
                             || {Key, Value} <- maps:to_list(JsonRecord)])}
    catch
        _:_ -> invalid
    end;
decode_record(_) ->
    invalid.

field_key(Key) ->
    case lists:member(Key, known_fields()) of
        true -> binary_to_existing_atom(Key, utf8);
        false -> Key
    end.

known_fields() ->
    [<<"id">>, <<"kind">>, <<"source">>, <<"import_id">>, <<"created_at">>,
     <<"type">>, <<"endpoint">>, <<"transport">>, <<"tunnel_device">>,
     <<"ca_present">>, <<"client_certificate_present">>, <<"private_key_present">>,
     <<"private_key_stored">>, <<"certificate_body_stored">>, <<"tls_auth_present">>,
     <<"service">>, <<"remote">>, <<"protocol">>, <<"cipher">>, <<"compression">>,
     <<"routes">>, <<"relationship_id">>, <<"relation_type">>, <<"source_kind">>,
     <<"source_id">>, <<"target_kind">>, <<"target_id">>, <<"score">>,
     <<"enrollment_id">>, <<"subject">>, <<"issuer">>, <<"not_before">>,
     <<"not_after">>, <<"requested_cn">>, <<"enrollment_cn">>, <<"profile">>,
     <<"cmp_server">>, <<"user">>, <<"user_name">>, <<"profile_id">>,
     <<"subject_cn">>, <<"role">>, <<"services">>, <<"attributes">>,
     <<"trust_level">>, <<"device_lock">>, <<"two_factor">>,
     <<"source_certificate_id">>, <<"policy_id">>, <<"enforcement_mode">>].

value_to_json(Value) when is_boolean(Value) ->
    Value;
value_to_json(Value) when is_atom(Value) ->
    #{<<"$atom">> => atom_to_binary(Value, utf8)};
value_to_json(Value) when is_binary(Value); is_integer(Value); is_float(Value); is_boolean(Value) ->
    Value;
value_to_json(Value) when is_list(Value) ->
    [value_to_json(Item) || Item <- Value];
value_to_json(Value) when is_map(Value) ->
    maps:from_list([{ias_html:text(Key), value_to_json(MapValue)}
                    || {Key, MapValue} <- maps:to_list(Value)]);
value_to_json(Value) ->
    ias_html:text(Value).

json_to_value(#{<<"$atom">> := Atom}) ->
    binary_to_existing_atom(Atom, utf8);
json_to_value(Value) when is_binary(Value); is_integer(Value); is_float(Value); is_boolean(Value) ->
    Value;
json_to_value(Value) when is_list(Value) ->
    [json_to_value(Item) || Item <- Value];
json_to_value(Value) when is_map(Value) ->
    maps:from_list([{field_key(Key), json_to_value(MapValue)}
                    || {Key, MapValue} <- maps:to_list(Value)]);
json_to_value(null) ->
    undefined;
json_to_value(Value) ->
    Value.

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
