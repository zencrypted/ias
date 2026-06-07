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
        body(ias_vpn_client:summary())
    ]}.

body({ok, Data}) ->
    Peers = peers(Data),
    [
        counters(Data, Peers),
        peers_table(Peers)
    ];
body({error, _Reason}) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = "VPN service unavailable"},
        #p{body = "IAS is running normally. VPN runtime status will appear when the VPN admin API is reachable."}
    ]}.

counters(Data, Peers) ->
    #panel{class = <<"ias-summary">>, body = [
        summary("Configured Peers", metric(Data, [configured_peers, configured, peers_total], length(Peers))),
        summary("Running Peers", metric(Data, [running_peers, running], running_count(Peers))),
        summary("Stopped Peers", metric(Data, [stopped_peers, stopped], stopped_count(Peers))),
        summary("Certificates", metric(Data, [certificates, certificate_count], undefined))
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
         field(Peer, [running, is_running, status]),
         field(Peer, [mode]),
         field(Peer, [ip, address]),
         field(Peer, [remote_peer, remote]),
         field(Peer, [trusted]),
         field(Peer, [key_match]),
         field(Peer, [expires, expires_at]),
         field(Peer, [crypto_failures]),
         field(Peer, [frames_rejected])]).

header(Columns) ->
    [#tr{cells = [#th{body = Column} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = value(Value)} || Value <- Values]}.

peers(Data) ->
    case field(Data, [peers, configured_peers_list, peer_status]) of
        Peers when is_list(Peers) -> [Peer || Peer <- Peers, is_map(Peer)];
        _ -> []
    end.

metric(Data, Keys, Default) ->
    case field(Data, Keys) of
        undefined -> Default;
        Value -> Value
    end.

running_count(Peers) ->
    length([Peer || Peer <- Peers, running(Peer)]).

stopped_count(Peers) ->
    length(Peers) - running_count(Peers).

running(Peer) ->
    case field(Peer, [running, is_running, status]) of
        true -> true;
        <<"running">> -> true;
        <<"up">> -> true;
        "running" -> true;
        "up" -> true;
        _ -> false
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
    Binary = atom_to_binary(Key, utf8),
    String = atom_to_list(Key),
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error ->
            case maps:find(Binary, Map) of
                {ok, Value} -> Value;
                error ->
                    case maps:find(String, Map) of
                        {ok, Value} -> Value;
                        error -> undefined
                    end
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
