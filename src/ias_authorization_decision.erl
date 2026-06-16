-module(ias_authorization_decision).
-export([device_decision/2,
         certificate_decision/2]).

device_decision(DeviceId, Action) ->
    case supported_action(Action) of
        true ->
            device_action_decision(DeviceId, Action);
        false ->
            deny(device, DeviceId, Action, [<<"unsupported action">>])
    end.

certificate_decision(CertificateId, Action) ->
    case supported_action(Action) of
        true ->
            certificate_action_decision(CertificateId, Action);
        false ->
            deny(certificate, CertificateId, Action, [<<"unsupported action">>])
    end.

supported_action(access_vpn) -> true;
supported_action(use_ias) -> true;
supported_action(issue_certificate) -> true;
supported_action(revoke_certificate) -> true;
supported_action(_) -> false.

device_action_decision(DeviceId, access_vpn) ->
    Readiness = device_readiness(DeviceId),
    Effective = ias_trust_status:effective_device_status(DeviceId),
    ReadinessStatus = maps:get(status, Readiness, incomplete),
    EffectiveStatus = maps:get(status, Effective, incomplete),
    case {ReadinessStatus, EffectiveStatus} of
        {ready, ready} ->
            allow(device, DeviceId, access_vpn);
        _ ->
            Reasons = unique_reasons(device_reasons(Readiness, Effective)),
            deny(device, DeviceId, access_vpn, Reasons)
    end;
device_action_decision(DeviceId, Action) ->
    deny(device, DeviceId, Action, [<<"action not supported for device preview">>]).

certificate_action_decision(CertificateId, Action) ->
    Status = ias_trust_status:effective_certificate_status(CertificateId),
    case maps:get(trust, Status, unknown) of
        trusted ->
            allow(certificate, CertificateId, Action);
        _ ->
            Reasons = unique_reasons(certificate_reasons(Status)),
            deny(certificate, CertificateId, Action, Reasons)
    end.

device_readiness(DeviceId) ->
    case [Readiness || Readiness <- maps:get(all,
                                             ias_graph_analysis:devices_operational_readiness(),
                                             []),
                       maps:get(device_id, Readiness, undefined) =:= normalize_id(DeviceId)] of
        [Readiness | _] ->
            Readiness;
        [] ->
            #{status => incomplete,
              missing => [<<"Device">>]}
    end.

device_reasons(Readiness, Effective) ->
    ReadinessReasons = readiness_reasons(Readiness),
    EffectiveReasons = trust_reason_texts(Effective),
    NotReady = case maps:get(status, Readiness, incomplete) of
                   ready -> [];
                   _ -> [<<"device not ready">>]
               end,
    ReadinessReasons ++ EffectiveReasons ++ NotReady.

readiness_reasons(Readiness) ->
    [readiness_reason(Item) || Item <- maps:get(missing, Readiness, [])].

readiness_reason(<<"VPN Service">>) ->
    <<"no vpn service">>;
readiness_reason(<<"Security Policy">>) ->
    <<"no security policy">>;
readiness_reason(<<"Current Certificate">>) ->
    <<"no current certificate">>;
readiness_reason(<<"Certificate Security Policy">>) ->
    <<"no certificate security policy">>;
readiness_reason(<<"Verified Certificate">>) ->
    <<"certificate not verified">>;
readiness_reason(<<"Current Certificate Revoked">>) ->
    <<"current certificate revoked">>;
readiness_reason(<<"Policy Match">>) ->
    <<"policy mismatch">>;
readiness_reason(Item) ->
    ias_html:text(Item).

certificate_reasons(Status) ->
    case trust_reason_texts(Status) of
        [] -> [<<"certificate not trusted">>];
        Reasons -> Reasons
    end.

trust_reason_texts(Status) ->
    [ias_html:text(maps:get(text, Reason, undefined))
     || Reason <- maps:get(reasons, Status, [])].

allow(SubjectKind, SubjectId, Action) ->
    #{subject_kind => SubjectKind,
      subject_id => normalize_id(SubjectId),
      action => Action,
      decision => allow,
      reasons => []}.

deny(SubjectKind, SubjectId, Action, Reasons) ->
    #{subject_kind => SubjectKind,
      subject_id => normalize_id(SubjectId),
      action => Action,
      decision => deny,
      reasons => Reasons}.

normalize_id(Id) ->
    ias_html:text(Id).

unique_reasons(Reasons) ->
    unique_reasons(Reasons, [], []).

unique_reasons([], _Seen, Acc) ->
    lists:reverse(Acc);
unique_reasons([Reason | Rest], Seen, Acc) ->
    Text = ias_html:text(Reason),
    case lists:member(Text, Seen) of
        true -> unique_reasons(Rest, Seen, Acc);
        false -> unique_reasons(Rest, [Text | Seen], [Text | Acc])
    end.
