-module(ias_certificate_detail).
-export([metadata/1, security_policy/1]).

metadata(#{kind := certificate} = Certificate) ->
    #{issued_user_id => maps:get(user, Certificate, undefined),
      issued_user => maps:get(user_name, Certificate, maps:get(user, Certificate, undefined)),
      source_security_profile => source_profile_id(Certificate),
      role => maps:get(role, Certificate, undefined),
      services => maps:get(services, Certificate, []),
      attributes => maps:get(attributes, Certificate, []),
      trust_level => maps:get(trust_level, Certificate, undefined),
      device_lock => maps:get(device_lock, Certificate, undefined),
      two_factor => maps:get(two_factor, Certificate, undefined)};
metadata(_Certificate) ->
    #{}.

security_policy(#{kind := certificate} = Certificate) ->
    case source_profile_policy(Certificate) of
        not_found -> ias_security_profile:applied_policy(Certificate);
        Policy -> Policy
    end;
security_policy(Object) ->
    ias_security_profile:applied_policy(Object).

source_profile_policy(Certificate) ->
    ProfileId = source_profile_id(Certificate),
    case ias_security_profile:profile(ProfileId) of
        {ok, Profile} ->
            #{id => ProfileId,
              profile => ProfileId,
              kind => security_profile_policy,
              source => certificate_issue_demo,
              device_lock => ias_policy:device_lock(Profile),
              two_factor => ias_policy:two_factor(Profile),
              enforcement_mode => preview_only};
        not_found ->
            not_found
    end.

source_profile_id(Certificate) ->
    maps:get(profile_id, Certificate, maps:get(profile, Certificate, undefined)).
