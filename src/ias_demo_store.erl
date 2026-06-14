-module(ias_demo_store).
-export([
    ensure/0,
    add_import/1,
    get/1,
    all/0,
    devices/0,
    certificates/0,
    services/0,
    security_profiles/0,
    security_policies/0,
    relationships/0,
    clear/0,
    add_device/1,
    add_certificate/1,
    add_service/1,
    add_security_policy/1,
    add_relationship/1,
    add_enrollment_result/1,
    get_enrollment_result/1,
    reset/0
]).

-define(TABLE, ias_demo_store).
-define(OWNER, ias_demo_store_owner).

ensure() ->
    ensure_table().

add_import(ImportMap) when is_map(ImportMap) ->
    ensure(),
    ImportId = import_id(),
    CreatedAt = created_at(),
    Records = import_records(ImportMap, ImportId, CreatedAt),
    [ets:insert(?TABLE, {{maps:get(kind, Record), maps:get(id, Record)}, Record})
     || Record <- Records],
    ImportId.

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

clear() ->
    ensure(),
    ets:delete_all_objects(?TABLE),
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
               created_at => maps:get(created_at, Relationship, CreatedAt)},
    ets:insert(?TABLE, {{relationship, Id}, Stored}),
    Stored.

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
               private_key_stored => false,
               certificate_body_stored => false},
    ets:insert(?TABLE, {{cmp_enrollment_result, Id}, Stored}),
    Id.

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
                tunnel_device => maps:get(tunnel_device, Device, not_found)},
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
    Stored = Object#{id => Id,
                     kind => Kind,
                     source => maps:get(source, Object, ovpn_demo_import),
                     import_id => ImportId,
                     created_at => maps:get(created_at, Object, CreatedAt)},
    ets:insert(?TABLE, {{Kind, Id}, Stored}),
    Stored.

list(Kind) ->
    [Object || Object <- all(), maps:get(kind, Object, undefined) =:= Kind].

objects() ->
    Stored = [Object || {_Key, Object} <- ets:tab2list(?TABLE)],
    StoredIds = [maps:get(id, Object, undefined) || Object <- Stored],
    SeedObjects = ias_security_profile:policies() ++ ias_security_profile:profiles(),
    Seeded = [Object || Object <- SeedObjects,
                        not lists:member(maps:get(id, Object, undefined), StoredIds)],
    Stored ++ Seeded.

compare_records(A, B) ->
    {maps:get(import_id, A, undefined),
     kind_order(maps:get(kind, A, undefined)),
     maps:get(id, A, undefined)}
        =< {maps:get(import_id, B, undefined),
            kind_order(maps:get(kind, B, undefined)),
            maps:get(id, B, undefined)}.

kind_order(device) -> 1;
kind_order(certificate) -> 2;
kind_order(vpn_service) -> 3;
kind_order(security_profile) -> 4;
kind_order(security_policy) -> 5;
kind_order(relationship) -> 6;
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
