-module(ias_policy).
-export([evaluate_vpn/1]).

evaluate_vpn(Profile) when is_map(Profile) ->
    case lists:member(vpn, maps:get(services, Profile, [])) of
        true ->
            #{authorized => true,
              reason => <<"profile allows vpn">>};
        false ->
            #{authorized => false,
              reason => <<"vpn not permitted by profile">>}
    end;
evaluate_vpn(_Profile) ->
    #{authorized => false,
      reason => <<"vpn not permitted by profile">>}.
