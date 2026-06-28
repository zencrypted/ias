-module(ias_user_detail).
-export([issued_certificates/1]).

issued_certificates(#{kind := user} = User) ->
    Relationships = ias_relationship_link:relationships_for(User),
    [Certificate || Relationship <- Relationships,
                    maps:get(relation_type, Relationship, undefined) =:= issued_certificate,
                    maps:get(target_kind, Relationship, undefined) =:= certificate,
                    {ok, Certificate} <- [ias_demo_store:get(maps:get(target_id, Relationship, undefined))]];
issued_certificates(_User) ->
    [].
