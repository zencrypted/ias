-module(ias_policy_consistency).
-export([evaluate_policy_consistency/2]).

evaluate_policy_consistency(DeviceId, CertificateId) ->
    DevicePolicy = active_security_policy(DeviceId),
    CertificatePolicy = active_security_policy(CertificateId),
    evaluate(DevicePolicy, CertificatePolicy).

evaluate(not_found, CertificatePolicy) ->
    #{match => false,
      device_policy => not_found,
      certificate_policy => CertificatePolicy,
      reason => <<"no policy available">>};
evaluate(DevicePolicy, not_found) ->
    #{match => false,
      device_policy => DevicePolicy,
      certificate_policy => not_found,
      reason => <<"no policy available">>};
evaluate(Policy, Policy) ->
    #{match => true,
      device_policy => Policy,
      certificate_policy => Policy,
      reason => <<"policies match">>};
evaluate(DevicePolicy, CertificatePolicy) ->
    #{match => false,
      device_policy => DevicePolicy,
      certificate_policy => CertificatePolicy,
      reason => ias_html:join([<<"device requires ">>, DevicePolicy,
                               <<"; certificate provides ">>, CertificatePolicy])}.

active_security_policy(ObjectId) ->
    case ias_demo_store:get(ObjectId) of
        {ok, Object} ->
            active_security_policy_for_object(Object);
        not_found ->
            not_found
    end.

active_security_policy_for_object(Object) ->
    ObjectId = maps:get(id, Object, undefined),
    ObjectKind = maps:get(kind, Object, undefined),
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_demo_store:relationships(),
             maps:get(relation_type, Relationship, undefined) =:= uses_security_policy,
             maps:get(source_kind, Relationship, undefined) =:= ObjectKind,
             maps:get(source_id, Relationship, undefined) =:= ObjectId,
             maps:get(target_kind, Relationship, undefined) =:= security_policy,
             resolves_security_policy(maps:get(target_id, Relationship, undefined))] of
        [PolicyId | _] -> PolicyId;
        [] -> not_found
    end.

resolves_security_policy(PolicyId) ->
    case ias_demo_store:get(PolicyId) of
        {ok, #{kind := security_policy}} -> true;
        _ -> false
    end.
