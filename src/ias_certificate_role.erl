-module(ias_certificate_role).
-export([origin/1,
         role/1,
         device_status/1,
         certificate_role/1,
         replacement_preview/1]).

origin(#{source := ovpn_demo_import}) ->
    imported;
origin(#{source := cmp_demo_enrollment}) ->
    issued;
origin(#{ca_present := _}) ->
    imported;
origin(#{subject := _, issuer := _}) ->
    issued;
origin(_Certificate) ->
    unknown.

role(Certificate) ->
    case origin(Certificate) of
        imported -> current;
        issued -> candidate;
        _ -> unassigned
    end.

device_status(#{kind := device} = Device) ->
    Current = current_certificate(Device),
    Candidate = candidate_certificate(Device, Current),
    #{current_certificate => Current,
      candidate_certificate => Candidate,
      state => state(Current, Candidate)};
device_status(_Object) ->
    #{current_certificate => not_found,
      candidate_certificate => not_found,
      state => no_certificate_context}.

certificate_role(#{kind := certificate} = Certificate) ->
    #{origin => origin(Certificate),
      role => active_role(Certificate),
      used_by_device => certificate_device(Certificate)};
certificate_role(_Object) ->
    #{origin => unknown,
      role => unassigned,
      used_by_device => not_found}.

replacement_preview(Device) ->
    Status = device_status(Device),
    Current = maps:get(current_certificate, Status, not_found),
    Candidate = maps:get(candidate_certificate, Status, not_found),
    #{current => Current,
      future => Candidate,
      action => replacement_action(Current, Candidate)}.

current_certificate(Device) ->
    Certificates = ias_demo_store:certificates(),
    case latest_replacement_certificate(Device, Certificates) of
        not_found ->
            active_linked_certificate(Device, Certificates);
        Certificate ->
            Certificate
    end.

latest_replacement_certificate(Device, Certificates) ->
    DeviceId = maps:get(id, Device, undefined),
    Replacements = [Replacement
                    || Relationship <- ias_demo_store:relationships(),
                       maps:get(relation_type, Relationship, undefined) =:= replaced_certificate_by,
                       maps:get(source_kind, Relationship, undefined) =:= device,
                       maps:get(source_id, Relationship, undefined) =:= DeviceId,
                       maps:get(target_kind, Relationship, undefined) =:= certificate_replacement,
                       {ok, Replacement} <- [ias_demo_store:get(maps:get(target_id, Relationship, undefined))],
                       maps:get(kind, Replacement, undefined) =:= certificate_replacement,
                       maps:get(status, Replacement, undefined) =:= completed],
    case latest_record(Replacements) of
        not_found ->
            not_found;
        Replacement ->
            certificate_by_id(maps:get(new_certificate_id, Replacement, undefined), Certificates)
    end.

active_linked_certificate(Device, Certificates) ->
    case latest_uses_certificate_relationship(Device) of
        not_found ->
            same_import_current_certificate(Device, Certificates);
        Relationship ->
            certificate_by_id(maps:get(target_id, Relationship, undefined), Certificates)
    end.

latest_uses_certificate_relationship(Device) ->
    DeviceId = maps:get(id, Device, undefined),
    Relationships = [Relationship
                     || Relationship <- ias_demo_store:relationships(),
                        maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
                        maps:get(source_kind, Relationship, undefined) =:= device,
                        maps:get(source_id, Relationship, undefined) =:= DeviceId,
                        maps:get(target_kind, Relationship, undefined) =:= certificate],
    latest_record(Relationships).

latest_record([]) ->
    not_found;
latest_record(Records) ->
    hd(lists:sort(fun newest_record/2, Records)).

newest_record(A, B) ->
    record_sort_key(A) >= record_sort_key(B).

record_sort_key(Record) ->
    {ias_html:text(maps:get(created_at, Record, <<>>)),
     ias_html:text(maps:get(id, Record, <<>>))}.

certificate_by_id(undefined, _Certificates) ->
    not_found;
certificate_by_id(CertificateId, Certificates) ->
    case [Certificate || Certificate <- Certificates,
                         maps:get(id, Certificate, undefined) =:= CertificateId] of
        [Certificate | _] -> Certificate;
        [] -> not_found
    end.

same_import_current_certificate(Device, Certificates) ->
    ImportId = maps:get(import_id, Device, undefined),
    case [Certificate || Certificate <- Certificates,
                         origin(Certificate) =:= imported,
                         maps:get(import_id, Certificate, undefined) =:= ImportId] of
        [Certificate | _] -> Certificate;
        [] -> not_found
    end.

candidate_certificate(Device, Current) ->
    CurrentId = certificate_id(Current),
    Candidates = [Candidate || Candidate <- scored_certificates(Device),
                               maps:get(origin, Candidate, unknown) =:= issued,
                               maps:get(score, Candidate, 0) > 0,
                               maps:get(id, Candidate, undefined) =/= CurrentId],
    case Candidates of
        [#{certificate := Certificate} | _] -> Certificate;
        [] -> not_found
    end.

scored_certificates(Device) ->
    PreviewCandidates = maps:get(suggested_certificates,
                                 ias_relationship_preview:preview(Device),
                                 []),
    PreviewScores = [{maps:get(id, Candidate, undefined),
                      maps:get(relationship_score, Candidate, 0)}
                     || Candidate <- PreviewCandidates],
    Scored = [#{certificate => Certificate,
                id => maps:get(id, Certificate, undefined),
                origin => origin(Certificate),
                score => certificate_score(Device, Certificate, PreviewScores)}
              || Certificate <- ias_demo_store:certificates()],
    lists:sort(fun compare_scored/2, Scored).

certificate_score(Device, Certificate, PreviewScores) ->
    Id = maps:get(id, Certificate, undefined),
    PreviewScore = proplists:get_value(Id, PreviewScores, 0),
    PreviewScore + device_type_score(Device, Certificate).

device_type_score(Device, Certificate) ->
    DeviceTypes = text_values(Device, [type]),
    Requested = text_value(maps:get(requested_cn, Certificate, undefined)),
    Enrollment = text_value(maps:get(enrollment_cn, Certificate, undefined)),
    Subject = subject_cn(Certificate),
    max_score([exact_score(DeviceTypes, Requested, 90),
               prefix_score(DeviceTypes, Enrollment, 60),
               prefix_score(DeviceTypes, Subject, 60)]).

certificate_device(Certificate) ->
    case active_role(Certificate) of
        current -> current_certificate_device(Certificate);
        candidate -> candidate_certificate_device(Certificate);
        _ -> not_found
    end.

active_role(#{kind := certificate} = Certificate) ->
    case current_certificate_device(Certificate) of
        not_found -> role(Certificate);
        _Device -> current
    end;
active_role(Certificate) ->
    role(Certificate).

current_certificate_device(Certificate) ->
    CertificateId = maps:get(id, Certificate, undefined),
    LinkedDevices = [Device || Relationship <- ias_demo_store:relationships(),
                               maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
                               maps:get(target_kind, Relationship, undefined) =:= certificate,
                               maps:get(target_id, Relationship, undefined) =:= CertificateId,
                               {ok, Device} <- [ias_demo_store:get(maps:get(source_id, Relationship, undefined))],
                               maps:get(kind, Device, undefined) =:= device],
    case LinkedDevices of
        [Device | _] ->
            Device;
        [] ->
            same_import_device(Certificate)
    end.

same_import_device(Certificate) ->
    ImportId = maps:get(import_id, Certificate, undefined),
    case [Device || Device <- ias_demo_store:devices(),
                    maps:get(import_id, Device, undefined) =:= ImportId] of
        [Device | _] -> Device;
        [] -> not_found
    end.

candidate_certificate_device(Certificate) ->
    Scored = [#{device => Device,
                score => certificate_score(Device, Certificate, preview_scores(Device))}
              || Device <- ias_demo_store:devices()],
    Candidates = [Candidate || Candidate <- lists:sort(fun compare_device_scores/2, Scored),
                               maps:get(score, Candidate, 0) > 0],
    case Candidates of
        [#{device := Device} | _] -> Device;
        [] -> not_found
    end.

preview_scores(Device) ->
    [{maps:get(id, Candidate, undefined), maps:get(relationship_score, Candidate, 0)}
     || Candidate <- maps:get(suggested_certificates,
                              ias_relationship_preview:preview(Device),
                              [])].

state(not_found, not_found) ->
    no_certificate_available;
state(_Current, not_found) ->
    current_only;
state(not_found, _Candidate) ->
    candidate_available;
state(_Current, _Candidate) ->
    replacement_available.

replacement_action(not_found, _Candidate) ->
    <<"not available">>;
replacement_action(_Current, not_found) ->
    <<"not available">>;
replacement_action(_Current, _Candidate) ->
    <<"replacement possible">>.

compare_scored(A, B) ->
    ScoreA = maps:get(score, A, 0),
    ScoreB = maps:get(score, B, 0),
    case ScoreA =:= ScoreB of
        true -> maps:get(id, A, undefined) =< maps:get(id, B, undefined);
        false -> ScoreA > ScoreB
    end.

compare_device_scores(A, B) ->
    ScoreA = maps:get(score, A, 0),
    ScoreB = maps:get(score, B, 0),
    case ScoreA =:= ScoreB of
        true -> maps:get(id, maps:get(device, A, #{}), undefined) =<
                    maps:get(id, maps:get(device, B, #{}), undefined);
        false -> ScoreA > ScoreB
    end.

certificate_id(not_found) ->
    not_found;
certificate_id(Certificate) ->
    maps:get(id, Certificate, undefined).

text_values(Object, Keys) ->
    [Text || Key <- Keys,
             Text <- [text_value(maps:get(Key, Object, undefined))],
             usable(Text)].

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

usable(Value) when is_binary(Value) ->
    Value =/= <<>> andalso Value =/= <<"-">>;
usable(_Value) ->
    false.
