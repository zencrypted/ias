-module(ias_html).
-export([text/1, join/1, join_csv/1]).

text(Value) when is_binary(Value) ->
    Value;
text(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
text(Value) when is_integer(Value) ->
    integer_to_binary(Value);
text(Value) when is_list(Value) ->
    case is_charlist(Value) of
        true -> unicode:characters_to_binary(Value);
        false -> join(Value)
    end.

join(Parts) when is_list(Parts) ->
    iolist_to_binary([text(Part) || Part <- Parts]);
join(Value) ->
    text(Value).

join_csv([]) ->
    <<"-">>;
join_csv(Values) ->
    join_csv(Values, []).

join_csv([], Acc) ->
    iolist_to_binary(lists:reverse(Acc));
join_csv([Value], Acc) ->
    join_csv([], [text(Value) | Acc]);
join_csv([Value | Rest], Acc) ->
    join_csv(Rest, [<<", ">>, text(Value) | Acc]).

is_charlist([]) ->
    true;
is_charlist([Char | Rest]) when is_integer(Char), Char >= 0 ->
    is_charlist(Rest);
is_charlist(_) ->
    false.
