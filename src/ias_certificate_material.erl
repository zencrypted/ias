-module(ias_certificate_material).
-export([put/4, get/1, status/1, delete/1, clear/0,
         stage_cmp/2, attach_staged/2]).

-define(TABLE, ias_certificate_material).
-define(OWNER, ias_certificate_material_owner).

put(CertificateId, MaterialType, Pem, Source) ->
    ensure_table(),
    Id = ias_html:text(CertificateId),
    case ias_demo_store:get(Id) of
        {ok, #{kind := certificate}} -> put_existing(Id, MaterialType, Pem, Source);
        _ -> {error, certificate_not_found}
    end.

put_existing(Id, MaterialType, Pem, Source) ->
    case validate(MaterialType, Pem) of
        {ok, NormalizedPem, Der} ->
            Record = #{certificate_id => Id,
                       material_type => MaterialType,
                       encoding => pem,
                       source => Source,
                       stored_at => created_at(),
                       fingerprint_sha256 => fingerprint(Der),
                       body => NormalizedPem},
            true = ets:insert(?TABLE, {Id, Record}),
            {ok, public_status(Record)};
        {error, Reason} ->
            {error, Reason}
    end.


stage_cmp(EnrollmentId, Pem) ->
    ensure_table(),
    case validate(client_certificate, Pem) of
        {ok, NormalizedPem, Der} ->
            Id = ias_html:text(EnrollmentId),
            Record = #{enrollment_id => Id,
                       material_type => client_certificate,
                       encoding => pem,
                       source => cmp_response,
                       stored_at => created_at(),
                       fingerprint_sha256 => fingerprint(Der),
                       body => NormalizedPem},
            true = ets:insert(?TABLE, {{staged_cmp, Id}, Record}),
            {ok, public_status(Record)};
        {error, Reason} -> {error, Reason}
    end.

attach_staged(EnrollmentId, CertificateId) ->
    ensure_table(),
    EnrollmentKey = ias_html:text(EnrollmentId),
    case ets:lookup(?TABLE, {staged_cmp, EnrollmentKey}) of
        [{_, Record}] ->
            Result = put(CertificateId, client_certificate,
                         maps:get(body, Record), cmp_response),
            case Result of
                {ok, _} -> ets:delete(?TABLE, {staged_cmp, EnrollmentKey});
                _ -> ok
            end,
            Result;
        [] -> not_found
    end.

get(CertificateId) ->
    ensure_table(),
    case ets:lookup(?TABLE, ias_html:text(CertificateId)) of
        [{_, Record}] -> {ok, Record};
        [] -> not_found
    end.

status(CertificateId) ->
    case get(CertificateId) of
        {ok, Record} -> {ok, public_status(Record)};
        not_found -> not_found
    end.

delete(CertificateId) ->
    ensure_table(),
    ets:delete(?TABLE, ias_html:text(CertificateId)),
    ok.

clear() ->
    ensure_table(),
    ets:delete_all_objects(?TABLE),
    ok.

validate(MaterialType, Pem0) when MaterialType =:= ca_certificate;
                                  MaterialType =:= client_certificate ->
    Pem = trim(ias_html:text(Pem0)),
    case contains_private_material(Pem) of
        true -> {error, private_key_material_rejected};
        false -> decode_single_certificate(Pem)
    end;
validate(_, _) ->
    {error, unsupported_material_type}.

decode_single_certificate(<<>>) ->
    {error, empty_pem};
decode_single_certificate(Pem) ->
    try public_key:pem_decode(Pem) of
        [{'Certificate', Der, not_encrypted}] -> {ok, ensure_newline(Pem), Der};
        [{'Certificate', Der, _}] -> {ok, ensure_newline(Pem), Der};
        [] -> {error, invalid_certificate_pem};
        _ -> {error, exactly_one_certificate_required}
    catch
        _:_ -> {error, invalid_certificate_pem}
    end.

contains_private_material(Pem) ->
    Markers = [<<"BEGIN PRIVATE KEY">>, <<"BEGIN RSA PRIVATE KEY">>,
               <<"BEGIN EC PRIVATE KEY">>, <<"BEGIN ENCRYPTED PRIVATE KEY">>],
    lists:any(fun(Marker) -> binary:match(Pem, Marker) =/= nomatch end, Markers).

public_status(Record) ->
    maps:without([body], Record).

fingerprint(Der) ->
    Hash = crypto:hash(sha256, Der),
    ias_html:text(string:uppercase(binary_to_list(binary:encode_hex(Hash)))).

trim(Bin) ->
    ias_html:text(string:trim(binary_to_list(Bin))).

ensure_newline(<<>>) -> <<>>;
ensure_newline(Pem) ->
    case binary:last(Pem) of
        $\n -> Pem;
        _ -> <<Pem/binary, "\n">>
    end.

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ensure_owner(),
            wait_table(20);
        _ -> ok
    end.

ensure_owner() ->
    case whereis(?OWNER) of
        undefined -> spawn(fun table_owner/0), ok;
        _ -> ok
    end.

wait_table(0) ->
    case ets:info(?TABLE) of
        undefined -> error({certificate_material_store_unavailable, ?TABLE});
        _ -> ok
    end;
wait_table(Attempts) ->
    case ets:info(?TABLE) of
        undefined -> timer:sleep(5), wait_table(Attempts - 1);
        _ -> ok
    end.

table_owner() ->
    case catch register(?OWNER, self()) of
        true ->
            case ets:info(?TABLE) of
                undefined -> ets:new(?TABLE, [named_table, public, set,
                                              {read_concurrency, true}]);
                _ -> ok
            end,
            table_owner_loop();
        _ -> ok
    end.

table_owner_loop() ->
    receive
        stop -> ok;
        _ -> table_owner_loop()
    end.

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
