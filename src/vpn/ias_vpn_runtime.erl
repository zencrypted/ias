-module(ias_vpn_runtime).
-export([summary/0,
         counts/1,
         peers/1,
         peer/2,
         running/1,
         state/1,
         running_count/1,
         stopped_count/1,
         field/2,
         certificate_field/2]).

summary() ->
    ias_vpn_client:summary().

counts({ok, Data}) ->
    counts(Data);
counts(Data) when is_map(Data) ->
    case maps:get(<<"counts">>, Data, #{}) of
        Counts when is_map(Counts) -> Counts;
        _ -> #{}
    end;
counts(_) ->
    #{}.

peers({ok, Data}) ->
    peers(Data);
peers(Data) when is_map(Data) ->
    case maps:get(<<"peers">>, Data, []) of
        Peers when is_list(Peers) -> [Peer || Peer <- Peers, is_map(Peer)];
        _ -> []
    end;
peers(_) ->
    [].

peer(undefined, _Summary) ->
    undefined;
peer(PeerId, Summary) ->
    case [Peer || Peer <- peers(Summary),
                  same_peer_id(field(Peer, [<<"id">>, id, peer, name]), PeerId)] of
        [Peer | _] -> Peer;
        [] -> undefined
    end.

same_peer_id(undefined, _PeerId) ->
    false;
same_peer_id(_Value, undefined) ->
    false;
same_peer_id(Value, PeerId) ->
    ias_html:text(Value) =:= ias_html:text(PeerId).

running(Peer) ->
    case field(Peer, [<<"running">>, running, is_running, status]) of
        true -> true;
        <<"running">> -> true;
        <<"up">> -> true;
        "running" -> true;
        "up" -> true;
        _ -> false
    end.

state(undefined) ->
    unavailable;
state(Peer) ->
    case running(Peer) of
        true -> running;
        false -> stopped
    end.

running_count(Peers) ->
    length([Peer || Peer <- Peers, running(Peer)]).

stopped_count(Peers) ->
    length(Peers) - running_count(Peers).

certificate_field(Peer, Keys) ->
    case field(Peer, [certificate]) of
        Certificate when is_map(Certificate) -> field(Certificate, Keys);
        _ -> field(Peer, Keys)
    end.

field(Map, Keys) when is_map(Map) ->
    field(Map, Keys, undefined);
field(_Value, _Keys) ->
    undefined.

field(_Map, [], Default) ->
    Default;
field(Map, [Key | Rest], Default) ->
    case lookup(Map, Key) of
        undefined -> field(Map, Rest, Default);
        Value -> Value
    end.

lookup(Map, Key) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> lookup_fallback(Map, Key)
    end.

lookup_fallback(Map, Key) when is_atom(Key) ->
    lookup_variants(Map, atom_to_binary(Key, utf8), atom_to_list(Key));
lookup_fallback(Map, Key) when is_binary(Key) ->
    lookup_variants(Map, binary_to_atom(Key, utf8), binary_to_list(Key));
lookup_fallback(_Map, _Key) ->
    undefined.

lookup_variants(Map, Key1, Key2) ->
    case maps:find(Key1, Map) of
        {ok, Value} -> Value;
        error ->
            case maps:find(Key2, Map) of
                {ok, Value} -> Value;
                error -> undefined
            end
    end.
