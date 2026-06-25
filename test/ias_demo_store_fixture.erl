-module(ias_demo_store_fixture).

-export([put_runtime_object/1,
         add_relationship/1]).

%% Test-only escape hatch for deliberately malformed or secret-bearing ETS
%% fixtures. Production flows must always use ias_demo_store so the durable
%% KVS boundary validates and commits the object before it becomes visible.
put_runtime_object(#{kind := Kind, id := Id} = Object) ->
    ok = ias_demo_store:ensure(),
    Key = {Kind, normalize_id(Id)},
    true = ets:insert(ias_demo_store, {Key, Object}),
    Object.

add_relationship(Relationship) when is_map(Relationship) ->
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

normalize_id(Id) when is_binary(Id) ->
    Id;
normalize_id(Id) when is_list(Id) ->
    unicode:characters_to_binary(Id);
normalize_id(Id) when is_atom(Id) ->
    atom_to_binary(Id, utf8);
normalize_id(Id) ->
    ias_html:text(Id).

relationship_id() ->
    ias_html:join([<<"relationship_fixture_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
