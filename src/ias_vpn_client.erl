-module(ias_vpn_client).
-export([summary/0]).

summary() ->
    case application:get_env(ias, vpn_admin_url) of
        {ok, Url} -> request(Url);
        undefined -> {error, not_configured}
    end.

request(Url) ->
    try
        {ok, _} = application:ensure_all_started(inets),
        case httpc:request(get, {Url, []}, [{timeout, 3000}], [{body_format, binary}]) of
            {ok, {{_, Code, _}, _Headers, Body}} when Code >= 200, Code < 300 ->
                decode(Body);
            {ok, {{_, Code, _}, _Headers, _Body}} ->
                {error, {http_status, Code}};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        Class:CatchReason ->
            {error, {Class, CatchReason}}
    end.

decode(Body) ->
    case parse_json(Body) of
        {ok, Data, Rest} ->
            case skip_ws(Rest) of
                <<>> -> {ok, Data};
                _ -> {error, trailing_json}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

parse_json(Bin) when is_binary(Bin) ->
    parse_value(skip_ws(Bin)).

parse_value(<<"{", Rest/binary>>) ->
    parse_object(skip_ws(Rest), #{});
parse_value(<<"[", Rest/binary>>) ->
    parse_array(skip_ws(Rest), []);
parse_value(<<"\"", Rest/binary>>) ->
    parse_string(Rest, []);
parse_value(<<"true", Rest/binary>>) ->
    {ok, true, Rest};
parse_value(<<"false", Rest/binary>>) ->
    {ok, false, Rest};
parse_value(<<"null", Rest/binary>>) ->
    {ok, undefined, Rest};
parse_value(Bin) ->
    parse_number(Bin).

parse_object(<<"}", Rest/binary>>, Acc) ->
    {ok, Acc, Rest};
parse_object(Bin, Acc) ->
    case parse_value(Bin) of
        {ok, Key, AfterKey} ->
            AfterColon = skip_ws(AfterKey),
            case AfterColon of
                <<":", AfterValue0/binary>> ->
                    case parse_value(skip_ws(AfterValue0)) of
                        {ok, Value, AfterValue} ->
                            parse_object_tail(skip_ws(AfterValue), Acc#{Key => Value});
                        {error, Reason} ->
                            {error, Reason}
                    end;
                _ ->
                    {error, expected_colon}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

parse_object_tail(<<"}", Rest/binary>>, Acc) ->
    {ok, Acc, Rest};
parse_object_tail(<<",", Rest/binary>>, Acc) ->
    parse_object(skip_ws(Rest), Acc);
parse_object_tail(_, _Acc) ->
    {error, expected_object_tail}.

parse_array(<<"]", Rest/binary>>, Acc) ->
    {ok, lists:reverse(Acc), Rest};
parse_array(Bin, Acc) ->
    case parse_value(Bin) of
        {ok, Value, Rest} ->
            parse_array_tail(skip_ws(Rest), [Value | Acc]);
        {error, Reason} ->
            {error, Reason}
    end.

parse_array_tail(<<"]", Rest/binary>>, Acc) ->
    {ok, lists:reverse(Acc), Rest};
parse_array_tail(<<",", Rest/binary>>, Acc) ->
    parse_array(skip_ws(Rest), Acc);
parse_array_tail(_, _Acc) ->
    {error, expected_array_tail}.

parse_string(<<"\"", Rest/binary>>, Acc) ->
    {ok, unicode:characters_to_binary(lists:reverse(Acc)), Rest};
parse_string(<<"\\\"", Rest/binary>>, Acc) ->
    parse_string(Rest, [$" | Acc]);
parse_string(<<"\\\\", Rest/binary>>, Acc) ->
    parse_string(Rest, [$\\ | Acc]);
parse_string(<<"\\/", Rest/binary>>, Acc) ->
    parse_string(Rest, [$/ | Acc]);
parse_string(<<"\\b", Rest/binary>>, Acc) ->
    parse_string(Rest, [8 | Acc]);
parse_string(<<"\\f", Rest/binary>>, Acc) ->
    parse_string(Rest, [12 | Acc]);
parse_string(<<"\\n", Rest/binary>>, Acc) ->
    parse_string(Rest, [$\n | Acc]);
parse_string(<<"\\r", Rest/binary>>, Acc) ->
    parse_string(Rest, [$\r | Acc]);
parse_string(<<"\\t", Rest/binary>>, Acc) ->
    parse_string(Rest, [$\t | Acc]);
parse_string(<<"\\u", Hex:4/binary, Rest/binary>>, Acc) ->
    case catch binary_to_integer(Hex, 16) of
        Code when is_integer(Code) -> parse_string(Rest, [Code | Acc]);
        _ -> {error, invalid_unicode_escape}
    end;
parse_string(<<Char/utf8, Rest/binary>>, Acc) ->
    parse_string(Rest, [Char | Acc]);
parse_string(<<>>, _Acc) ->
    {error, unterminated_string}.

parse_number(Bin) ->
    {Number, Rest} = take_number(Bin, <<>>),
    case Number of
        <<>> ->
            {error, expected_value};
        _ ->
            parse_number_value(Number, Rest)
    end.

parse_number_value(Number, Rest) ->
    try
        case binary:match(Number, [<<".">>, <<"e">>, <<"E">>]) of
            nomatch -> {ok, binary_to_integer(Number), Rest};
            _ -> {ok, binary_to_float(Number), Rest}
        end
    catch
        _:_ -> {error, invalid_number}
    end.

take_number(<<Char, Rest/binary>>, Acc)
        when (Char >= $0 andalso Char =< $9);
             Char =:= $-; Char =:= $+; Char =:= $.; Char =:= $e; Char =:= $E ->
    take_number(Rest, <<Acc/binary, Char>>);
take_number(Rest, Acc) ->
    {Acc, Rest}.

skip_ws(<<Char, Rest/binary>>) when Char =:= 32; Char =:= 9; Char =:= 10; Char =:= 13 ->
    skip_ws(Rest);
skip_ws(Bin) ->
    Bin.
