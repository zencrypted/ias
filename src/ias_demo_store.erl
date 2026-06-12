-module(ias_demo_store).
-export([
    add_device/1,
    add_certificate/1,
    add_service/1,
    devices/0,
    certificates/0,
    services/0,
    all/0,
    reset/0
]).

-define(TABLE, ias_demo_store).
-define(OWNER, ias_demo_store_owner).

add_device(Device) when is_map(Device) ->
    add(device, Device).

add_certificate(Certificate) when is_map(Certificate) ->
    add(certificate, Certificate).

add_service(Service) when is_map(Service) ->
    add(service, Service).

devices() ->
    list(device).

certificates() ->
    list(certificate).

services() ->
    list(service).

all() ->
    #{devices => devices(),
      certificates => certificates(),
      services => services()}.

reset() ->
    ensure_table(),
    ets:delete_all_objects(?TABLE),
    ok.

add(Type, Object) ->
    ensure_table(),
    Id = object_id(Type, Object),
    Stored = Object#{id => Id,
                      source => maps:get(source, Object, ovpn_demo_import)},
    ets:insert(?TABLE, {{Type, Id}, Stored}),
    Stored.

list(Type) ->
    ensure_table(),
    Objects = [Object || {{StoredType, _Id}, Object} <- ets:tab2list(?TABLE),
                         StoredType =:= Type],
    lists:sort(fun compare_ids/2, Objects).

compare_ids(A, B) ->
    term_to_binary(maps:get(id, A, undefined)) =< term_to_binary(maps:get(id, B, undefined)).

object_id(Type, Object) ->
    case maps:get(id, Object, undefined) of
        undefined -> generated_id(Type);
        Id -> Id
    end.

generated_id(Type) ->
    Count = erlang:unique_integer([positive, monotonic]),
    list_to_binary(io_lib:format("~s_~p", [atom_to_list(Type), Count])).

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
