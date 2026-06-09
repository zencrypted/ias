-module(ias_vpn).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    logger:info("IAS VPN page init"),
    Summary = ias_vpn_runtime:summary(),
    logger:info("IAS VPN summary result: ~p", [summary_shape(Summary)]),
    nitro:clear(stand),
    nitro:insert_bottom(stand, content(Summary));
event(_) ->
    ok.

content(Summary) ->
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "VPN"},
        #p{body = "Read-only VPN runtime status from the VPN admin API."},
        render_summary(Summary)
    ]}.

summary_shape({ok, Data}) when is_map(Data) ->
    Counts = ias_vpn_runtime:counts(Data),
    Peers = ias_vpn_runtime:peers(Data),
    {ok, #{counts => Counts, peers => length(Peers)}};
summary_shape({ok, Data}) ->
    {ok, Data};
summary_shape({error, Reason}) ->
    {error, Reason}.

render_summary({ok, Data}) when is_map(Data) ->
    Counts = ias_vpn_runtime:counts(Data),
    Peers = ias_vpn_runtime:peers(Data),
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
        summary("Running Peers", maps:get(<<"running">>, Counts, ias_vpn_runtime:running_count(Peers))),
        summary("Stopped Peers", maps:get(<<"stopped">>, Counts, ias_vpn_runtime:stopped_count(Peers))),
        summary("Certificates", maps:get(<<"certificates">>, Counts, 0))
    ]}.

summary(Label, undefined) ->
    #panel{class = <<"ias-summary-item">>, body = [Label, ": -"]};
summary(Label, Value) ->
    #panel{class = <<"ias-summary-item">>, body = [Label, ": ", value(Value)]}.

peers_table([]) ->
    #panel{class = <<"ias-status-card">>, body = "No VPN peers reported."};
peers_table(Peers) ->
    Devices = ias_demo_data:devices(),
    Profiles = ias_demo_data:profiles(),
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               header = header(["Peer", "State", "Profile", "Authorized", "Reason",
                                "Running", "Mode", "IP", "Remote Peer", "Trusted",
                                "Key Match", "Expires", "Crypto Failures", "Frames Rejected"]),
               body = #tbody{body = [peer_row(Peer, Devices, Profiles) || Peer <- Peers]}}
    ]}.

peer_row(Peer, Devices, Profiles) ->
    Policy = policy_decision(Peer, Devices, Profiles),
    row([ias_vpn_runtime:field(Peer, [peer, id, name]),
         ias_vpn_runtime:state(Peer),
         maps:get(profile_id, Policy, undefined),
         maps:get(authorized, Policy, false),
         maps:get(reason, Policy, undefined),
         ias_vpn_runtime:field(Peer, [<<"running">>, running, is_running, status]),
         ias_vpn_runtime:field(Peer, [mode]),
         ias_vpn_runtime:field(Peer, [ip, address]),
         ias_vpn_runtime:field(Peer, [remote_peer_id, remote_peer, remote]),
         ias_vpn_runtime:certificate_field(Peer, [trusted]),
         ias_vpn_runtime:certificate_field(Peer, [key_match]),
         ias_vpn_runtime:certificate_field(Peer, [not_after, expires, expires_at]),
         ias_vpn_runtime:field(Peer, [crypto_failures]),
         ias_vpn_runtime:field(Peer, [frames_rejected])]).

policy_decision(Peer, Devices, Profiles) ->
    PeerId = ias_vpn_runtime:field(Peer, [<<"id">>, id, peer, name]),
    ProfileId = profile_id(PeerId, Devices),
    Profile = profile(ProfileId, Profiles),
    (ias_policy:evaluate_vpn(Profile))#{profile_id => ProfileId}.

profile_id(undefined, _Devices) ->
    undefined;
profile_id(PeerId, Devices) ->
    case [Device || Device <- Devices,
                    maps:get(vpn_peer, Device, undefined) =:= PeerId] of
        [#{profile_id := ProfileId} | _] -> ProfileId;
        _ -> undefined
    end.

profile(undefined, _Profiles) ->
    #{};
profile(ProfileId, Profiles) ->
    case [Profile || Profile <- Profiles, maps:get(id, Profile) =:= ProfileId] of
        [Profile | _] -> Profile;
        [] -> #{}
    end.

header(Columns) ->
    [#tr{cells = [#th{body = Column} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = value(Value)} || Value <- Values]}.

%% TODO:
%% Replace local value conversion with shared ias_html:text/1.
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
