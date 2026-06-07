-module(ias_vpn).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "VPN"},
        #p{body = "Read-only VPN runtime status from the VPN admin API."},
        render_summary(ias_vpn_client:summary())
    ]}.

render_summary({ok, Data}) when is_map(Data) ->
    Counts = vpn_counts(Data),
    Peers = vpn_peers(Data),
    [
        counters(Counts, Peers),
        peers_table(Peers)
    ];
render_summary({ok, _Data}) ->
    unavailable();
render_summary({error, _Reason}) ->
    unavailable().

unavailable() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = "VPN service unavailable"},
        #p{body = "IAS is running normally. VPN runtime status will appear when the VPN admin API is reachable."}
    ]}.

counters(Counts, Peers) ->
    #panel{class = <<"ias-summary">>, body = [
        summary("Configured Peers", maps:get(<<"configured">>, Counts, length(Peers))),
        summary("Running Peers", maps:get(<<"running">>, Counts, running_count(Peers))),
        summary("Stopped Peers", maps:get(<<"stopped">>, Counts, stopped_count(Peers))),
        summary("Certificates", maps:get(<<"certificates">>, Counts, 0))
    ]}.

summary(Label, undefined) ->
    #panel{class = <<"ias-summary-item">>, body = [Label, ": -"]};
summary(Label, Value) ->
    #panel{class = <<"ias-summary-item">>, body = [Label, ": ", value(Value)]}.

peers_table([]) ->
    #panel{class = <<"ias-status-card">>, body = "No VPN peers reported."};
peers_table(Peers) ->
    #table{class = <<"ias-table">>,
           header = header(["Peer", "Running", "Mode", "IP", "Remote Peer", "Trusted",
                            "Key Match", "Expires", "Crypto Failures", "Frames Rejected"]),
           body = #tbody{body = [peer_row(Peer) || Peer <- Peers]}}.

peer_row(Peer) ->
    row([field(Peer, [peer, id, name]),
         field(Peer, [<<"running">>, running, is_running, status]),
         field(Peer, [mode]),
         field(Peer, [ip, address]),
         field(Peer, [remote_peer_id, remote_peer, remote]),
         certificate_field(Peer, [trusted]),
         certificate_field(Peer, [key_match]),
         certificate_field(Peer, [not_after, expires, expires_at]),
         field(Peer, [crypto_failures]),
         field(Peer, [frames_rejected])]).

header(Columns) ->
    [#tr{cells = [#th{body = Column} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = value(Value)} || Value <- Values]}.

vpn_counts(Data) ->
    case maps:get(<<"counts">>, Data, #{}) of
        Counts when is_map(Counts) -> Counts;
        _ -> #{}
    end.

vpn_peers(Data) ->
    case maps:get(<<"peers">>, Data, []) of
        Peers when is_list(Peers) -> [Peer || Peer <- Peers, is_map(Peer)];
        _ -> []
    end.

running_count(Peers) ->
    length([Peer || Peer <- Peers, running(Peer)]).

stopped_count(Peers) ->
    length(Peers) - running_count(Peers).

running(Peer) ->
    case field(Peer, [<<"running">>, running, is_running, status]) of
        true -> true;
        <<"running">> -> true;
        <<"up">> -> true;
        "running" -> true;
        "up" -> true;
        _ -> false
    end.

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

value(undefined) ->
    "-";
value(true) ->
    "yes";
value(false) ->
    "no";
value(Value) when is_atom(Value) ->
    atom_to_list(Value);
value(Value) when is_integer(Value) ->
    integer_to_list(Value);
value(Value) when is_float(Value) ->
    io_lib:format("~p", [Value]);
value(Value) ->
    Value.
