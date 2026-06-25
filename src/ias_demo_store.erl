-module(ias_demo_store).
-export([
    ensure/0,
    add_import/1,
    get/1,
    all/0,
    users/0,
    devices/0,
    certificates/0,
    services/0,
    security_profiles/0,
    security_policies/0,
    relationships/0,
    runtime_objects/0,
    rehydrate/0,
    projection_health/0,
    commit_graph/2,
    put_runtime_object/1,
    delete_runtime_object/2,
    clear/0,
    add_device/1,
    add_certificate/1,
    add_service/1,
    add_security_policy/1,
    add_relationship/1,
    delete_relationship/1,
    add_enrollment_result/1,
    get_enrollment_result/1,
    reset/0
]).

-define(TABLE, ias_demo_store).
-define(OWNER, ias_demo_store_owner).
-define(PROJECTION_HEALTH_KEY, {?MODULE, projection_health}).

ensure() ->
    ensure_table().

add_import(ImportMap) when is_map(ImportMap) ->
    ensure(),
    ImportId = import_id(),
    CreatedAt = created_at(),
    Records = import_records(ImportMap, ImportId, CreatedAt),
    case commit_graph(Records, []) of
        {ok, _Graph} ->
            ImportId;
        {error, Reason} ->
            erlang:error({demo_store_graph_write_failed, Reason})
    end.

get(undefined) ->
    not_found;
get(Id) ->
    ensure(),
    TextId = normalize_id(Id),
    case [Object || Object <- objects(),
        normalize_id(maps:get(id, Object, undefined)) =:= TextId] of
        [Object | _] -> {ok, Object};
        [] -> not_found
    end.

normalize_id(Id) when is_binary(Id) ->
    Id;
normalize_id(Id) when is_list(Id) ->
    unicode:characters_to_binary(Id);
normalize_id(Id) ->
    ias_html:text(Id).

all() ->
    ensure(),
    Objects = objects(),
    lists:sort(fun compare_records/2, Objects).

users() ->
    list(user).

devices() ->
    list(device).

certificates() ->
    list(certificate).

services() ->
    list(vpn_service).

security_profiles() ->
    list(security_profile).

security_policies() ->
    list(security_policy).

relationships() ->
    list(relationship).

runtime_objects() ->
    ensure(),
    Stored = [durable_overlay(Object) || {_Key, Object} <- ets:tab2list(?TABLE)],
    lists:sort(fun compare_records/2, Stored).

rehydrate() ->
    ensure(),
    case prepare_expected_projection() of
        {ok, Entries, DurableCounts} ->
            case replace_runtime_projection(Entries) of
                ok ->
                    mark_rehydration_success(),
                    RuntimeCounts = projection_counts(ets:tab2list(?TABLE)),
                    {ok, projection_report(synchronized,
                                           DurableCounts,
                                           RuntimeCounts,
                                           projection_metadata())};
                {error, Reason} = Error ->
                    mark_rehydration_failure(Reason),
                    Error
            end;
        {error, Reason} = Error ->
            mark_rehydration_failure(Reason),
            Error
    end.

projection_health() ->
    ensure(),
    RuntimeEntries = ets:tab2list(?TABLE),
    RuntimeCounts = projection_counts(RuntimeEntries),
    Metadata = projection_metadata(),
    case prepare_expected_projection() of
        {ok, ExpectedEntries, DurableCounts} ->
            Status = case projection_matches(ExpectedEntries, RuntimeEntries) of
                         true -> synchronized;
                         false -> mismatch
                     end,
            projection_report(Status, DurableCounts, RuntimeCounts, Metadata);
        {error, Reason} ->
            projection_report(unavailable,
                              undefined,
                              RuntimeCounts,
                              Metadata#{last_rehydration_error => Reason})
    end.

commit_graph(Objects0, Relationships0)
  when is_list(Objects0), is_list(Relationships0) ->
    ensure(),
    case prepare_graph(Objects0, Relationships0) of
        {ok, Objects, Relationships} ->
            case ias_domain_store:transaction(
                   fun() -> persist_graph(Objects, Relationships) end) of
                {ok, {ObjectRecords, RelationshipRecords}} ->
                    project_graph(ObjectRecords, RelationshipRecords);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
commit_graph(_Objects, _Relationships) ->
    {error, invalid_domain_graph}.

put_runtime_object(#{kind := _Kind, id := _Id} = Object) ->
    ensure(),
    case ias_domain_store:put(Object) of
        {ok, DomainRecord, _Change} ->
            Projection = maps:get(payload, DomainRecord),
            case persist_device_authority(Projection) of
                ok ->
                    Stored = durable_overlay(Projection),
                    Key = runtime_key(Stored),
                    true = ets:insert(?TABLE, {Key, Stored}),
                    Stored;
                {error, Reason} ->
                    erlang:error({demo_store_device_authority_write_failed, Reason})
            end;
        {error, Reason} ->
            erlang:error({demo_store_domain_write_failed, Reason})
    end.

delete_runtime_object(Kind, Id0) ->
    ensure(),
    Id = normalize_id(Id0),
    case ias_domain_store:delete(Kind, Id) of
        ok ->
            case maybe_delete_device_authority(Kind, Id) of
                ok ->
                    ets:delete(?TABLE, {Kind, Id}),
                    ok;
                {error, Reason} ->
                    {error, {vpn_authority_delete_failed, Reason}}
            end;
        {error, _} = Error ->
            Error
    end.

clear() ->
    ensure(),
    ok = ias_domain_store:reset(),
    ok = ias_vpn_authority:reset(),
    ok = ias_vpn_reconciliation_incidents:reset(),
    ets:delete_all_objects(?TABLE),
    persistent_term:erase(?PROJECTION_HEALTH_KEY),
    ok.

add_device(Device) when is_map(Device) ->
    add_legacy(device, Device).

add_certificate(Certificate) when is_map(Certificate) ->
    add_legacy(certificate, Certificate).

add_service(Service) when is_map(Service) ->
    add_legacy(vpn_service, Service).

add_security_policy(Policy) when is_map(Policy) ->
    add_legacy(security_policy, Policy).

add_relationship(Relationship) when is_map(Relationship) ->
    ensure(),
    CreatedAt = created_at(),
    Id = maps:get(relationship_id, Relationship, relationship_id()),
    Stored = #{id => Id,
               relationship_id => Id,
               kind => relationship,
               relation_type => maps:get(relation_type, Relationship, undefined),
               source_kind => maps:get(source_kind, Relationship, undefined),
               source_id => maps:get(source_id, Relationship, undefined),
               target_kind => maps:get(target_kind, Relationship, undefined),
               target_id => maps:get(target_id, Relationship, undefined),
               score => maps:get(score, Relationship, 0),
               warnings => maps:get(warnings, Relationship, []),
               created_at => maps:get(created_at, Relationship, CreatedAt)},
    put_runtime_object(Stored).

delete_relationship(Id) ->
    delete_runtime_object(relationship, Id).

add_enrollment_result(Result) when is_map(Result) ->
    ensure(),
    CreatedAt = created_at(),
    Id = maps:get(enrollment_id, Result, enrollment_id()),
    Stored = #{id => Id,
               enrollment_id => Id,
               kind => cmp_enrollment_result,
               source => cmp_demo_enrollment,
               created_at => maps:get(created_at, Result, CreatedAt),
               subject => maps:get(subject, Result, <<"not found">>),
               issuer => maps:get(issuer, Result, <<"not found">>),
               not_before => maps:get(not_before, Result, <<"not found">>),
               not_after => maps:get(not_after, Result, <<"not found">>),
               requested_cn => maps:get(requested_cn, Result, <<"not found">>),
               enrollment_cn => maps:get(enrollment_cn, Result, <<"not found">>),
               profile => maps:get(profile, Result, <<"not found">>),
               cmp_server => maps:get(cmp_server, Result, <<"not found">>),
               device_id => maps:get(device_id, Result, undefined),
               csr_fingerprint => maps:get(csr_fingerprint, Result, undefined),
               csr_public_key_fingerprint => maps:get(csr_public_key_fingerprint, Result, undefined),
               certificate_public_key_fingerprint => maps:get(certificate_public_key_fingerprint, Result, undefined),
               private_key_reference => maps:get(private_key_reference, Result, undefined),
               key_rotation => maps:get(key_rotation, Result, undefined),
               public_key_fingerprint => maps:get(public_key_fingerprint, Result, undefined),
               issued_via => maps:get(issued_via, Result, undefined),
               private_key_stored => false,
               certificate_body_stored => false},
    Persisted = put_runtime_object(Stored),
    maps:get(id, Persisted).

get_enrollment_result(undefined) ->
    not_found;
get_enrollment_result(Id) ->
    ensure(),
    TextId = normalize_id(Id),
    case ets:lookup(?TABLE, {cmp_enrollment_result, TextId}) of
        [{_Key, Object}] -> {ok, Object};
        [] -> not_found
    end.

reset() ->
    clear().

import_records(ImportMap, ImportId, CreatedAt) ->
    Common = #{source => ovpn_demo_import,
               import_id => ImportId,
               created_at => CreatedAt},
    Device = maps:get(device, ImportMap, #{}),
    Certificate = maps:get(certificate, ImportMap, #{}),
    VpnService = maps:get(vpn_service, ImportMap, #{}),
    [
        Common#{id => record_id(device, ImportId),
                kind => device,
                type => maps:get(type, Device, <<"vpn-client">>),
                endpoint => maps:get(endpoint, Device, not_found),
                transport => maps:get(transport, Device, not_found),
                tunnel_device => maps:get(tunnel_device, Device, not_found),
                private_key_provider => maps:get(private_key_provider, Device, <<"device_file">>),
                private_key_ref => maps:get(private_key_ref, Device, <<"client.key">>)},
        Common#{id => record_id(certificate, ImportId),
                kind => certificate,
                ca_present => maps:get(ca_present, Certificate, false),
                client_certificate_present => maps:get(client_certificate_present, Certificate, false),
                private_key_present => maps:get(private_key_present, Certificate, false),
                private_key_stored => false,
                tls_auth_present => maps:get(tls_auth_present, Certificate, false)},
        Common#{id => record_id(vpn_service, ImportId),
                kind => vpn_service,
                service => maps:get(service, VpnService, openvpn),
                remote => maps:get(remote, VpnService, not_found),
                protocol => maps:get(protocol, VpnService, not_found),
                cipher => maps:get(cipher, VpnService, not_found),
                compression => maps:get(compression, VpnService, false),
                routes => maps:get(routes, VpnService, 0)}
    ].

add_legacy(Kind, Object) ->
    ensure(),
    CreatedAt = created_at(),
    ImportId = maps:get(import_id, Object, legacy_import),
    Id = maps:get(id, Object, record_id(Kind, ImportId)),
    Stored0 = Object#{id => Id,
                      kind => Kind,
                      source => maps:get(source, Object, ovpn_demo_import),
                      import_id => ImportId,
                      created_at => maps:get(created_at, Object, CreatedAt)},
    Stored = with_kind_defaults(Kind, Stored0),
    put_runtime_object(Stored).

with_kind_defaults(device, Object) ->
    Defaults = ias_device_key_ref:defaults(),
    maps:merge(Defaults, Object);
with_kind_defaults(_Kind, Object) ->
    Object.

list(Kind) ->
    [Object || Object <- all(), maps:get(kind, Object, undefined) =:= Kind].

objects() ->
    Stored = [durable_overlay(Object) || {_Key, Object} <- ets:tab2list(?TABLE)],
    StoredIds = [normalize_id(maps:get(id, Object, undefined)) || Object <- Stored],
    SeedObjects = user_objects() ++ ias_security_profile:policies() ++ ias_security_profile:profiles(),
    Seeded = [Object || Object <- SeedObjects,
                        not lists:member(normalize_id(maps:get(id, Object, undefined)), StoredIds)],
    Stored ++ Seeded.

user_objects() ->
    [User#{kind => user, source => demo_catalog} || User <- ias_demo_data:users()].

prepare_graph(Objects, Relationships0) ->
    case prepare_graph_objects(Objects, []) of
        {ok, PreparedObjects} ->
            case prepare_graph_relationships(Relationships0, []) of
                {ok, PreparedRelationships} ->
                    case unique_graph_identities(PreparedObjects ++ PreparedRelationships) of
                        ok -> {ok, PreparedObjects, PreparedRelationships};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

prepare_graph_objects([], Acc) ->
    {ok, lists:reverse(Acc)};
prepare_graph_objects([#{kind := relationship} | _Rest], _Acc) ->
    {error, relationship_must_use_graph_relationships};
prepare_graph_objects([#{kind := _Kind, id := _Id} = Object | Rest], Acc) ->
    prepare_graph_objects(Rest, [Object | Acc]);
prepare_graph_objects([_Invalid | _Rest], _Acc) ->
    {error, invalid_domain_graph_object}.

prepare_graph_relationships([], Acc) ->
    {ok, lists:reverse(Acc)};
prepare_graph_relationships([Relationship | Rest], Acc) when is_map(Relationship) ->
    case relationship_record(Relationship) of
        {ok, Stored} ->
            prepare_graph_relationships(Rest, [Stored | Acc]);
        {error, _} = Error ->
            Error
    end;
prepare_graph_relationships([_Invalid | _Rest], _Acc) ->
    {error, invalid_domain_graph_relationship}.

relationship_record(Relationship) ->
    CreatedAt = created_at(),
    Id = maps:get(relationship_id, Relationship,
                  maps:get(id, Relationship, relationship_id())),
    case Id of
        undefined ->
            {error, invalid_domain_graph_relationship};
        _ ->
            {ok,
             #{id => Id,
               relationship_id => Id,
               kind => relationship,
               relation_type => maps:get(relation_type, Relationship, undefined),
               source_kind => maps:get(source_kind, Relationship, undefined),
               source_id => maps:get(source_id, Relationship, undefined),
               target_kind => maps:get(target_kind, Relationship, undefined),
               target_id => maps:get(target_id, Relationship, undefined),
               score => maps:get(score, Relationship, 0),
               warnings => maps:get(warnings, Relationship, []),
               created_at => maps:get(created_at, Relationship, CreatedAt)}}
    end.

unique_graph_identities(Records) ->
    unique_graph_identities(Records, #{}).

unique_graph_identities([], _Seen) ->
    ok;
unique_graph_identities([#{kind := Kind, id := Id} | Rest], Seen) ->
    Key = {Kind, normalize_id(Id)},
    case maps:is_key(Key, Seen) of
        true -> {error, {duplicate_domain_graph_identity, Kind, Id}};
        false -> unique_graph_identities(Rest, Seen#{Key => true})
    end;
unique_graph_identities([_Invalid | _Rest], _Seen) ->
    {error, invalid_domain_graph_record}.

persist_graph(Objects, Relationships) ->
    case persist_graph_records(Objects, []) of
        {ok, ObjectRecords} ->
            case persist_graph_records(Relationships, []) of
                {ok, RelationshipRecords} ->
                    {ObjectRecords, RelationshipRecords};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

persist_graph_records([], Acc) ->
    {ok, lists:reverse(Acc)};
persist_graph_records([Object | Rest], Acc) ->
    case ias_domain_store:put(Object) of
        {ok, DomainRecord, _Change} ->
            persist_graph_records(Rest, [DomainRecord | Acc]);
        {error, _} = Error ->
            Error
    end.

prepare_expected_projection() ->
    case ias_domain_store:all() of
        {ok, Records} ->
            case ias_vpn_authority:ensure() of
                ok -> build_expected_projection(Records);
                {error, Reason} ->
                    {error, {vpn_authority_unavailable, Reason}}
            end;
        {error, _} = Error ->
            Error
    end.

build_expected_projection(Records) ->
    try build_expected_projection(Records, #{}) of
        {ok, EntryMap} ->
            Entries = lists:sort(maps:to_list(EntryMap)),
            {ok, Entries, projection_counts(Entries)};
        {error, _} = Error ->
            Error
    catch
        exit:{vpn_authority_overlay_failed, Reason} ->
            {error, {vpn_authority_overlay_failed, Reason}};
        Class:Reason:Stacktrace ->
            {error,
             {demo_store_projection_build_failed,
              {Class, Reason, Stacktrace}}}
    end.

build_expected_projection([], EntryMap) ->
    {ok, EntryMap};
build_expected_projection([Record | Rest], EntryMap) ->
    Kind = maps:get(kind, Record, undefined),
    ObjectId = maps:get(object_id, Record, undefined),
    Payload = maps:get(payload, Record, undefined),
    Projected = durable_overlay(Payload),
    Key = runtime_key(Projected),
    case Key =:= {Kind, ObjectId} of
        false ->
            {error, {invalid_rehydration_identity, {Kind, ObjectId}, Key}};
        true ->
            case maps:is_key(Key, EntryMap) of
                true ->
                    {error, {duplicate_rehydration_identity, Key}};
                false ->
                    build_expected_projection(Rest,
                                              EntryMap#{Key => Projected})
            end
    end.

replace_runtime_projection(Entries) ->
    Previous = ets:tab2list(?TABLE),
    try
        true = ets:delete_all_objects(?TABLE),
        ok = insert_graph_entries(Entries),
        case projection_matches(Entries, ets:tab2list(?TABLE)) of
            true -> ok;
            false -> erlang:error(projection_verification_failed)
        end
    catch
        Class:Reason:Stacktrace ->
            restore_runtime_projection(
              Previous,
              {Class, Reason, Stacktrace})
    end.

restore_runtime_projection(Previous, Failure) ->
    try
        true = ets:delete_all_objects(?TABLE),
        ok = insert_graph_entries(Previous),
        {error, {demo_store_projection_replace_failed, Failure}}
    catch
        RestoreClass:RestoreReason:RestoreStacktrace ->
            {error,
             {demo_store_projection_replace_and_restore_failed,
              Failure,
              {RestoreClass, RestoreReason, RestoreStacktrace}}}
    end.

projection_matches(ExpectedEntries, RuntimeEntries) ->
    maps:from_list(ExpectedEntries) =:= maps:from_list(RuntimeEntries).

projection_counts(Entries) ->
    lists:foldl(
      fun({_Key, #{kind := relationship}}, Counts) ->
              Counts#{relationships => maps:get(relationships, Counts) + 1,
                      total => maps:get(total, Counts) + 1};
         ({_Key, _Object}, Counts) ->
              Counts#{objects => maps:get(objects, Counts) + 1,
                      total => maps:get(total, Counts) + 1}
      end,
      #{objects => 0, relationships => 0, total => 0},
      Entries).

projection_report(Status, DurableCounts, RuntimeCounts, Metadata) ->
    DurableObjects = count_value(objects, DurableCounts),
    DurableRelationships = count_value(relationships, DurableCounts),
    DurableTotal = count_value(total, DurableCounts),
    maps:merge(
      #{status => Status,
        durable_objects => DurableObjects,
        durable_relationships => DurableRelationships,
        durable_total => DurableTotal,
        ets_projection_objects => maps:get(objects, RuntimeCounts),
        ets_projection_relationships => maps:get(relationships, RuntimeCounts),
        ets_projection_total => maps:get(total, RuntimeCounts)},
      Metadata).

count_value(_Key, undefined) ->
    undefined;
count_value(Key, Counts) ->
    maps:get(Key, Counts).

projection_metadata() ->
    persistent_term:get(
      ?PROJECTION_HEALTH_KEY,
      #{last_rehydrated_at => undefined,
        last_rehydration_attempt_at => undefined,
        last_rehydration_error => undefined}).

mark_rehydration_success() ->
    Now = created_at(),
    persistent_term:put(
      ?PROJECTION_HEALTH_KEY,
      #{last_rehydrated_at => Now,
        last_rehydration_attempt_at => Now,
        last_rehydration_error => undefined}),
    ok.

mark_rehydration_failure(Reason) ->
    Metadata = projection_metadata(),
    persistent_term:put(
      ?PROJECTION_HEALTH_KEY,
      Metadata#{last_rehydration_attempt_at => created_at(),
                last_rehydration_error => Reason}),
    ok.

project_graph(ObjectRecords, RelationshipRecords) ->
    ObjectProjections = [maps:get(payload, Record) || Record <- ObjectRecords],
    RelationshipProjections = [maps:get(payload, Record)
                               || Record <- RelationshipRecords],
    case persist_device_authorities(ObjectProjections) of
        ok ->
            StoredObjects = [durable_overlay(Object) || Object <- ObjectProjections],
            StoredRelationships = [durable_overlay(Relationship)
                                   || Relationship <- RelationshipProjections],
            Entries = [{runtime_key(Object), Object}
                       || Object <- StoredObjects ++ StoredRelationships],
            ok = insert_graph_entries(Entries),
            {ok, #{objects => StoredObjects,
                   relationships => StoredRelationships}};
        {error, Reason} ->
            {error, {device_authority_write_failed, Reason}}
    end.

insert_graph_entries([]) ->
    ok;
insert_graph_entries(Entries) ->
    true = ets:insert(?TABLE, Entries),
    ok.

persist_device_authorities([]) ->
    ok;
persist_device_authorities([Object | Rest]) ->
    case persist_device_authority(Object) of
        ok -> persist_device_authorities(Rest);
        {error, _} = Error -> Error
    end.

persist_device_authority(#{kind := device} = Device) ->
    ias_vpn_authority:sync_device(Device);
persist_device_authority(_Object) ->
    ok.

maybe_delete_device_authority(device, Id) ->
    ias_vpn_authority:delete(Id);
maybe_delete_device_authority(_Kind, _Id) ->
    ok.

durable_overlay(Object) ->
    ias_vpn_authority:overlay_device(Object).

runtime_key(#{kind := Kind, id := Id}) ->
    {Kind, normalize_id(Id)}.

compare_records(A, B) ->
    {maps:get(import_id, A, undefined),
     kind_order(maps:get(kind, A, undefined)),
     maps:get(id, A, undefined)}
        =< {maps:get(import_id, B, undefined),
            kind_order(maps:get(kind, B, undefined)),
            maps:get(id, B, undefined)}.

kind_order(user) -> 1;
kind_order(device) -> 2;
kind_order(certificate) -> 3;
kind_order(verification) -> 4;
kind_order(certificate_replacement) -> 5;
kind_order(certificate_revocation) -> 6;
kind_order(vpn_service) -> 7;
kind_order(security_profile) -> 8;
kind_order(security_policy) -> 9;
kind_order(relationship) -> 10;
kind_order(ovpn_provisioning) -> 11;
kind_order(_) -> 99.

import_id() ->
    Count = erlang:unique_integer([positive, monotonic]),
    ias_html:join([<<"ovpn_import_">>, Count]).

record_id(Kind, ImportId) ->
    ias_html:join([ImportId, <<"_">>, Kind]).

relationship_id() ->
    ias_html:join([<<"relationship_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

enrollment_id() ->
    ias_html:join([<<"cmp_enrollment_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ensure_owner(),
            wait_table(20);
        _ ->
            ok
    end.

ensure_owner() ->
    case whereis(?OWNER) of
        undefined ->
            spawn(fun table_owner/0),
            ok;
        _Pid ->
            ok
    end.

wait_table(0) ->
    case ets:info(?TABLE) of
        undefined -> error({demo_store_unavailable, ?TABLE});
        _ -> ok
    end;
wait_table(Attempts) ->
    case ets:info(?TABLE) of
        undefined ->
            timer:sleep(5),
            wait_table(Attempts - 1);
        _ ->
            ok
    end.

table_owner() ->
    case catch register(?OWNER, self()) of
        true ->
            ensure_owner_table(),
            table_owner_loop();
        _ ->
            ok
    end.

ensure_owner_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.

table_owner_loop() ->
    receive
        stop -> ok;
        _ -> table_owner_loop()
    end.
