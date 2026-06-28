-module(ias_authorization_enforcement).
-export([device_enforcement/1,
         certificate_enforcement/1]).

device_enforcement(DeviceId) ->
    enforcement_item(<<"VPN Connection">>,
                     ias_authorization_decision:device_decision(DeviceId, access_vpn)).

certificate_enforcement(CertificateId) ->
    [enforcement_item(Operation,
                      ias_authorization_decision:certificate_decision(CertificateId, Action))
     || {Action, Operation} <- certificate_operations()].

certificate_operations() ->
    [{use_ias, <<"IAS Access">>},
     {issue_certificate, <<"Certificate Issuance">>},
     {revoke_certificate, <<"Certificate Revocation">>}].

enforcement_item(Operation, Decision) ->
    #{operation => Operation,
      action => maps:get(action, Decision, undefined),
      result => maps:get(decision, Decision, deny),
      reason => reason_text(maps:get(reasons, Decision, [])),
      reasons => maps:get(reasons, Decision, [])}.

reason_text([]) ->
    <<"authorization decision allowed">>;
reason_text(Reasons) ->
    ias_html:join(join_reasons(Reasons, [])).

join_reasons([], Acc) ->
    lists:reverse(Acc);
join_reasons([Reason | Rest], []) ->
    join_reasons(Rest, [ias_html:text(Reason)]);
join_reasons([Reason | Rest], Acc) ->
    join_reasons(Rest, [ias_html:text(Reason), <<"; ">> | Acc]).
