-module(ias_policy).
-export([ca_signing_preview/1, certificate_claims/1, certificate_request/2,
         evaluate_service/2, evaluate_vpn/1, format_claims/1,
         validate_certificate_request/2]).

evaluate_service(Profile, Service) when is_map(Profile) ->
    Claims = certificate_claims(Profile),
    case lists:member(Service, maps:get(services, Claims, [])) of
        true ->
            #{authorized => true,
              decision => allow,
              reason => <<"profile allows service">>};
        false ->
            #{authorized => false,
              decision => deny,
              reason => <<"service not permitted">>}
    end;
evaluate_service(_Profile, _Service) ->
    #{authorized => false,
      decision => deny,
      reason => <<"service not permitted">>}.

evaluate_vpn(Profile) when is_map(Profile) ->
    case evaluate_service(Profile, vpn) of
        #{authorized := true} ->
            #{authorized => true,
              decision => allow,
              reason => <<"profile allows vpn">>};
        _ ->
            #{authorized => false,
              decision => deny,
              reason => <<"vpn not permitted by profile">>}
    end;
evaluate_vpn(_Profile) ->
    #{authorized => false,
      decision => deny,
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

certificate_request(Profile, SubjectCN) ->
    Claims = certificate_claims(Profile),
    #{subject_cn => ias_html:text(SubjectCN),
      profile_id => profile_id(Profile),
      requested_role => maps:get(role, Claims, undefined),
      requested_services => maps:get(services, Claims, []),
      requested_attributes => maps:get(attributes, Claims, []),
      requested_trust_level => maps:get(trust_level, Claims, undefined)}.

validate_certificate_request(Request, Profile) when is_map(Request), is_map(Profile) ->
    Claims = certificate_claims(Profile),
    [validation(profile_exists, true, <<"profile found">>),
     validation(subject_cn_present, subject_present(maps:get(subject_cn, Request, <<>>)),
                <<"subject is set">>, <<"subject is required">>),
     validation(requested_services_allowed,
                maps:get(requested_services, Request, []) =:= maps:get(services, Claims, []),
                <<"request matches profile services">>, <<"request services differ from profile">>),
     validation(requested_attributes_allowed,
                maps:get(requested_attributes, Request, []) =:= maps:get(attributes, Claims, []),
                <<"request matches profile attributes">>, <<"request attributes differ from profile">>),
     validation(certificate_role_allowed,
                maps:get(requested_role, Request, undefined) =:= maps:get(role, Claims, undefined),
                <<"request matches profile role">>, <<"request role differs from profile">>)];
validate_certificate_request(_Request, _Profile) ->
    [validation(profile_exists, false, <<"profile not found">>)].

ca_signing_preview(Validation) when is_list(Validation) ->
    case lists:all(fun(#{result := Result}) -> Result end, Validation) of
        true ->
            #{ca => <<"Zencrypted Dev CA">>,
              decision => <<"would sign">>,
              reason => <<"request matches selected profile">>};
        false ->
            #{ca => <<"Zencrypted Dev CA">>,
              decision => <<"would reject">>,
              reason => <<"validation failed">>}
    end;
ca_signing_preview(_Validation) ->
    ca_signing_preview([]).

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

profile_id(Profile) when is_map(Profile) ->
    maps:get(id, Profile, undefined);
profile_id(_Profile) ->
    undefined.

subject_present(SubjectCN) ->
    ias_html:text(string:trim(binary_to_list(ias_html:text(SubjectCN)))) =/= <<>>.

validation(Check, true, Reason) ->
    validation(Check, true, Reason, Reason);
validation(Check, false, Reason) ->
    validation(Check, false, Reason, Reason).

validation(Check, Result, PassReason, FailReason) ->
    Reason = case Result of
        true -> PassReason;
        false -> FailReason
    end,
    #{check => Check,
      result => Result,
      reason => Reason}.
