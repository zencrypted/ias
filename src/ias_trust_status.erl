-module(ias_trust_status).
-export([effective_certificate_status/1,
         effective_device_status/1]).

effective_certificate_status(CertificateId) ->
    case ias_demo_store:get(CertificateId) of
        {ok, #{kind := certificate} = Certificate} ->
            certificate_status(Certificate);
        _ ->
            #{id => ias_html:text(CertificateId),
              kind => certificate,
              trust => unknown,
              reasons => [<<"certificate not found">>]}
    end.

effective_device_status(DeviceId) ->
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} ->
            device_status(Device);
        _ ->
            #{id => ias_html:text(DeviceId),
              kind => device,
              status => incomplete,
              reasons => [<<"device not found">>]}
    end.

certificate_status(Certificate) ->
    Reasons = certificate_reasons(Certificate),
    #{id => maps:get(id, Certificate, undefined),
      kind => certificate,
      trust => certificate_trust(Reasons),
      reasons => Reasons}.

certificate_reasons(Certificate) ->
    ReasonGroups = [
        certificate_revocation_reasons(Certificate),
        certificate_validity_reasons(Certificate),
        certificate_verification_reasons(Certificate),
        certificate_policy_reasons(Certificate),
        certificate_binding_reasons(Certificate)
    ],
    lists:append(ReasonGroups).

certificate_trust(Reasons) ->
    case has_reason_class(blocked, Reasons) of
        true -> blocked;
        false ->
            case has_reason_class(unknown, Reasons) of
                true -> unknown;
                false ->
                    case has_reason_class(degraded, Reasons) of
                        true -> degraded;
                        false -> trusted
                    end
            end
    end.

certificate_revocation_reasons(Certificate) ->
    case ias_certificate_revocation:revoked(Certificate) of
        true -> [reason(blocked, <<"certificate revoked">>)];
        false -> []
    end.

certificate_validity_reasons(Certificate) ->
    case validity_status(Certificate) of
        valid -> [];
        unavailable -> [];
        not_yet_valid -> [reason(blocked, <<"certificate not yet valid">>)];
        expired -> [reason(blocked, <<"certificate expired">>)]
    end.

certificate_verification_reasons(Certificate) ->
    History = ias_certificate_verification:verification_history(Certificate),
    case successful_verification(History) of
        true ->
            [];
        false ->
            case failed_verification(History) of
                true -> [reason(blocked, <<"certificate verification failed">>)];
                false -> [reason(unknown, <<"certificate not verified">>)]
            end
    end.

certificate_policy_reasons(Certificate) ->
    case active_security_policy(Certificate) of
        not_found -> [reason(degraded, <<"no security policy">>)];
        _PolicyId -> []
    end.

certificate_binding_reasons(Certificate) ->
    case bound_device(Certificate) of
        not_found -> [reason(degraded, <<"no device binding">>)];
        _DeviceId -> []
    end.

device_status(Device) ->
    Readiness = device_readiness(Device),
    CertificateId = maps:get(current_certificate_id, Readiness, not_found),
    CertificateStatus = certificate_status_for_device(CertificateId),
    Reasons = device_reasons(Readiness, CertificateStatus),
    #{id => maps:get(id, Device, undefined),
      kind => device,
      status => device_effective_status(Reasons),
      reasons => Reasons,
      certificate_status => maps:get(trust, CertificateStatus, unknown),
      current_certificate_id => CertificateId}.

device_readiness(Device) ->
    DeviceId = maps:get(id, Device, undefined),
    case [Readiness || Readiness <- maps:get(all,
                                             ias_graph_analysis:devices_operational_readiness(),
                                             []),
                       maps:get(device_id, Readiness, undefined) =:= DeviceId] of
        [Readiness | _] -> Readiness;
        [] -> #{status => incomplete,
                missing => [<<"Current Certificate">>],
                current_certificate_id => not_found,
                policy_match => false}
    end.

certificate_status_for_device(not_found) ->
    #{trust => unknown,
      reasons => [reason(unknown, <<"certificate not found">>)]};
certificate_status_for_device(CertificateId) ->
    effective_certificate_status(CertificateId).

device_reasons(Readiness, CertificateStatus) ->
    MissingReasons = [device_missing_reason(Item)
                      || Item <- maps:get(missing, Readiness, [])],
    CertificateReasons = device_certificate_reasons(CertificateStatus),
    PolicyReasons = policy_consistency_reasons(Readiness),
    unique_reasons(MissingReasons ++ CertificateReasons ++ PolicyReasons).

device_missing_reason(<<"VPN Service">>) ->
    reason(incomplete, <<"no vpn service">>);
device_missing_reason(<<"Security Policy">>) ->
    reason(incomplete, <<"no security policy">>);
device_missing_reason(<<"Current Certificate">>) ->
    reason(incomplete, <<"no current certificate">>);
device_missing_reason(<<"Certificate Security Policy">>) ->
    reason(incomplete, <<"no certificate security policy">>);
device_missing_reason(<<"Verified Certificate">>) ->
    reason(incomplete, <<"current certificate not verified">>);
device_missing_reason(<<"Current Certificate Revoked">>) ->
    reason(blocked, <<"current certificate revoked">>);
device_missing_reason(<<"Policy Match">>) ->
    reason(degraded, <<"policy mismatch">>);
device_missing_reason(Item) ->
    reason(incomplete, ias_html:text(Item)).

device_certificate_reasons(#{trust := blocked, reasons := Reasons}) ->
    [reason(blocked, device_certificate_reason_text(maps:get(text, Reason, <<"certificate blocked">>)))
     || Reason <- Reasons,
        maps:get(class, Reason, undefined) =:= blocked];
device_certificate_reasons(_CertificateStatus) ->
    [].

device_certificate_reason_text(<<"certificate revoked">>) ->
    <<"current certificate revoked">>;
device_certificate_reason_text(<<"certificate expired">>) ->
    <<"current certificate expired">>;
device_certificate_reason_text(<<"certificate not yet valid">>) ->
    <<"current certificate not yet valid">>;
device_certificate_reason_text(<<"certificate verification failed">>) ->
    <<"current certificate verification failed">>;
device_certificate_reason_text(Text) ->
    Text.

policy_consistency_reasons(#{policy_match := false,
                             security_policy_id := DevicePolicy,
                             certificate_security_policy_id := CertificatePolicy})
  when DevicePolicy =/= not_found, CertificatePolicy =/= not_found ->
    [reason(degraded, <<"policy mismatch">>)];
policy_consistency_reasons(_Readiness) ->
    [].

device_effective_status(Reasons) ->
    case has_reason_class(blocked, Reasons) of
        true -> blocked;
        false ->
            case has_reason_class(incomplete, Reasons) of
                true -> incomplete;
                false ->
                    case has_reason_class(degraded, Reasons) of
                        true -> degraded;
                        false -> ready
                    end
            end
    end.

successful_verification(History) ->
    lists:any(fun(Verification) ->
        maps:get(verification_status, Verification, undefined) =:= verified
    end, History).

failed_verification(History) ->
    lists:any(fun(Verification) ->
        maps:get(verification_status, Verification, undefined) =:= failed
    end, History).

active_security_policy(Object) ->
    ObjectId = maps:get(id, Object, undefined),
    ObjectKind = maps:get(kind, Object, undefined),
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_demo_store:relationships(),
             maps:get(relation_type, Relationship, undefined) =:= uses_security_policy,
             maps:get(source_kind, Relationship, undefined) =:= ObjectKind,
             maps:get(source_id, Relationship, undefined) =:= ObjectId,
             maps:get(target_kind, Relationship, undefined) =:= security_policy,
             resolves(maps:get(target_id, Relationship, undefined), security_policy)] of
        [PolicyId | _] -> PolicyId;
        [] -> not_found
    end.

bound_device(Certificate) ->
    CertificateId = maps:get(id, Certificate, undefined),
    case [maps:get(source_id, Relationship, undefined)
          || Relationship <- ias_demo_store:relationships(),
             maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
             maps:get(source_kind, Relationship, undefined) =:= device,
             maps:get(target_kind, Relationship, undefined) =:= certificate,
             maps:get(target_id, Relationship, undefined) =:= CertificateId,
             resolves(maps:get(source_id, Relationship, undefined), device)] of
        [DeviceId | _] -> DeviceId;
        [] ->
            case ias_certificate_role:certificate_role(Certificate) of
                #{used_by_device := #{id := DeviceId}} -> DeviceId;
                _ -> not_found
            end
    end.

validity_status(Certificate) ->
    NotBefore = parse_time(maps:get(not_before, Certificate, undefined)),
    NotAfter = parse_time(maps:get(not_after, Certificate, undefined)),
    Now = erlang:system_time(second),
    case {NotBefore, NotAfter} of
        {unavailable, unavailable} ->
            unavailable;
        {{ok, Before}, _} when Before > Now ->
            not_yet_valid;
        {_, {ok, After}} when After < Now ->
            expired;
        {{ok, _}, {ok, _}} ->
            valid;
        {{ok, _}, unavailable} ->
            valid;
        {unavailable, {ok, _}} ->
            valid
    end.

parse_time(undefined) ->
    unavailable;
parse_time(<<"not found">>) ->
    unavailable;
parse_time(not_found) ->
    unavailable;
parse_time(Value) ->
    Text = ias_html:text(Value),
    case parse_rfc3339(Text) of
        {ok, Seconds} ->
            {ok, Seconds};
        unavailable ->
            parse_openssl_date(Text)
    end.

parse_rfc3339(Text) ->
    try {ok, calendar:rfc3339_to_system_time(binary_to_list(Text),
                                             [{unit, second}])}
    catch
        _:_ -> unavailable
    end.

parse_openssl_date(Text) ->
    Parts = binary:split(Text, <<" ">>, [global, trim_all]),
    case Parts of
        [MonthText, DayText, TimeText, YearText, <<"GMT">>] ->
            openssl_parts_to_time(MonthText, DayText, TimeText, YearText);
        _ ->
            unavailable
    end.

openssl_parts_to_time(MonthText, DayText, TimeText, YearText) ->
    case {month(MonthText), binary_to_integer_safe(DayText),
          time_parts(TimeText), binary_to_integer_safe(YearText)} of
        {Month, Day, {Hour, Minute, Second}, Year}
          when is_integer(Month), is_integer(Day), is_integer(Year) ->
            {ok, calendar:datetime_to_gregorian_seconds({{Year, Month, Day},
                                                         {Hour, Minute, Second}})
                 - gregorian_unix_offset()};
        _ ->
            unavailable
    end.

time_parts(TimeText) ->
    case binary:split(TimeText, <<":">>, [global]) of
        [HourText, MinuteText, SecondText] ->
            case {binary_to_integer_safe(HourText),
                  binary_to_integer_safe(MinuteText),
                  binary_to_integer_safe(SecondText)} of
                {Hour, Minute, Second}
                  when is_integer(Hour), is_integer(Minute), is_integer(Second) ->
                    {Hour, Minute, Second};
                _ ->
                    unavailable
            end;
        _ ->
            unavailable
    end.

month(<<"Jan">>) -> 1;
month(<<"Feb">>) -> 2;
month(<<"Mar">>) -> 3;
month(<<"Apr">>) -> 4;
month(<<"May">>) -> 5;
month(<<"Jun">>) -> 6;
month(<<"Jul">>) -> 7;
month(<<"Aug">>) -> 8;
month(<<"Sep">>) -> 9;
month(<<"Oct">>) -> 10;
month(<<"Nov">>) -> 11;
month(<<"Dec">>) -> 12;
month(_Month) -> unavailable.

binary_to_integer_safe(Text) ->
    try binary_to_integer(Text)
    catch
        _:_ -> unavailable
    end.

gregorian_unix_offset() ->
    calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).

has_reason_class(Class, Reasons) ->
    lists:any(fun(Reason) ->
        maps:get(class, Reason, undefined) =:= Class
    end, Reasons).

reason(Class, Text) ->
    #{class => Class,
      text => ias_html:text(Text)}.

unique_reasons(Reasons) ->
    lists:reverse(element(2, lists:foldl(fun unique_reason/2, {#{}, []}, Reasons))).

unique_reason(Reason, {Seen, Acc}) ->
    Text = maps:get(text, Reason, undefined),
    case maps:is_key(Text, Seen) of
        true -> {Seen, Acc};
        false -> {Seen#{Text => true}, [Reason | Acc]}
    end.

resolves(Id, Kind) ->
    case ias_demo_store:get(Id) of
        {ok, #{kind := Kind}} -> true;
        _ -> false
    end.
