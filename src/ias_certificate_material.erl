-module(ias_certificate_material).
-compile({no_auto_import, [get/1]}).

-export([ensure/0,
         put/4,
         validate_public/2,
         get/1,
         get/2,
         status/1,
         delete/1,
         clear/0,
         count/0,
         projection_count/0,
         rehydrate/0,
         protection_mode/0,
         stage_cmp/2,
         attach_staged/2]).

-define(TABLE, ias_certificate_material).
-define(OWNER, ias_certificate_material_owner).

ensure() ->
    case ias_certificate_material_store:ensure() of
        ok -> ensure_table();
        {error, _} = Error -> Error
    end.

put(CertificateId, MaterialType, Pem, Source) ->
    ensure_table(),
    Id = ias_html:text(CertificateId),
    case ias_demo_store:get(Id) of
        {ok, #{kind := certificate}} ->
            put_existing(Id, MaterialType, Pem, Source);
        _ ->
            {error, certificate_not_found}
    end.

put_existing(Id, MaterialType, Pem, Source) ->
    case validate(MaterialType, Pem) of
        {ok, NormalizedPem, _Der} ->
            case ias_certificate_material_store:put_certificate(
                   Id, MaterialType, NormalizedPem, Source) of
                {ok, Record, _Change} ->
                    project_certificate(Record),
                    {ok, public_status(Record)};
                {error, _} = Error -> Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

validate_public(MaterialType, Pem) ->
    case validate(MaterialType, Pem) of
        {ok, NormalizedPem, _Der} -> {ok, NormalizedPem};
        {error, Reason} -> {error, Reason}
    end.

stage_cmp(EnrollmentId, Pem) ->
    ensure_table(),
    case validate(client_certificate, Pem) of
        {ok, NormalizedPem, _Der} ->
            case ias_certificate_material_store:stage_cmp(
                   EnrollmentId, NormalizedPem) of
                {ok, Record, _Change} ->
                    project_staged(Record),
                    {ok, public_status(Record)};
                {error, _} = Error -> Error
            end;
        {error, Reason} -> {error, Reason}
    end.

attach_staged(EnrollmentId, CertificateId) ->
    ensure_table(),
    CertificateKey = ias_html:text(CertificateId),
    case ias_demo_store:get(CertificateKey) of
        {ok, #{kind := certificate}} ->
            case ias_certificate_material_store:attach_staged(
                   EnrollmentId, CertificateKey) of
                {ok, Record} ->
                    ets:delete(?TABLE,
                               {staged_cmp, ias_html:text(EnrollmentId)}),
                    project_certificate(Record),
                    {ok, public_status(Record)};
                not_found -> not_found;
                {error, staged_cmp_material_expired} = Error ->
                    ets:delete(?TABLE,
                               {staged_cmp, ias_html:text(EnrollmentId)}),
                    Error;
                {error, _} = Error -> Error
            end;
        _ ->
            {error, certificate_not_found}
    end.

get(CertificateId) ->
    get(CertificateId, compatibility_read).

get(CertificateId, Purpose) ->
    case authorize(Purpose) of
        ok ->
            ensure_table(),
            case ets:lookup(?TABLE, ias_html:text(CertificateId)) of
                [{_, Record}] -> {ok, Record};
                [] -> not_found
            end;
        {error, _} = Error -> Error
    end.

status(CertificateId) ->
    case get(CertificateId, status_read) of
        {ok, Record} -> {ok, public_status(Record)};
        not_found -> not_found;
        {error, _} = Error -> Error
    end.

delete(CertificateId) ->
    ensure_table(),
    Id = ias_html:text(CertificateId),
    case ias_certificate_material_store:delete_certificate(Id) of
        ok -> ets:delete(?TABLE, Id), ok;
        {error, _} = Error -> Error
    end.

clear() ->
    ensure_table(),
    case ias_certificate_material_store:reset() of
        ok -> ets:delete_all_objects(?TABLE), ok;
        {error, _} = Error -> Error
    end.

count() ->
    projection_count().

projection_count() ->
    ensure_table(),
    ets:info(?TABLE, size).

rehydrate() ->
    ensure_table(),
    case ias_certificate_material_store:ensure() of
        ok ->
            case ias_certificate_material_store:all() of
                {ok, Records} -> replace_projection(Records);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

protection_mode() ->
    ias_certificate_material_protection:mode().

replace_projection(Records) ->
    Entries = [projection_entry(Record) || Record <- Records],
    Previous = ets:tab2list(?TABLE),
    try
        true = ets:delete_all_objects(?TABLE),
        true = ets:insert(?TABLE, Entries),
        {ok, length(Entries)}
    catch
        Class:Reason:Stacktrace ->
            _ = ets:delete_all_objects(?TABLE),
            _ = ets:insert(?TABLE, Previous),
            {error,
             {certificate_material_projection_failed,
              {Class, Reason, Stacktrace}}}
    end.

projection_entry(#{certificate_id := Id} = Record) ->
    {ias_html:text(Id), Record};
projection_entry(#{enrollment_id := Id} = Record) ->
    {{staged_cmp, ias_html:text(Id)}, Record}.

project_certificate(#{certificate_id := Id} = Record) ->
    true = ets:insert(?TABLE, {ias_html:text(Id), Record}),
    ok.

project_staged(#{enrollment_id := Id} = Record) ->
    true = ets:insert(?TABLE, {{staged_cmp, ias_html:text(Id)}, Record}),
    ok.

authorize(compatibility_read) -> ok;
authorize(status_read) -> ok;
authorize(ovpn_assembly) -> ok;
authorize(certificate_chain_validation) -> ok;
authorize(operator_inspection) -> ok;
authorize(cmp_attachment) -> ok;
authorize(configured_ca_load) -> ok;
authorize(Purpose) -> {error, {certificate_material_access_denied, Purpose}}.

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
