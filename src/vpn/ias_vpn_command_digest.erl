%%%-------------------------------------------------------------------
%% @doc Portable integrity digest for durable IAS VPN authority commands.
%%
%% The canonical encoding is deliberately independent of Erlang's external
%% term format so authority records remain verifiable across OTP major
%% releases. Command revisions are stored separately and are excluded from the
%% digest just as they were by the legacy format.
%%%-------------------------------------------------------------------
-module(ias_vpn_command_digest).

-export([schema_version/0,
         digest/1,
         legacy_digest/1,
         canonical_binary/1]).

-define(SCHEMA_VERSION, 2).

schema_version() ->
    ?SCHEMA_VERSION.

digest(Command) when is_map(Command) ->
    crypto:hash(sha256,
                canonical_binary(maps:remove(revision, Command))).

legacy_digest(Command) when is_map(Command) ->
    crypto:hash(sha256,
                term_to_binary(maps:remove(revision, Command),
                               [deterministic])).

canonical_binary(Term) ->
    iolist_to_binary(encode(Term)).

encode(Term) when is_atom(Term) ->
    value($a, atom_to_binary(Term, utf8));
encode(Term) when is_binary(Term) ->
    value($b, Term);
encode(Term) when is_bitstring(Term) ->
    BitSize = bit_size(Term),
    Padding = (8 - (BitSize rem 8)) rem 8,
    Padded = <<Term/bitstring, 0:Padding>>,
    value($B, [unsigned(BitSize), Padded]);
encode(Term) when is_integer(Term) ->
    value($i, integer_to_binary(Term));
encode(Term) when is_float(Term) ->
    value($f, <<Term:64/float>>);
encode([]) ->
    <<$l, 0:64/unsigned-big>>;
encode(Term) when is_list(Term) ->
    encode_list(Term);
encode(Term) when is_tuple(Term) ->
    Items = [encode(Item) || Item <- tuple_to_list(Term)],
    sequence($t, tuple_size(Term), Items);
encode(Term) when is_map(Term) ->
    Entries0 =
        [{iolist_to_binary(encode(Key)), encode(Value)}
         || {Key, Value} <- maps:to_list(Term)],
    Entries = lists:keysort(1, Entries0),
    Encoded = [[value($k, KeyBin), value($v, ValueEncoding)]
               || {KeyBin, ValueEncoding} <- Entries],
    sequence($m, map_size(Term), Encoded);
encode(Term) ->
    erlang:error({unsupported_canonical_term, term_kind(Term)}).

encode_list(Term) ->
    case proper_list(Term, []) of
        {proper, Items} ->
            Encoded = [encode(Item) || Item <- Items],
            sequence($l, length(Items), Encoded);
        {improper, Heads, Tail} ->
            EncodedHeads = [encode(Item) || Item <- Heads],
            sequence($L,
                     length(Heads),
                     [EncodedHeads, value($d, encode(Tail))])
    end.

proper_list([], Acc) ->
    {proper, lists:reverse(Acc)};
proper_list([Head | Tail], Acc) ->
    proper_list(Tail, [Head | Acc]);
proper_list(Tail, Acc) ->
    {improper, lists:reverse(Acc), Tail}.

sequence(Tag, Count, Items) ->
    [<<Tag>>, unsigned(Count), [framed(Item) || Item <- Items]].

value(Tag, Payload) ->
    [<<Tag>>, framed(Payload)].

framed(Payload) ->
    Size = iolist_size(Payload),
    [unsigned(Size), Payload].

unsigned(Value) when is_integer(Value), Value >= 0 ->
    <<Value:64/unsigned-big>>.

term_kind(Term) when is_pid(Term) -> pid;
term_kind(Term) when is_port(Term) -> port;
term_kind(Term) when is_reference(Term) -> reference;
term_kind(Term) when is_function(Term) -> function;
term_kind(_Term) -> unsupported.
