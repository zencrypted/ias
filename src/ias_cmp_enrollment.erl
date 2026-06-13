-module(ias_cmp_enrollment).
-export([enroll/1]).
-include_lib("kernel/include/file.hrl").

-define(DEFAULT_OPENSSL, "opt/openssl-3/bin/openssl").
-define(DEFAULT_CA_OPENSSL_DIR, "ca/openssl").
-define(DEFAULT_REF, "cmptestp10cr").
-define(DEFAULT_SECRET, "0000").

enroll(#{common_name := CommonName,
         profile := Curve,
         server := Server}) ->
    with_temp_dir(fun(Dir) ->
        case ca_available(Server) of
            ok -> enroll_with_openssl(Dir, CommonName, Curve, Server);
            {error, ca_unavailable} -> {error, ca_unavailable}
        end
    end).

enroll_with_openssl(Dir, CommonName, Curve, Server) ->
    OpenSSL = openssl_path(),
    CaOpenSSLDir = ca_openssl_dir(),
    Params = filename:join(Dir, "ecparams.pem"),
    Key = "/dev/null",
    Csr = filename:join(Dir, "client.csr"),
    Cert = filename:join(Dir, "client.pem"),
    case executable(OpenSSL) of
        true ->
            case filelib:is_dir(CaOpenSSLDir) of
                true ->
                    run_steps(OpenSSL, CaOpenSSLDir, CommonName, Curve, Server,
                              Params, Key, Csr, Cert);
                false ->
                    {error, ias_html:join([<<"CA OpenSSL directory not found: ">>,
                                           ias_html:text(CaOpenSSLDir)])}
            end;
        false ->
            {error, ias_html:join([<<"OpenSSL 3 binary not executable: ">>,
                                   ias_html:text(OpenSSL)])}
    end.

run_steps(OpenSSL, CaOpenSSLDir, CommonName, Curve, Server,
          Params, Key, Csr, Cert) ->
    Steps = [
        {ecparams, [<<"ecparam">>, <<"-name">>, Curve, <<"-out">>, Params]},
        {csr, [<<"req">>, <<"-new">>,
               <<"-newkey">>, ias_html:join([<<"ec:">>, Params]),
               <<"-keyout">>, Key,
               <<"-passout">>, <<"pass:0">>,
               <<"-out">>, Csr,
               <<"-subj">>, subject(CommonName)]},
        {cmp, [<<"cmp">>,
               <<"-cmd">>, <<"p10cr">>,
               <<"-server">>, Server,
               <<"-secret">>, <<"pass:", ?DEFAULT_SECRET>>,
               <<"-ref">>, ?DEFAULT_REF,
               <<"-path">>, <<".">>,
               <<"-srvcert">>, <<"synrc.pem">>,
               <<"-certout">>, Cert,
               <<"-csr">>, Csr]},
        {metadata, [<<"x509">>, <<"-in">>, Cert,
                    <<"-noout">>, <<"-subject">>, <<"-issuer">>, <<"-dates">>]}
    ],
    run_steps(OpenSSL, CaOpenSSLDir, Steps, #{}).

run_steps(_OpenSSL, _Cwd, [], #{metadata := Metadata}) ->
    parse_metadata(Metadata);
run_steps(OpenSSL, Cwd, [{metadata, Args} | Rest], State) ->
    case run(OpenSSL, Args, Cwd) of
        {ok, Output} -> run_steps(OpenSSL, Cwd, Rest, State#{metadata => Output});
        {error, Output} -> {error, clean_error(Output)}
    end;
run_steps(OpenSSL, Cwd, [{_Name, Args} | Rest], State) ->
    case run(OpenSSL, Args, Cwd) of
        {ok, _Output} -> run_steps(OpenSSL, Cwd, Rest, State);
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
    {ok, #{
        subject => metadata_value(<<"subject=">>, Lines),
        issuer => metadata_value(<<"issuer=">>, Lines),
        not_before => metadata_value(<<"notBefore=">>, Lines),
        not_after => metadata_value(<<"notAfter=">>, Lines)
    }}.

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
