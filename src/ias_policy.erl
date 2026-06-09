-module(ias_policy).
-export([certificate_claims/1, evaluate_vpn/1, format_claims/1]).

evaluate_vpn(Profile) when is_map(Profile) ->
    Claims = certificate_claims(Profile),
    case lists:member(vpn, maps:get(services, Claims, [])) of
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

certificate_claims(Profile) when is_map(Profile) ->
    #{role => maps:get(certificate_role, Profile, undefined),
      services => maps:get(services, Profile, []),
      attributes => maps:get(attributes, Profile, []),
      trust_level => maps:get(trust_level, Profile, undefined)};
certificate_claims(_Profile) ->
    #{role => undefined,
      services => [],
      attributes => [],
      trust_level => undefined}.

format_claims(Claims) when is_map(Claims) ->
    ias_html:join(["role=", maps:get(role, Claims, undefined),
                   "; services=", join_claim_values(maps:get(services, Claims, [])),
                   "; attrs=", join_claim_values(maps:get(attributes, Claims, [])),
                   "; trust=", maps:get(trust_level, Claims, undefined)]);
format_claims(_Claims) ->
    format_claims(#{}).

join_claim_values([]) ->
    <<"-">>;
join_claim_values(Values) ->
    join_claim_values(Values, []).

join_claim_values([], Acc) ->
    iolist_to_binary(lists:reverse(Acc));
join_claim_values([Value], Acc) ->
    join_claim_values([], [ias_html:text(Value) | Acc]);
join_claim_values([Value | Rest], Acc) ->
    join_claim_values(Rest, [<<",">>, ias_html:text(Value) | Acc]).
