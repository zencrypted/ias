-module(ias_device_csr_command).
-export([generate/1, script/1]).

generate(#{kind := device} = Device) ->
    case device_stem(Device) of
        {ok, Stem} ->
            Nonce = nonce(),
            Basename = ias_html:join([Stem, <<"-">>, Nonce]),
            CommonName = Basename,
            KeyRef = ias_html:join([<<"keys/">>, Basename, <<".key">>]),
            CsrFile = ias_html:join([Basename, <<".csr">>]),
            case ias_device_key_ref:validate(<<"device_file">>, KeyRef) of
                {ok, #{private_key_ref := SafeKeyRef}} ->
                    {ok, #{private_key_provider => <<"device_file">>,
                           private_key_ref => SafeKeyRef,
                           key_filename => SafeKeyRef,
                           common_name => CommonName,
                           csr_filename => CsrFile,
                           command => command(SafeKeyRef, CsrFile, CommonName),
                           script_filename => script_filename(CommonName)}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
generate(_Device) ->
    {error, device_required}.

script(#{key_filename := KeyRef,
         csr_filename := CsrFile,
         common_name := CommonName}) ->
    ias_html:join([
        <<"#!/bin/sh\n">>,
        <<"set -eu\n\n">>,
        <<"OPENSSL=\"${OPENSSL3:-openssl}\"\n">>,
        <<"KEY_FILE=">>, shell_quote(KeyRef), <<"\n">>,
        <<"CSR_OUT=">>, shell_quote(CsrFile), <<"\n">>,
        <<"SUBJECT_CN=">>, shell_quote(CommonName), <<"\n\n">>,
        <<"KEY_DIR=$(dirname \"$KEY_FILE\")\n">>,
        <<"mkdir -p \"$KEY_DIR\"\n\n">>,
        <<"if [ -e \"$KEY_FILE\" ]; then\n">>,
        <<"  echo \"Refusing to overwrite existing private key: $KEY_FILE\" >&2\n">>,
        <<"  exit 1\n">>,
        <<"fi\n\n">>,
        <<"if [ -e \"$CSR_OUT\" ]; then\n">>,
        <<"  echo \"Refusing to overwrite existing CSR: $CSR_OUT\" >&2\n">>,
        <<"  exit 1\n">>,
        <<"fi\n\n">>,
        <<"\"$OPENSSL\" ecparam \\\n">>,
        <<"  -name secp384r1 \\\n">>,
        <<"  -genkey \\\n">>,
        <<"  -noout \\\n">>,
        <<"  -out \"$KEY_FILE\"\n\n">>,
        <<"chmod 600 \"$KEY_FILE\"\n\n">>,
        <<"\"$OPENSSL\" req \\\n">>,
        <<"  -new \\\n">>,
        <<"  -key \"$KEY_FILE\" \\\n">>,
        <<"  -out \"$CSR_OUT\" \\\n">>,
        <<"  -subj \"/CN=$SUBJECT_CN\"\n\n">>,
        <<"\"$OPENSSL\" req -verify -noout -in \"$CSR_OUT\" >/dev/null\n\n">>,
        <<"echo \"Private key: $KEY_FILE\"\n">>,
        <<"echo \"CSR: $CSR_OUT\"\n">>
    ]).

command(KeyRef, CsrFile, CommonName) ->
    ias_html:join([
        <<"OPENSSL=\"${OPENSSL3:-openssl}\"\n">>,
        <<"$OPENSSL ecparam -name secp384r1 -genkey -noout -out ">>,
        shell_quote(KeyRef), <<"\n">>,
        <<"chmod 600 ">>, shell_quote(KeyRef), <<"\n">>,
        <<"$OPENSSL req -new -key ">>, shell_quote(KeyRef),
        <<" -out ">>, shell_quote(CsrFile),
        <<" -subj ">>, shell_quote(ias_html:join([<<"/CN=">>, CommonName]))
    ]).

device_stem(Device) ->
    Raw = first_defined([maps:get(name, Device, undefined),
                         maps:get(id, Device, undefined),
                         <<"vpn-client">>]),
    Text = ias_html:text(Raw),
    case unsafe_metadata(Text) of
        true ->
            {error, unsafe_device_metadata};
        false ->
            Safe0 = safe_token(Text),
            case Safe0 of
                <<>> -> {ok, <<"vpn-client">>};
                Safe -> {ok, Safe}
            end
    end.

first_defined([]) -> <<"vpn-client">>;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([<<>> | Rest]) -> first_defined(Rest);
first_defined([Value | _Rest]) -> Value.

safe_token(Text) ->
    Lower = string:lowercase(ias_html:text(Text)),
    Chars = [safe_char(Char) || <<Char>> <= Lower],
    Collapsed = collapse_dashes(iolist_to_binary(Chars)),
    trim_dashes(Collapsed).

safe_char(Char) when Char >= $a, Char =< $z -> <<Char>>;
safe_char(Char) when Char >= $0, Char =< $9 -> <<Char>>;
safe_char($-) -> <<"-">>;
safe_char($_) -> <<"-">>;
safe_char(_) -> <<"-">>.

collapse_dashes(Text) ->
    re:replace(Text, <<"-+">>, <<"-">>, [global, {return, binary}]).

trim_dashes(Text) ->
    re:replace(Text, <<"^-+|-+$">>, <<>>, [global, {return, binary}]).

unsafe_metadata(Text) ->
    has_control(Text) orelse
        binary:match(Text, [<<"'">>, <<"\"">>, <<"`">>, <<"$">>, <<";">>,
                            <<"&">>, <<"|">>, <<"<">>, <<">">>]) =/= nomatch.

has_control(Text) ->
    lists:any(fun(Char) -> Char < 32 orelse Char =:= 127 end,
              binary_to_list(Text)).

nonce() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    Unique = erlang:unique_integer([positive, monotonic]),
    ias_html:text(io_lib:format("~4..0B~2..0B~2..0B-~2..0B~2..0B~2..0B-~B",
                                [Year, Month, Day, Hour, Minute, Second, Unique])).

script_filename(CommonName) ->
    ias_html:join([CommonName, <<"-generate-csr.sh">>]).

shell_quote(Value) ->
    Text = ias_html:text(Value),
    Escaped = binary:replace(Text, <<"\'">>, <<"'\''">>, [global]),
    ias_html:join([<<"'">>, Escaped, <<"'">>]).
