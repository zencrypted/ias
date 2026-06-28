-module(ias_configured_ca_trust_anchor).
-export([status/0, load/0, resolve_path/2]).

status() ->
    case configured_file() of
        undefined ->
            #{configured => false,
              display_path => <<"not configured">>};
        File ->
            #{configured => true,
              display_path => display_path(File)}
    end.

load() ->
    case configured_file() of
        undefined ->
            {error, not_configured};
        File ->
            Base = configured_base_dir(),
            case resolve_path(File, Base) of
                {ok, Path} -> load_path(Path);
                {error, Reason} -> {error, Reason}
            end
    end.

resolve_path(File0, Base0) ->
    File = trim(File0),
    Base = trim(Base0),
    case File of
        <<>> ->
            {error, not_configured};
        _ ->
            FileList = binary_to_list(File),
            case filename:pathtype(FileList) of
                absolute ->
                    {ok, normalize_path(FileList)};
                _ ->
                    case resolve_base(Base) of
                        {ok, BasePath} ->
                            {ok, normalize_path(filename:join(BasePath, FileList))};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
    end.

load_path(Path) ->
    case file:read_file(Path) of
        {ok, Pem} ->
            register_pem(Pem);
        {error, enoent} ->
            {error, file_not_found};
        {error, eacces} ->
            {error, permission_denied};
        {error, Reason} ->
            {error, {read_failed, Reason}}
    end.

register_pem(Pem) ->
    case ias_certificate_material:validate_public(ca_certificate, Pem) of
        {ok, NormalizedPem} ->
            case ias_x509_validation:validate_certificate(ca_certificate, NormalizedPem) of
                {ok, Metadata} ->
                    store_certificate(NormalizedPem, Metadata);
                {error, Reason} ->
                    {error, validation_reason(Reason)}
            end;
        {error, Reason} ->
            {error, material_reason(Reason)}
    end.

store_certificate(Pem, Metadata) ->
    Id = certificate_id(maps:get(fingerprint_sha256, Metadata)),
    ExistingCreatedAt = case ias_demo_store:get(Id) of
        {ok, Existing} -> maps:get(created_at, Existing, created_at());
        not_found -> created_at()
    end,
    Certificate = certificate_object(Id, Metadata, ExistingCreatedAt),
    Stored = ias_demo_store:put_runtime_object(Certificate),
    case ias_certificate_material:put(Id, ca_certificate, Pem, ca_configuration) of
        {ok, _Status} ->
            {ok, Stored};
        {error, Reason} ->
            ok = ias_demo_store:delete_runtime_object(certificate, Id),
            {error, {material_store_failed, Reason}}
    end.

certificate_object(Id, Metadata, CreatedAt) ->
    Subject = maps:get(subject, Metadata, <<"Configured CA Trust Anchor">>),
    #{id => Id,
      kind => certificate,
      source => ca_configuration,
      material_type => ca_certificate,
      certificate_role => ca_certificate,
      certificate_status => trusted,
      name => Subject,
      subject => Subject,
      issuer => maps:get(issuer, Metadata, undefined),
      serial => maps:get(serial, Metadata, undefined),
      not_before => maps:get(not_before, Metadata, undefined),
      not_after => maps:get(not_after, Metadata, undefined),
      fingerprint_sha256 => maps:get(fingerprint_sha256, Metadata, undefined),
      created_at => CreatedAt,
      private_key_stored => false,
      certificate_body_stored => false}.

certificate_id(Fingerprint) ->
    ias_html:join([<<"configured_ca_trust_anchor_">>, ias_html:text(Fingerprint)]).

validation_reason(<<"private key material is not certificate material">>) ->
    private_key_supplied;
validation_reason(<<"CA certificate must have basicConstraints CA=TRUE">>) ->
    certificate_is_not_ca;
validation_reason(<<"certificate has expired">>) ->
    certificate_expired;
validation_reason(<<"invalid certificate PEM">>) ->
    invalid_pem;
validation_reason(<<"invalid X.509 certificate">>) ->
    invalid_pem;
validation_reason(Reason) ->
    Reason.

material_reason(private_key_material_rejected) ->
    private_key_supplied;
material_reason(invalid_certificate_pem) ->
    invalid_pem;
material_reason(exactly_one_certificate_required) ->
    invalid_pem;
material_reason(empty_pem) ->
    invalid_pem;
material_reason(unsupported_material_type) ->
    invalid_pem;
material_reason(Reason) ->
    Reason.

configured_file() ->
    case application:get_env(ias, ca_trust_anchor_file) of
        {ok, Value} -> present_text(Value);
        undefined -> undefined
    end.

configured_base_dir() ->
    case application:get_env(ias, ca_trust_anchor_base_dir) of
        {ok, Value} -> present_text(Value);
        undefined -> <<".">>
    end.

present_text(Value) ->
    case trim(Value) of
        <<>> -> undefined;
        Text -> Text
    end.

resolve_base(undefined) ->
    resolve_base(<<".">>);
resolve_base(<<>>) ->
    resolve_base(<<".">>);
resolve_base(Base) ->
    BaseList = binary_to_list(Base),
    case filename:pathtype(BaseList) of
        absolute ->
            {ok, normalize_path(BaseList)};
        _ ->
            case file:get_cwd() of
                {ok, Cwd} -> {ok, normalize_path(filename:join(Cwd, BaseList))};
                {error, Reason} -> {error, {cwd_failed, Reason}}
            end
    end.

normalize_path(Path) ->
    Parts = filename:split(filename:absname(Path)),
    filename:join(lists:reverse(lists:foldl(fun normalize_part/2, [], Parts))).

normalize_part(".", Acc) ->
    Acc;
normalize_part("..", []) ->
    [];
normalize_part("..", ["/"]) ->
    ["/"];
normalize_part("..", [_Part | Rest]) ->
    Rest;
normalize_part(Part, Acc) ->
    [Part | Acc].

display_path(File) ->
    Text = trim(File),
    case filename:pathtype(binary_to_list(Text)) of
        absolute -> ias_html:text(filename:basename(binary_to_list(Text)));
        _ -> Text
    end.

trim(Value) ->
    ias_html:text(string:trim(binary_to_list(ias_html:text(Value)))).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
