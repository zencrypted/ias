-module(ias_security_profile).
-export([policies/0,
         policy/1,
         default_policy/0,
         applied_policy/1,
         effects/1,
         profile_label/1,
         device_lock_label/1,
         two_factor_label/1,
         enforcement_label/1]).

policies() ->
    [standard_policy(), high_security_policy()].

policy(Id) ->
    TextId = ias_html:text(Id),
    case [Policy || Policy <- policies(),
                    maps:get(id, Policy, undefined) =:= TextId] of
        [Policy | _] -> {ok, Policy};
        [] -> not_found
    end.

default_policy() ->
    standard_policy().

applied_policy(Object) ->
    case linked_policy(Object) of
        not_found -> default_policy();
        Policy -> Policy
    end.

effects(#{profile := high_security}) ->
    [<<"Device binding expected">>, <<"2FA required">>];
effects(#{profile := <<"High Security">>}) ->
    [<<"Device binding expected">>, <<"2FA required">>];
effects(_Policy) ->
    [<<"Multiple devices allowed">>, <<"2FA optional">>].

profile_label(#{profile := standard}) ->
    <<"Standard">>;
profile_label(#{profile := high_security}) ->
    <<"High Security">>;
profile_label(#{profile := Profile}) ->
    ias_html:text(Profile);
profile_label(_Policy) ->
    <<"Standard">>.

device_lock_label(#{device_lock := enabled}) ->
    <<"Enabled">>;
device_lock_label(#{device_lock := disabled}) ->
    <<"Disabled">>;
device_lock_label(#{device_lock := Value}) ->
    ias_html:text(Value);
device_lock_label(_Policy) ->
    <<"Disabled">>.

two_factor_label(#{two_factor := required}) ->
    <<"Required">>;
two_factor_label(#{two_factor := optional}) ->
    <<"Optional">>;
two_factor_label(#{two_factor := Value}) ->
    ias_html:text(Value);
two_factor_label(_Policy) ->
    <<"Optional">>.

enforcement_label(#{enforcement_mode := preview_only}) ->
    <<"Preview Only">>;
enforcement_label(#{enforcement_mode := Value}) ->
    ias_html:text(Value);
enforcement_label(_Policy) ->
    <<"Preview Only">>.

linked_policy(Object) ->
    ObjectId = maps:get(id, Object, undefined),
    ObjectKind = maps:get(kind, Object, undefined),
    case [Policy || Relationship <- ias_demo_store:relationships(),
                    maps:get(relation_type, Relationship, undefined) =:= uses_security_policy,
                    maps:get(source_kind, Relationship, undefined) =:= ObjectKind,
                    maps:get(source_id, Relationship, undefined) =:= ObjectId,
                    {ok, Policy} <- [ias_demo_store:get(maps:get(target_id, Relationship, undefined))],
                    maps:get(kind, Policy, undefined) =:= security_policy] of
        [Policy | _] -> Policy;
        [] -> not_found
    end.

standard_policy() ->
    #{id => <<"standard">>,
      policy_id => <<"standard">>,
      kind => security_policy,
      source => security_profile_preview,
      profile => standard,
      device_lock => disabled,
      two_factor => optional,
      enforcement_mode => preview_only}.

high_security_policy() ->
    #{id => <<"high_security">>,
      policy_id => <<"high_security">>,
      kind => security_policy,
      source => security_profile_preview,
      profile => high_security,
      device_lock => enabled,
      two_factor => required,
      enforcement_mode => preview_only}.
