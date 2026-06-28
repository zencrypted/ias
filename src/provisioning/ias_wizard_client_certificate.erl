-module(ias_wizard_client_certificate).
-export([issue/1]).

issue(Fields) when is_map(Fields) ->
    UserId = normalize_id(maps:get(user_id, Fields, <<>>)),
    SubjectCN = trim(maps:get(subject_cn, Fields, <<>>)),
    Pem = ias_html:text(maps:get(pem, Fields, <<>>)),
    case validate(UserId, SubjectCN, Pem) of
        {ok, NormalizedPem} -> issue_valid(UserId, SubjectCN, NormalizedPem);
        {error, Reason} -> {error, Reason}
    end.

validate(<<>>, _SubjectCN, _Pem) -> {error, <<"User is required">>};
validate(_UserId, <<>>, _Pem) -> {error, <<"Subject CN is required">>};
validate(_UserId, _SubjectCN, <<>>) -> {error, <<"Certificate PEM is required">>};
validate(UserId, _SubjectCN, Pem) ->
    case ias_demo_store:get(UserId) of
        {ok, #{kind := user}} -> ias_certificate_material:validate_public(client_certificate, Pem);
        _ -> {error, <<"Selected User does not exist">>}
    end.

issue_valid(UserId, SubjectCN, NormalizedPem) ->
    case ias_certificate_issue_demo:issue(UserId, SubjectCN, ias_demo_data:profiles()) of
        {ok, Certificate} ->
            CertificateId = maps:get(id, Certificate),
            case ias_certificate_material:put(CertificateId, client_certificate,
                                              NormalizedPem, operator_load) of
                {ok, _Status} -> {ok, Certificate};
                {error, Reason} ->
                    rollback(CertificateId),
                    {error, ias_html:join([<<"material store failure: ">>, ias_html:text(Reason)])}
            end;
        {error, Reason} -> {error, Reason}
    end.

rollback(CertificateId) ->
    [ias_demo_store:delete_relationship(maps:get(id, Relationship))
     || Relationship <- ias_demo_store:relationships(),
        maps:get(source_id, Relationship, undefined) =:= CertificateId orelse
        maps:get(target_id, Relationship, undefined) =:= CertificateId],
    ias_demo_store:delete_runtime_object(certificate, CertificateId).

normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) -> ias_html:text(Id).

trim(Value) ->
    re:replace(ias_html:text(Value), <<"^\\s+|\\s+$">>, <<>>,
               [global, {return, binary}]).
