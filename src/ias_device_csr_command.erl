-module(ias_device_csr_command).
-export([generate/1, script/1]).

generate(Device) when is_map(Device) ->
    case ias_device_key_ref:status(Device) of
        {ok, #{private_key_provider := <<"device_file">>,
               private_key_ref := KeyRef}} ->
            Stem = device_stem(Device),
            Nonce = nonce(),
            CommonName = ias_html:join([Stem, <<"-">>, Nonce]),
            CsrFile = ias_html:join([CommonName, <<".csr">>]),
            {ok, #{private_key_provider => <<"device_file">>,
                   private_key_ref => KeyRef,
                   common_name => CommonName,
                   csr_filename => CsrFile,
                   command => command(KeyRef, CsrFile, CommonName),
                   script_filename => script_filename(CommonName)}};
        {error, Reason} ->
            {error, Reason}
    end;
generate(_Device) ->
    {error, device_required}.

script(#{private_key_ref := KeyRef,
         csr_filename := CsrFile,
         common_name := CommonName}) ->
    ias_html:join([
        <<"#!/bin/sh\n">>,
        <<"set -eu\n\n">>,
        <<"KEY_REF=">>, shell_quote(KeyRef), <<"\n">>,
        <<"CSR_OUT=">>, shell_quote(CsrFile), <<"\n">>,
        <<"SUBJECT_CN=">>, shell_quote(CommonName), <<"\n\n">>,
        <<"if [ ! -f \"$KEY_REF\" ]; then\n">>,
        <<"  echo \"Private key reference not found: $KEY_REF\" >&2\n">>,
        <<"  exit 1\n">>,
        <<"fi\n\n">>,
        <<"if [ -e \"$CSR_OUT\" ]; then\n">>,
        <<"  echo \"Refusing to overwrite existing CSR: $CSR_OUT\" >&2\n">>,
        <<"  exit 1\n">>,
        <<"fi\n\n">>,
        <<"openssl req -new \\\n">>,
        <<"  -key \"$KEY_REF\" \\\n">>,
        <<"  -out \"$CSR_OUT\" \\\n">>,
        <<"  -subj \"/CN=$SUBJECT_CN\"\n\n">>,
        <<"echo \"$CSR_OUT\"\n">>
    ]).

command(KeyRef, CsrFile, CommonName) ->
    ias_html:join([
        <<"openssl req -new \\\n">>,
        <<"  -key ">>, shell_quote(KeyRef), <<" \\\n">>,
        <<"  -out ">>, shell_quote(CsrFile), <<" \\\n">>,
        <<"  -subj ">>, shell_quote(ias_html:join([<<"/CN=">>, CommonName]))
    ]).

device_stem(Device) ->
    Raw = first_defined([maps:get(name, Device, undefined),
                         maps:get(id, Device, undefined),
                         <<"vpn-client">>]),
    Safe0 = safe_token(ias_html:text(Raw)),
    case Safe0 of
        <<>> -> <<"vpn-client">>;
        Safe -> Safe
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
