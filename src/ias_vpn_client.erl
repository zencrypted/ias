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
    try
        {ok, jiffy:decode(Body, [return_maps])}
    catch
        Class:Reason -> {error, {json_decode, Class, Reason}}
    end.
