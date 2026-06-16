-module(ias_relationship_graph).
-export([known_relationship_type/1,
         categorized_relationships/0,
         graph_consistency_report/0,
         summary/0,
         tree_edge/1]).

known_relationship_type(uses_security_profile) -> true;
known_relationship_type(issued_certificate) -> true;
known_relationship_type(uses_certificate) -> true;
known_relationship_type(verified_by) -> true;
known_relationship_type(uses_security_policy) -> true;
known_relationship_type(uses_service) -> true;
known_relationship_type(uses_vpn_service) -> true;
known_relationship_type(issues) -> true;
known_relationship_type(replaced_certificate_by) -> true;
known_relationship_type(old_certificate) -> true;
known_relationship_type(new_certificate) -> true;
known_relationship_type(revoked_by) -> true;
known_relationship_type(_RelationType) -> false.

categorized_relationships() ->
    Relationships = ias_demo_store:relationships(),
    #{known => [Relationship || Relationship <- Relationships,
                              known_relationship(Relationship),
                              not broken_relationship(Relationship)],
      unknown => [Relationship || Relationship <- Relationships,
                                not known_relationship(Relationship),
                                not broken_relationship(Relationship)],
      broken => [Relationship || Relationship <- Relationships,
                               broken_relationship(Relationship)]}.

graph_consistency_report() ->
    Categories = categorized_relationships(),
    Broken = maps:get(broken, Categories, []),
    Unknown = maps:get(unknown, Categories, []),
    #{broken_relationships => Broken,
      unknown_relationships => Unknown,
      missing_objects => missing_objects(Broken),
      total_relationships => length(ias_demo_store:relationships())}.

summary() ->
    #{users => length(ias_demo_store:users()),
      devices => length(ias_demo_store:devices()),
      certificates => length(ias_demo_store:certificates()),
      security_profiles => length(ias_demo_store:security_profiles()),
      security_policies => length(ias_demo_store:security_policies()),
      vpn_services => length(ias_demo_store:services()),
      relationships => length(ias_demo_store:relationships()),
      total_relationships => length(ias_demo_store:relationships())}.

tree_edge(Relationship) ->
    #{source => object_label(maps:get(source_id, Relationship, undefined)),
      relation_type => maps:get(relation_type, Relationship, undefined),
      target => object_label(maps:get(target_id, Relationship, undefined))}.

known_relationship(Relationship) ->
    known_relationship_type(maps:get(relation_type, Relationship, undefined)).

broken_relationship(Relationship) ->
    unresolved(maps:get(source_id, Relationship, undefined)) orelse
        unresolved(maps:get(target_id, Relationship, undefined)).

unresolved(Id) ->
    case ias_demo_store:get(Id) of
        {ok, _Object} -> false;
        not_found -> true
    end.

missing_objects(Relationships) ->
    lists:append([missing_objects_for_relationship(Relationship)
                  || Relationship <- Relationships]).

missing_objects_for_relationship(Relationship) ->
    Source = missing_object(source, maps:get(source_kind, Relationship, undefined),
                            maps:get(source_id, Relationship, undefined), Relationship),
    Target = missing_object(target, maps:get(target_kind, Relationship, undefined),
                            maps:get(target_id, Relationship, undefined), Relationship),
    [Object || Object <- [Source, Target], Object =/= resolved].

missing_object(Side, Kind, Id, Relationship) ->
    case ias_demo_store:get(Id) of
        {ok, _Object} ->
            resolved;
        not_found ->
            #{side => Side,
              kind => Kind,
              id => Id,
              relationship_id => maps:get(id, Relationship, undefined),
              relation_type => maps:get(relation_type, Relationship, undefined)}
    end.

object_label(Id) ->
    case ias_demo_store:get(Id) of
        {ok, Object} ->
            ias_html:text(maps:get(name, Object, maps:get(id, Object, Id)));
        not_found ->
            ias_html:text(Id)
    end.
