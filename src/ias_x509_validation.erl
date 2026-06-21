-module(ias_x509_validation).
-include_lib("public_key/include/public_key.hrl").
-export([mode/0,
         validate_certificate/2,
         validate_pair/2,
         validate_ovpn_inputs/3]).

validate_certificate(Role, Pem) when Role =:= ca_certificate;
                                     Role =:= client_certificate ->
    Mode = mode(),
    case decode_pem(Pem) of
        {ok, Decoded} ->
            case first_error(role_checks(Role, Decoded) ++ validity_checks(Mode, Decoded)) of
                ok ->
                    {ok, metadata(Role, Mode, Decoded)};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
validate_certificate(_Role, _Pem) ->
    {error, <<"unsupported certificate role">>}.

validate_pair(CaPem, ClientPem) ->
    Mode = mode(),
    with_valid_certificate(ca_certificate, CaPem,
      fun(Ca) ->
        with_valid_certificate(client_certificate, ClientPem,
          fun(Client) ->
            Checks = [fun() -> distinct_fingerprints(Ca, Client) end,
                      fun() -> chain_check(Mode, Ca, Client) end],
            case first_error(Checks) of
                ok ->
                    {ok, #{mode => Mode,
                           ca_fingerprint => maps:get(fingerprint_sha256, Ca),
                           client_fingerprint => maps:get(fingerprint_sha256, Client),
                           development_bypass => Mode =:= development}};
                {error, Reason} ->
                    {error, Reason}
            end
          end)
      end).

validate_ovpn_inputs(Device, Service, KeyRef) ->
    Checks = [
        fun() -> validate_protocol(maps:get(protocol, Service, <<"udp">>)) end,
        fun() -> validate_port(first_present([maps:get(remote_port, Service, undefined),
                                              endpoint_port(Service)])) end,
        fun() -> validate_endpoint(first_present([maps:get(remote_host, Service, undefined),
                                                  endpoint_host(Service)])) end,
        fun() -> validate_tunnel_device(maps:get(tunnel_device, Device, <<"tun">>)) end,
        fun() -> validate_key_ref(KeyRef) end
    ],
    case first_error(Checks) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

mode() ->
    case application:get_env(ias, certificate_validation_mode, strict) of
        strict -> strict;
        development -> development;
        _ -> strict
    end.

with_valid_certificate(Role, Pem, Fun) ->
    case validate_certificate(Role, Pem) of
        {ok, Metadata} -> Fun(Metadata);
        {error, Reason} -> {error, Reason}
    end.

decode_pem(Pem0) ->
    Pem = ias_html:text(Pem0),
    case contains_private_material(Pem) of
        true ->
            {error, <<"private key material is not certificate material">>};
        false ->
            decode_public_certificate(Pem)
    end.

decode_public_certificate(Pem) ->
    try public_key:pem_decode(Pem) of
        [{'Certificate', Der, _}] ->
            try public_key:pkix_decode_cert(Der, otp) of
                Cert -> {ok, #{der => Der,
                               cert => Cert,
                               fingerprint_sha256 => fingerprint(Der)}}
            catch
                _:_ -> {error, <<"invalid X.509 certificate">>}
            end;
        [] ->
            {error, <<"invalid certificate PEM">>};
        _ ->
            {error, <<"exactly one public certificate PEM is required">>}
    catch
        _:_ -> {error, <<"invalid certificate PEM">>}
    end.

contains_private_material(Pem) ->
    Markers = [<<"BEGIN PRIVATE KEY">>, <<"BEGIN RSA PRIVATE KEY">>,
               <<"BEGIN EC PRIVATE KEY">>, <<"BEGIN ENCRYPTED PRIVATE KEY">>],
    lists:any(fun(Marker) -> binary:match(Pem, Marker) =/= nomatch end, Markers).

role_checks(ca_certificate, Decoded) ->
    [fun() -> require_ca_true(Decoded) end,
     fun() -> require_key_cert_sign_when_present(Decoded) end];
role_checks(client_certificate, Decoded) ->
    [fun() -> reject_ca_true(Decoded) end,
     fun() -> require_client_auth_when_present(Decoded) end].

validity_checks(development, _Decoded) ->
    [];
validity_checks(strict, Decoded) ->
    [fun() -> require_current_validity(Decoded) end].

require_ca_true(Decoded) ->
    case basic_constraints(Decoded) of
        #'BasicConstraints'{cA = true} -> ok;
        _ -> {error, <<"CA certificate must have basicConstraints CA=TRUE">>}
    end.

reject_ca_true(Decoded) ->
    case basic_constraints(Decoded) of
        #'BasicConstraints'{cA = true} ->
            {error, <<"client certificate must not have basicConstraints CA=TRUE">>};
        _ ->
            ok
    end.

require_key_cert_sign_when_present(Decoded) ->
    case extension_value(Decoded, ?'id-ce-keyUsage') of
        undefined -> ok;
        Usages when is_list(Usages) ->
            case lists:member(keyCertSign, Usages) of
                true -> ok;
                false -> {error, <<"CA certificate keyUsage must include keyCertSign">>}
            end;
        _ -> ok
    end.

require_client_auth_when_present(Decoded) ->
    case extension_value(Decoded, ?'id-ce-extKeyUsage') of
        undefined -> ok;
        Usages when is_list(Usages) ->
            case lists:member(?'id-kp-clientAuth', Usages) of
                true -> ok;
                false -> {error, <<"client certificate EKU must include clientAuth">>}
            end;
        _ -> ok
    end.

require_current_validity(Decoded) ->
    #'OTPCertificate'{tbsCertificate = Tbs} = maps:get(cert, Decoded),
    #'OTPTBSCertificate'{validity = #'Validity'{notBefore = NotBefore,
                                                notAfter = NotAfter}} = Tbs,
    Now = calendar:universal_time(),
    case compare_time(Now, cert_time(NotBefore)) of
        before -> {error, <<"certificate is not valid yet">>};
        _ ->
            case compare_time(Now, cert_time(NotAfter)) of
                'after' -> {error, <<"certificate has expired">>};
                _ -> ok
            end
    end.

metadata(Role, Mode, Decoded) ->
    #'OTPCertificate'{tbsCertificate = Tbs} = maps:get(cert, Decoded),
    #'OTPTBSCertificate'{serialNumber = Serial,
                         issuer = Issuer,
                         subject = Subject,
                         subjectPublicKeyInfo = PublicKeyInfo,
                         validity = #'Validity'{notBefore = NotBefore,
                                                notAfter = NotAfter}} = Tbs,
    #{role => Role,
      validation_mode => Mode,
      fingerprint_sha256 => maps:get(fingerprint_sha256, Decoded),
      subject => certificate_name(Subject),
      issuer => certificate_name(Issuer),
      serial => integer_to_binary(Serial),
      not_before => certificate_time(NotBefore),
      not_after => certificate_time(NotAfter),
      public_key_fingerprint => public_key_fingerprint(PublicKeyInfo),
      der => maps:get(der, Decoded)}.

basic_constraints(Decoded) ->
    extension_value(Decoded, ?'id-ce-basicConstraints').

extension_value(Decoded, Oid) ->
    #'OTPCertificate'{tbsCertificate = Tbs} = maps:get(cert, Decoded),
    #'OTPTBSCertificate'{extensions = Extensions} = Tbs,
    case Extensions of
        asn1_NOVALUE -> undefined;
        _ ->
            case [Value || #'Extension'{extnID = Id, extnValue = Value} <- Extensions,
                           Id =:= Oid] of
                [Value | _] -> Value;
                [] -> undefined
            end
    end.

distinct_fingerprints(Ca, Client) ->
    case maps:get(fingerprint_sha256, Ca) =:= maps:get(fingerprint_sha256, Client) of
        true -> {error, <<"CA and client certificates must be different">>};
        false -> ok
    end.

chain_check(development, _Ca, _Client) ->
    ok;
chain_check(strict, Ca, Client) ->
    case public_key:pkix_path_validation(maps:get(der, Ca), [maps:get(der, Client)], []) of
        {ok, _} -> ok;
        {error, _Reason} -> {error, <<"client certificate does not verify against selected CA">>}
    end.

validate_protocol(Value) ->
    case ias_html:text(Value) of
        <<"udp">> -> ok;
        <<"tcp">> -> ok;
        _ -> {error, <<"OVPN protocol must be udp or tcp">>}
    end.

validate_port(undefined) ->
    {error, <<"missing VPN endpoint">>};
validate_port(Value) ->
    Text = ias_html:text(Value),
    case catch binary_to_integer(Text) of
        Port when is_integer(Port), Port >= 1, Port =< 65535 -> ok;
        _ -> {error, <<"OVPN remote port must be in 1..65535">>}
    end.

validate_endpoint(undefined) ->
    {error, <<"missing VPN endpoint">>};
validate_endpoint(Value) ->
    Text = ias_html:text(Value),
    case Text =/= <<>> andalso safe_endpoint(Text) of
        true -> ok;
        false -> {error, <<"OVPN remote endpoint contains unsafe characters">>}
    end.

safe_endpoint(Text) ->
    not has_control(Text) andalso
        binary:match(Text, [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>]) =:= nomatch.

validate_tunnel_device(Value) ->
    case safe_token(ias_html:text(Value)) of
        true -> ok;
        false -> {error, <<"OVPN tunnel device contains unsafe characters">>}
    end.

validate_key_ref(Value) ->
    case ias_device_key_ref:validate(<<"device_file">>, Value) of
        {ok, #{private_key_ref := Ref}} ->
            case safe_relative_path_token(Ref) of
                true -> ok;
                false -> {error, <<"Device-owned private key reference is invalid.">>}
            end;
        {error, _Reason} ->
            {error, <<"Device-owned private key reference is invalid.">>}
    end.

safe_token(<<>>) ->
    false;
safe_token(Text) when byte_size(Text) > 64 ->
    false;
safe_token(Text) ->
    lists:all(fun safe_token_char/1, binary_to_list(Text)).

safe_token_char(Char) ->
    (Char >= $a andalso Char =< $z) orelse
    (Char >= $A andalso Char =< $Z) orelse
    (Char >= $0 andalso Char =< $9) orelse
    Char =:= $_ orelse Char =:= $- orelse Char =:= $..

safe_relative_path_token(<<>>) ->
    false;
safe_relative_path_token(Text) when byte_size(Text) > 180 ->
    false;
safe_relative_path_token(Text) ->
    lists:all(fun safe_path_char/1, binary_to_list(Text)).

safe_path_char(Char) ->
    safe_token_char(Char) orelse Char =:= $/.

has_control(Text) ->
    lists:any(fun(Char) -> Char < 32 orelse Char =:= 127 end,
              binary_to_list(Text)).

endpoint_host(Service) ->
    {Host, _Port} = split_endpoint(maps:get(remote, Service,
                                            maps:get(endpoint, Service, <<"">>))),
    Host.

endpoint_port(Service) ->
    {_Host, Port} = split_endpoint(maps:get(remote, Service,
                                            maps:get(endpoint, Service, <<"">>))),
    Port.

split_endpoint(Value0) ->
    Value = ias_html:text(Value0),
    case binary:split(Value, <<":">>, [global]) of
        [Host, Port] -> {Host, Port};
        [Host] -> {Host, undefined};
        Parts ->
            [Port | RevHostParts] = lists:reverse(Parts),
            {ias_html:join(lists:join(<<":">>, lists:reverse(RevHostParts))), Port}
    end.

first_present([]) ->
    undefined;
first_present([Value | Rest]) ->
    case present(Value) of
        true -> Value;
        false -> first_present(Rest)
    end.

present(undefined) -> false;
present(not_found) -> false;
present(<<>>) -> false;
present(Value) -> ias_html:text(Value) =/= <<"not found">>.

cert_time({utcTime, Value}) ->
    parse_utc_time(ias_html:text(Value));
cert_time({generalTime, Value}) ->
    parse_general_time(ias_html:text(Value)).

certificate_time({utcTime, Value}) ->
    ias_html:text(Value);
certificate_time({generalTime, Value}) ->
    ias_html:text(Value);
certificate_time(Value) ->
    ias_html:text(io_lib:format("~p", [Value])).

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

common_name_value(#'AttributeTypeAndValue'{type = ?'id-at-commonName',
                                           value = Value}) ->
    directory_string(Value);
common_name_value(_) ->
    undefined.

directory_string({utf8String, Value}) -> ias_html:text(Value);
directory_string({printableString, Value}) -> ias_html:text(Value);
directory_string({teletexString, Value}) -> ias_html:text(Value);
directory_string({bmpString, Value}) -> ias_html:text(Value);
directory_string({universalString, Value}) -> ias_html:text(Value);
directory_string(Value) -> ias_html:text(io_lib:format("~p", [Value])).

public_key_fingerprint({'OTPSubjectPublicKeyInfo', _Algorithm, {'ECPoint', Point}}) ->
    fingerprint(Point);
public_key_fingerprint(PublicKeyInfo) ->
    fingerprint(term_to_binary(PublicKeyInfo)).

parse_utc_time(<<Y1:2/binary, M:2/binary, D:2/binary,
                 H:2/binary, Min:2/binary, S:2/binary, "Z">>) ->
    Year0 = binary_to_integer(Y1),
    Year = case Year0 >= 50 of
        true -> 1900 + Year0;
        false -> 2000 + Year0
    end,
    {{Year, binary_to_integer(M), binary_to_integer(D)},
     {binary_to_integer(H), binary_to_integer(Min), binary_to_integer(S)}}.

parse_general_time(<<Y:4/binary, M:2/binary, D:2/binary,
                     H:2/binary, Min:2/binary, S:2/binary, "Z">>) ->
    {{binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)},
     {binary_to_integer(H), binary_to_integer(Min), binary_to_integer(S)}}.

compare_time(Left, Right) ->
    case calendar:datetime_to_gregorian_seconds(Left) -
        calendar:datetime_to_gregorian_seconds(Right) of
        Delta when Delta < 0 -> before;
        Delta when Delta > 0 -> 'after';
        _ -> equal
    end.

fingerprint(Der) ->
    Hash = crypto:hash(sha256, Der),
    ias_html:text(string:uppercase(binary_to_list(binary:encode_hex(Hash)))).

first_error([]) ->
    ok;
first_error([Check | Rest]) ->
    case Check() of
        ok -> first_error(Rest);
        {error, Reason} -> {error, Reason}
    end.
