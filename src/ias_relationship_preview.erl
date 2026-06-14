-module(ias_relationship_preview).
-export([preview/1]).

preview(#{kind := device} = Object) ->
    #{kind => device,
      related_certificate => not_linked,
      related_vpn_service => not_linked,
      suggested_certificates => candidate_certificates(Object),
      suggested_services => candidate_services(Object)};
preview(#{kind := certificate} = Object) ->
    #{kind => certificate,
      used_by_device => not_linked,
      suggested_devices => candidate_devices(Object)};
preview(#{kind := vpn_service} = Object) ->
    #{kind => vpn_service,
      used_by_device => not_linked,
      suggested_devices => candidate_devices(Object)};
preview(_Object) ->
    #{kind => unknown}.

candidate_certificates(Object) ->
    candidates(Object, ias_demo_store:certificates()).

candidate_services(Object) ->
    candidates(Object, ias_demo_store:services()).

candidate_devices(Object) ->
    candidates(Object, ias_demo_store:devices()).

candidates(Object, Objects) ->
    Scored = [Candidate#{relationship_score => score(Object, Candidate)}
              || Candidate <- Objects, not same_id(Object, Candidate)],
    lists:sort(fun compare_candidates/2, Scored).

compare_candidates(A, B) ->
    ScoreA = maps:get(relationship_score, A, 0),
    ScoreB = maps:get(relationship_score, B, 0),
    case ScoreA =:= ScoreB of
        true -> maps:get(id, A, undefined) =< maps:get(id, B, undefined);
        false -> ScoreA > ScoreB
    end.

score(#{kind := device} = Device, #{kind := certificate} = Certificate) ->
    device_certificate_score(Device, Certificate);
score(#{kind := certificate} = Certificate, #{kind := device} = Device) ->
    device_certificate_score(Device, Certificate);
score(#{kind := device} = Device, #{kind := vpn_service} = Service) ->
    device_service_score(Device, Service);
score(#{kind := vpn_service} = Service, #{kind := device} = Device) ->
    device_service_score(Device, Service);
score(Object, Candidate) ->
    flow_score(Object, Candidate).

device_certificate_score(Device, Certificate) ->
    DeviceNames = device_names(Device),
    CommonNames = values(Device, [common_name]),
    DeviceNameValues = values(Device, [device_name]),
    RequestedCN = text_value(maps:get(requested_cn, Certificate, undefined)),
    EnrollmentCN = text_value(maps:get(enrollment_cn, Certificate, undefined)),
    SubjectCN = subject_cn(Certificate),
    SemanticScore = max_score([
        exact_score(CommonNames, RequestedCN, 100),
        exact_score(DeviceNameValues, RequestedCN, 80),
        prefix_score(DeviceNames, EnrollmentCN, 50),
        prefix_score(DeviceNames, SubjectCN, 50)
    ]),
    SemanticScore + flow_score(Device, Certificate).

device_service_score(Device, Service) ->
    DeviceHosts = device_hosts(Device),
    ServiceHosts = service_hosts(Service),
    exact_any_score(DeviceHosts, ServiceHosts, 80) + flow_score(Device, Service).

flow_score(Object, Candidate) ->
    same_import_score(Object, Candidate) + same_source_score(Object, Candidate).

same_import_score(Object, Candidate) ->
    case {maps:get(import_id, Object, undefined),
          maps:get(import_id, Candidate, undefined)} of
        {undefined, _} -> 0;
        {_, undefined} -> 0;
        {ImportId, ImportId} -> 20;
        _ -> 0
    end.

same_source_score(Object, Candidate) ->
    case {maps:get(source, Object, undefined),
          maps:get(source, Candidate, undefined)} of
        {undefined, _} -> 0;
        {_, undefined} -> 0;
        {Source, Source} -> 10;
        _ -> 0
    end.

device_names(Device) ->
    values(Device, [common_name, device_name, hostname, imported_ovpn_device_name,
                    name, id]).

device_hosts(Device) ->
    values(Device, [remote_host, hostname, device_name, common_name, service_name]) ++
        endpoint_hosts(values(Device, [endpoint])).

service_hosts(Service) ->
    values(Service, [remote_host, service_name]) ++
        endpoint_hosts(values(Service, [remote])).

values(Object, Keys) ->
    [Text || Key <- Keys,
             Text <- [text_value(maps:get(Key, Object, undefined))],
             usable(Text)].

endpoint_hosts(Values) ->
    [Host || Value <- Values,
             Host <- [hd(binary:split(Value, <<":">>))],
             usable(Host)].

subject_cn(Certificate) ->
    Subject = text_value(maps:get(subject, Certificate, undefined)),
    case Subject of
        <<"CN=", CN/binary>> -> CN;
        _ -> Subject
    end.

exact_score(_Values, Value, _Score) when not is_binary(Value) ->
    0;
exact_score(Values, Value, Score) ->
    case lists:member(Value, Values) of
        true -> Score;
        false -> 0
    end.

exact_any_score(ValuesA, ValuesB, Score) ->
    case [Value || Value <- ValuesA, lists:member(Value, ValuesB)] of
        [] -> 0;
        _ -> Score
    end.

prefix_score(_Values, Value, _Score) when not is_binary(Value) ->
    0;
prefix_score(Values, Value, Score) ->
    case [Candidate || Candidate <- Values, starts_with(Value, Candidate)] of
        [] -> 0;
        _ -> Score
    end.

starts_with(Value, Prefix) when byte_size(Prefix) =< byte_size(Value) ->
    binary:part(Value, 0, byte_size(Prefix)) =:= Prefix;
starts_with(_Value, _Prefix) ->
    false.

max_score([]) ->
    0;
max_score(Scores) ->
    lists:max(Scores).

text_value(undefined) ->
    undefined;
text_value(not_found) ->
    undefined;
text_value(Value) ->
    Text = ias_html:text(Value),
    case Text of
        <<>> -> undefined;
        <<"-">> -> undefined;
        _ -> Text
    end.

usable(Value) when is_binary(Value) ->
    Value =/= <<>> andalso Value =/= <<"-">>;
usable(_Value) ->
    false.

same_id(A, B) ->
    maps:get(id, A, undefined) =:= maps:get(id, B, undefined).
