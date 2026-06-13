-module(ias_ovpn_preview).
-export([analyze/1]).

analyze(Input) ->
    Text = input_text(Input),
    #{detected => detected(Text),
      lines => line_count(Text),
      has_ca => has_block(Text, <<"ca">>),
      has_cert => has_block(Text, <<"cert">>),
      has_key => has_block(Text, <<"key">>),
      remote_host => remote_host(Text),
      remote_port => remote_port(Text),
      proto => first_directive_value(Text, <<"proto">>),
      dev => first_directive_value(Text, <<"dev">>),
      route_count => route_count(Text),
      tls_auth => directive_exists(Text, <<"tls-auth">>),
      cipher => first_directive_value(Text, <<"cipher">>),
      compression => directive_exists(Text, <<"comp-lzo">>)}.

input_text(undefined) ->
    <<>>;
input_text(Value) ->
    ias_html:text(Value).

detected(Text) ->
    has_directive_line(Text) orelse has_any_inline_block(Text).

has_directive_line(Text) ->
    nomatch =/= re:run(Text, <<"(?im)^\\s*(remote|proto|dev|client)(\\s|$)">>,
                       [{capture, none}]).

remote_host(Text) ->
    case remote_parts(Text) of
        [Host | _] -> Host;
        _ -> not_found
    end.

remote_port(Text) ->
    port_value(case remote_parts(Text) of
        [_Host, Port | _] -> Port;
        _ -> first_directive_value(Text, <<"port">>)
    end).

port_value(not_found) ->
    not_found;
port_value(Port) ->
    case string:to_integer(binary_to_list(ias_html:text(Port))) of
        {Integer, ""} -> Integer;
        _ -> Port
    end.

remote_parts(Text) ->
    case first_directive_parts(Text, <<"remote">>) of
        not_found -> [];
        Parts -> Parts
    end.

first_directive_value(Text, Directive) ->
    case first_directive_parts(Text, Directive) of
        [Value | _] -> Value;
        _ -> not_found
    end.

first_directive_parts(Text, Directive) ->
    Lines = binary:split(normalize_newlines(Text), <<"\n">>, [global]),
    first_directive_parts_from_lines(Lines, Directive).

first_directive_parts_from_lines([], _Directive) ->
    not_found;
first_directive_parts_from_lines([Line | Rest], Directive) ->
    case directive_parts(Line, Directive) of
        not_found -> first_directive_parts_from_lines(Rest, Directive);
        Parts -> Parts
    end.

directive_parts(Line, Directive) ->
    Clean = strip_inline_comment(Line),
    Parts = binary:split(string:trim(Clean), <<" ">>, [global, trim_all]),
    case Parts of
        [Directive | Values] when Values =/= [] -> Values;
        _ -> not_found
    end.

strip_inline_comment(Line) ->
    hd(binary:split(Line, <<"#">>)).

route_count(Text) ->
    Lines = binary:split(normalize_newlines(Text), <<"\n">>, [global]),
    length([Line || Line <- Lines, directive_parts(Line, <<"route">>) =/= not_found]).

directive_exists(Text, Directive) ->
    Lines = binary:split(normalize_newlines(Text), <<"\n">>, [global]),
    lists:any(fun(Line) -> directive_present(Line, Directive) end, Lines).

directive_present(Line, Directive) ->
    Clean = strip_inline_comment(Line),
    Parts = binary:split(string:trim(Clean), <<" ">>, [global, trim_all]),
    case Parts of
        [Directive | _] -> true;
        _ -> false
    end.

has_any_inline_block(Text) ->
    has_block(Text, <<"ca">>) orelse has_block(Text, <<"cert">>) orelse
        has_block(Text, <<"key">>).

has_block(Text, Tag) ->
    Lower = lowercase(Text),
    Open = ias_html:join([<<"<">>, Tag, <<">">>]),
    Close = ias_html:join([<<"</">>, Tag, <<">">>]),
    binary:match(Lower, Open) =/= nomatch andalso
        binary:match(Lower, Close) =/= nomatch.

lowercase(Text) ->
    unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(Text))).

line_count(<<>>) ->
    0;
line_count(Text) ->
    Normalized = trim_trailing_newlines(normalize_newlines(Text)),
    case Normalized of
        <<>> -> 0;
        _ -> length(binary:split(Normalized, <<"\n">>, [global]))
    end.

normalize_newlines(Text) ->
    binary:replace(Text, <<"\r\n">>, <<"\n">>, [global]).

trim_trailing_newlines(<<>>) ->
    <<>>;
trim_trailing_newlines(Text) ->
    Size = byte_size(Text),
    case Text of
        <<Prefix:(Size - 1)/binary, "\n">> ->
            trim_trailing_newlines(Prefix);
        _ ->
            Text
    end.
