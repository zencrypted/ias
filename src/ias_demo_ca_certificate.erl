-module(ias_demo_ca_certificate).
-export([register/1]).

register(Fields) when is_map(Fields) ->
    Name = trim(maps:get(name, Fields, <<>>)),
    Subject = trim(maps:get(subject, Fields, <<>>)),
    Pem = ias_html:text(maps:get(pem, Fields, <<>>)),
    case validate_fields(Name, Subject, Pem) of
        ok ->
            register_valid(Name, Subject, Pem);
        {error, Reason} ->
            {error, Reason}
    end.

validate_fields(<<>>, _Subject, _Pem) ->
    {error, <<"Name is required">>};
validate_fields(_Name, <<>>, _Pem) ->
    {error, <<"Subject is required">>};
validate_fields(_Name, _Subject, <<>>) ->
    {error, <<"Certificate PEM is required">>};
validate_fields(_Name, _Subject, Pem) ->
    case ias_certificate_material:validate_public(ca_certificate, Pem) of
        {ok, NormalizedPem} ->
            case ias_x509_validation:validate_certificate(ca_certificate, NormalizedPem) of
                {ok, _Metadata} -> ok;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

register_valid(Name, Subject, Pem) ->
    case ias_certificate_material:validate_public(ca_certificate, Pem) of
        {ok, NormalizedPem} ->
            case ias_x509_validation:validate_certificate(ca_certificate, NormalizedPem) of
                {ok, _Metadata} ->
                    Certificate = certificate_object(Name, Subject),
                    Stored = ias_demo_store:put_runtime_object(Certificate),
                    case ias_certificate_material:put(maps:get(id, Stored), ca_certificate,
                                                      NormalizedPem, operator_load) of
                        {ok, _Status} ->
                            {ok, Stored};
                        {error, Reason} ->
                            ok = ias_demo_store:delete_runtime_object(certificate,
                                                                      maps:get(id, Stored)),
                            {error, material_store_error(Reason)}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

certificate_object(Name, Subject) ->
    Id = certificate_id(),
    #{id => Id,
      kind => certificate,
      source => ca_certificate,
      material_type => ca_certificate,
      certificate_role => ca_certificate,
      certificate_status => trusted,
      name => Name,
      subject => Subject,
      created_at => created_at(),
      private_key_stored => false,
      certificate_body_stored => false}.

certificate_id() ->
    ias_html:join([<<"manual_ca_certificate_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

material_store_error(Reason) ->
    ias_html:join([<<"material store failure: ">>, ias_html:text(Reason)]).

trim(Value) ->
    re:replace(ias_html:text(Value), <<"^\\s+|\\s+$">>, <<>>,
               [global, {return, binary}]).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
