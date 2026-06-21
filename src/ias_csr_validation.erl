-module(ias_csr_validation).
-export([validate/1]).

validate(Pem0) ->
    Pem = trim(ias_html:text(Pem0)),
    case contains_private_material(Pem) of
        true ->
            {error, private_key_supplied};
        false ->
            decode_csr(Pem)
    end.

decode_csr(<<>>) ->
    {error, malformed_csr};
decode_csr(Pem) ->
    try public_key:pem_decode(Pem) of
        [{'CertificationRequest', Der, _}] ->
            decode_der(Pem, Der);
        [] ->
            {error, malformed_csr};
        _ ->
            {error, exactly_one_csr_required}
    catch
        _:_ -> {error, malformed_csr}
    end.

decode_der(Pem, Der) ->
    try public_key:der_decode('CertificationRequest', Der) of
        Csr ->
            case csr_signature_valid(Pem) of
                true ->
                    metadata(Pem, Der, Csr);
                false ->
                    {error, csr_signature_invalid}
            end
    catch
        _:_ -> {error, malformed_csr}
    end.

metadata(Pem, Der, {'CertificationRequest', Info, _SigAlg, _Signature}) ->
    Subject = element(3, Info),
    PublicKeyInfo = element(4, Info),
    SubjectText = certificate_name(Subject),
    case safe_subject(SubjectText) of
        true ->
            {ok, #{pem => ensure_newline(Pem),
                   der => Der,
                   subject => SubjectText,
                   subject_cn => common_name_or_subject(SubjectText),
                   csr_fingerprint => fingerprint(Der),
                   public_key_fingerprint => public_key_fingerprint(PublicKeyInfo)}};
        false ->
            {error, unsafe_subject}
    end.

csr_signature_valid(Pem) ->
    with_temp_file(Pem, fun(Path) ->
        case openssl_path() of
            false -> false;
            OpenSSL ->
                case run(OpenSSL, [<<"req">>, <<"-verify">>, <<"-noout">>,
                                   <<"-in">>, ias_html:text(Path)]) of
                    {ok, Output} -> csr_verify_output_ok(Output);
                    {error, _Output} -> false
                end
        end
    end).

csr_verify_output_ok(Output) ->
    binary:match(Output, <<"verify OK">>) =/= nomatch andalso
        binary:match(Output, <<"verify failure">>) =:= nomatch.

with_temp_file(Pem, Fun) ->
    Path = filename:join(tmp_dir(), temp_name()),
    case file:write_file(Path, Pem) of
        ok ->
            try Fun(Path)
            after file:delete(Path)
            end;
        {error, _Reason} ->
            false
    end.

run(Executable, Args) ->
    Port = open_port({spawn_executable, Executable},
                     [exit_status,
                      binary,
                      use_stdio,
                      stderr_to_stdout,
                      hide,
                      {args, [arg(Arg) || Arg <- Args]}]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, _Status}} ->
            {error, Acc}
    after 10000 ->
        port_close(Port),
        {error, <<"OpenSSL CSR verification timed out">>}
    end.

openssl_path() ->
    case os:getenv("OPENSSL") of
        false -> os:find_executable("openssl");
        Value -> Value
    end.

certificate_name({rdnSequence, Rdns}) ->
    case common_name(Rdns) of
        undefined -> ias_html:text(io_lib:format("~p", [{rdnSequence, Rdns}]));
        Cn -> ias_html:join([<<"CN=">>, Cn])
    end;
certificate_name(Name) ->
    ias_html:text(io_lib:format("~p", [Name])).

common_name(Rdns) ->
    Values = [Value || Rdn <- Rdns,
                       Attribute <- Rdn,
                       Value <- [common_name_value(Attribute)],
                       Value =/= undefined],
    case Values of
        [Value | _] -> Value;
        [] -> undefined
    end.

common_name_value({'AttributeTypeAndValue', {2,5,4,3}, Value}) ->
    directory_string(Value);
common_name_value(_) ->
    undefined.

directory_string(<<12, Len, Value:Len/binary>>) -> ias_html:text(Value);
directory_string(<<19, Len, Value:Len/binary>>) -> ias_html:text(Value);
directory_string(<<20, Len, Value:Len/binary>>) -> ias_html:text(Value);
directory_string({utf8String, Value}) -> ias_html:text(Value);
directory_string({printableString, Value}) -> ias_html:text(Value);
directory_string(Value) -> ias_html:text(io_lib:format("~p", [Value])).

common_name_or_subject(<<"CN=", Value/binary>>) -> Value;
common_name_or_subject(Value) -> Value.

safe_subject(<<>>) ->
    false;
safe_subject(Subject) when byte_size(Subject) > 180 ->
    false;
safe_subject(Subject) ->
    not has_control(Subject) andalso
        binary:match(Subject, [<<"\r">>, <<"\n">>, <<"\"">>]) =:= nomatch.

has_control(Text) ->
    lists:any(fun(Char) -> Char < 32 orelse Char =:= 127 end,
              binary_to_list(Text)).

public_key_fingerprint({'CertificationRequestInfo_subjectPKInfo',
                        _Algorithm, Point}) when is_binary(Point) ->
    fingerprint(Point);
public_key_fingerprint(PublicKeyInfo) ->
    fingerprint(term_to_binary(PublicKeyInfo)).

contains_private_material(Pem) ->
    Markers = [<<"BEGIN PRIVATE KEY">>, <<"BEGIN RSA PRIVATE KEY">>,
               <<"BEGIN EC PRIVATE KEY">>, <<"BEGIN ENCRYPTED PRIVATE KEY">>],
    lists:any(fun(Marker) -> binary:match(Pem, Marker) =/= nomatch end, Markers).

fingerprint(Bin) ->
    Hash = crypto:hash(sha256, Bin),
    ias_html:text(string:uppercase(binary_to_list(binary:encode_hex(Hash)))).

trim(Value) ->
    ias_html:text(string:trim(binary_to_list(Value))).

ensure_newline(<<>>) -> <<>>;
ensure_newline(Pem) ->
    case binary:last(Pem) of
        $\n -> Pem;
        _ -> <<Pem/binary, "\n">>
    end.

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Value -> Value
    end.

temp_name() ->
    ias_html:text(io_lib:format("ias_device_csr_~p_~p.csr",
                                [erlang:system_time(millisecond),
                                 erlang:unique_integer([positive])])).

arg(Value) when is_binary(Value) ->
    binary_to_list(Value);
arg(Value) ->
    Value.
