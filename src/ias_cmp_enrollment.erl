-module(ias_cmp_enrollment).
-export([enroll/1, enrollment_cn/1]).
-include_lib("kernel/include/file.hrl").

-define(DEFAULT_OPENSSL, "opt/openssl-3/bin/openssl").
-define(DEFAULT_CA_OPENSSL_DIR, "ca/openssl").
-define(DEFAULT_REF, "cmptestp10cr").
-define(DEFAULT_SECRET, "0000").

enroll(#{common_name := CommonName,
         enrollment_common_name := EnrollmentCN,
         profile := Curve,
         server := Server}) ->
    with_temp_dir(fun(Dir) ->
        case ca_available(Server) of
            ok -> enroll_with_openssl(Dir, CommonName, EnrollmentCN, Curve, Server);
            {error, ca_unavailable} -> {error, ca_unavailable}
        end
    end).

enroll_with_openssl(Dir, CommonName, EnrollmentCN, Curve, Server) ->
    OpenSSL = openssl_path(),
    CaOpenSSLDir = ca_openssl_dir(),
    Name = enrollment_name(EnrollmentCN),
    Params = filename:join(Dir, ias_html:join([Name, <<".ecparams.pem">>])),
    Key = filename:join(Dir, ias_html:join([Name, <<".key.enc">>])),
    Csr = filename:join(Dir, ias_html:join([Name, <<".csr">>])),
    Cert = filename:join(Dir, ias_html:join([Name, <<".pem">>])),
    case executable(OpenSSL) of
        true ->
            case filelib:is_dir(CaOpenSSLDir) of
                true ->
                    run_steps(OpenSSL, CaOpenSSLDir, Dir, CommonName, EnrollmentCN, Curve, Server,
                              Params, Key, Csr, Cert);
                false ->
                    {error, ias_html:join([<<"CA OpenSSL directory not found: ">>,
                                           ias_html:text(CaOpenSSLDir)])}
            end;
        false ->
            {error, ias_html:join([<<"OpenSSL 3 binary not executable: ">>,
                                   ias_html:text(OpenSSL)])}
    end.

run_steps(OpenSSL, CaOpenSSLDir, Dir, CommonName, EnrollmentCN, Curve, Server,
          Params, Key, Csr, Cert) ->
    Steps = [
        {ecparams, Dir, [<<"ecparam">>, <<"-name">>, Curve, <<"-out">>, Params]},
        {csr, Dir, [<<"req">>, <<"-new">>,
               <<"-newkey">>, ias_html:join([<<"ec:">>, Params]),
               <<"-keyout">>, Key,
               <<"-passout">>, <<"pass:0">>,
               <<"-out">>, Csr,
               <<"-subj">>, subject(EnrollmentCN)]},
        {cmp, CaOpenSSLDir, [<<"cmp">>,
               <<"-cmd">>, <<"p10cr">>,
               <<"-server">>, Server,
               <<"-secret">>, <<"pass:", ?DEFAULT_SECRET>>,
               <<"-ref">>, ?DEFAULT_REF,
               <<"-path">>, <<".">>,
               <<"-srvcert">>, <<"synrc.pem">>,
               <<"-certout">>, Cert,
               <<"-csr">>, Csr]},
        {metadata, Dir, [<<"x509">>, <<"-in">>, Cert,
                         <<"-noout">>, <<"-subject">>, <<"-issuer">>, <<"-dates">>]}
    ],
    run_steps(OpenSSL, Steps, #{
        requested_cn => ias_html:text(CommonName),
        enrollment_cn => ias_html:text(EnrollmentCN),
        profile => ias_html:text(Curve),
        cmp_server => ias_html:text(Server)
    }).

run_steps(_OpenSSL, [], #{metadata := Metadata} = State) ->
    {ok, maps:merge(maps:without([metadata], State), parse_metadata(Metadata))};
run_steps(OpenSSL, [{metadata, Cwd, Args} | Rest], State) ->
    case run(OpenSSL, Args, Cwd) of
        {ok, Output} -> run_steps(OpenSSL, Rest, State#{metadata => Output});
        {error, Output} -> {error, clean_error(Output)}
    end;
run_steps(OpenSSL, [{_Name, Cwd, Args} | Rest], State) ->
    case run(OpenSSL, Args, Cwd) of
        {ok, _Output} -> run_steps(OpenSSL, Rest, State);
        {error, Output} -> {error, clean_error(Output)}
    end.

run(Executable, Args, Cwd) ->
    Port = open_port({spawn_executable, Executable},
                     [exit_status,
                      binary,
                      use_stdio,
                      stderr_to_stdout,
                      hide,
                      {cd, Cwd},
                      {args, [arg(Arg) || Arg <- Args]},
                      {env, env()}]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, _Status}} ->
            {error, Acc}
    after 15000 ->
        port_close(Port),
        {error, <<"OpenSSL command timed out">>}
    end.

parse_metadata(Output) ->
    Lines = binary:split(Output, <<"\n">>, [global, trim_all]),
    #{
        subject => metadata_value(<<"subject=">>, Lines),
        issuer => metadata_value(<<"issuer=">>, Lines),
        not_before => metadata_value(<<"notBefore=">>, Lines),
        not_after => metadata_value(<<"notAfter=">>, Lines)
    }.

metadata_value(Prefix, Lines) ->
    case [Value || Line <- Lines,
                   binary:match(Line, Prefix) =:= {0, byte_size(Prefix)},
                   Value <- [binary:part(Line, byte_size(Prefix),
                                         byte_size(Line) - byte_size(Prefix))]] of
        [Value | _] -> Value;
        [] -> <<"not found">>
    end.

ca_available(Server) ->
    case parse_server(Server) of
        {ok, Host, Port} ->
            case gen_tcp:connect(binary_to_list(Host), Port, [binary, {active, false}], 1000) of
                {ok, Socket} ->
                    gen_tcp:close(Socket),
                    ok;
                {error, _Reason} ->
                    {error, ca_unavailable}
            end;
        {error, _Reason} ->
            ok
    end.

parse_server(Server) ->
    case binary:split(ias_html:text(Server), <<":">>) of
        [Host, PortBin] ->
            case string:to_integer(binary_to_list(PortBin)) of
                {Port, ""} when Port > 0, Port < 65536 -> {ok, Host, Port};
                _ -> {error, invalid_server}
            end;
        _ ->
            {error, invalid_server}
    end.

with_temp_dir(Fun) ->
    Dir = filename:join(tmp_dir(), temp_name()),
    case file:make_dir(Dir) of
        ok ->
            try Fun(Dir)
            after cleanup(Dir)
            end;
        {error, Reason} ->
            {error, ias_html:join([<<"failed to create temp dir: ">>,
                                   ias_html:text(Reason)])}
    end.

cleanup(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            [file:delete(filename:join(Dir, File)) || File <- Files],
            file:del_dir(Dir);
        {error, _Reason} ->
            ok
    end.

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Value -> Value
    end.

temp_name() ->
    ias_html:text(io_lib:format("ias_cmp_enroll_~p_~p",
                                [erlang:system_time(millisecond),
                                 erlang:unique_integer([positive])])).

enrollment_cn(CommonName) ->
    ias_html:join([ias_html:text(CommonName), <<"-">>, timestamp(), <<"-">>,
                   ias_html:text(erlang:unique_integer([positive]))]).

enrollment_name(CommonName) ->
    ias_html:join([file_stem(CommonName), <<"_">>,
                   ias_html:text(erlang:system_time(millisecond)), <<"_">>,
                   ias_html:text(erlang:unique_integer([positive]))]).

timestamp() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:local_time(),
    ias_html:text(io_lib:format("~4..0B~2..0B~2..0B-~2..0B~2..0B~2..0B",
                                [Year, Month, Day, Hour, Minute, Second])).

file_stem(Value) ->
    file_stem(ias_html:text(Value), <<>>).

file_stem(<<>>, <<>>) ->
    <<"enroll">>;
file_stem(<<>>, Acc) ->
    Acc;
file_stem(<<Char/utf8, Rest/binary>>, Acc)
  when (Char >= $a andalso Char =< $z) orelse
       (Char >= $A andalso Char =< $Z) orelse
       (Char >= $0 andalso Char =< $9) orelse
       Char =:= $_ orelse
       Char =:= $- ->
    file_stem(Rest, <<Acc/binary, Char/utf8>>);
file_stem(<<_Char/utf8, Rest/binary>>, Acc) ->
    file_stem(Rest, <<Acc/binary, $_>>).

openssl_path() ->
    case os:getenv("OPENSSL3") of
        false -> filename:join(home_dir(), ?DEFAULT_OPENSSL);
        Value -> Value
    end.

ca_openssl_dir() ->
    case os:getenv("CA_OPENSSL_DIR") of
        false -> filename:join(home_dir(), ?DEFAULT_CA_OPENSSL_DIR);
        Value -> Value
    end.

home_dir() ->
    case os:getenv("HOME") of
        false -> ".";
        Value -> Value
    end.

executable(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} ->
            Mode = Info#file_info.mode,
            Mode band 8#001 =/= 0 orelse
            Mode band 8#010 =/= 0 orelse
            Mode band 8#100 =/= 0;
        {error, _Reason} ->
            false
    end.

env() ->
    Home = home_dir(),
    OpenSSLLib = filename:join([Home, "opt", "openssl-3", "lib64"]) ++ ":" ++
                 filename:join([Home, "opt", "openssl-3", "lib"]),
    [{"LD_LIBRARY_PATH", ld_library_path(OpenSSLLib)}].

ld_library_path(OpenSSLLib) ->
    case os:getenv("LD_LIBRARY_PATH") of
        false -> OpenSSLLib;
        Existing -> OpenSSLLib ++ ":" ++ Existing
    end.

subject(CommonName) ->
    ias_html:join([<<"/CN=">>, escape_subject(ias_html:text(CommonName))]).

escape_subject(Value) ->
    escape_subject(Value, <<>>).

escape_subject(<<>>, Acc) ->
    Acc;
escape_subject(<<$/, Rest/binary>>, Acc) ->
    escape_subject(Rest, <<Acc/binary, "\\/">>);
escape_subject(<<$\\, Rest/binary>>, Acc) ->
    escape_subject(Rest, <<Acc/binary, "\\\\">>);
escape_subject(<<Char/utf8, Rest/binary>>, Acc) ->
    escape_subject(Rest, <<Acc/binary, Char/utf8>>).

arg(Value) when is_binary(Value) ->
    binary_to_list(Value);
arg(Value) ->
    Value.

clean_error(Output) ->
    Text = ias_html:text(Output),
    case Text of
        <<>> -> <<"OpenSSL CMP enrollment failed">>;
        _ -> Text
    end.
