-module(ias_ovpn_preview).
-export([analyze/1]).

analyze(Input) ->
    Text = input_text(Input),
    #{detected => detected(Text),
      lines => line_count(Text),
      has_ca => has_block(Text, <<"ca">>),
      has_cert => has_block(Text, <<"cert">>),
      has_key => has_block(Text, <<"key">>)}.

input_text(undefined) ->
    <<>>;
input_text(Value) ->
    ias_html:text(Value).

detected(Text) ->
    has_directive_line(Text) orelse has_any_inline_block(Text).

has_directive_line(Text) ->
    nomatch =/= re:run(Text, <<"(?im)^\\s*(remote|proto|dev|client)(\\s|$)">>,
                       [{capture, none}]).

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
