-module(ias_devices).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    Devices = ias_demo_data:devices(),
    VpnSummary = ias_vpn_runtime:summary(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Devices"},
        #p{body = "Track endpoints and devices that will participate in IAS policies."},
        #h3{body = count("Devices", Devices)},
        #table{class = <<"ias-table">>,
               header = header(["Device", "VPN Peer", "Peer IP", "State", "Remote Peer"]),
               body = #tbody{body =
                   [device_row(Device, VpnSummary)
                    || Device <- Devices]}}
    ]}.

device_row(Device, VpnSummary) ->
    PeerId = maps:get(vpn_peer, Device, undefined),
    Peer = ias_vpn_runtime:peer(PeerId, VpnSummary),
    row([id(Device),
         peer_id(PeerId),
         peer_field(Peer, [ip, address]),
         peer_state(PeerId, Peer, VpnSummary),
         peer_field(Peer, [remote_peer_id, remote_peer, remote])]).

peer_id(undefined) ->
    "-";
peer_id(PeerId) ->
    PeerId.

peer_field(undefined, _Keys) ->
    "-";
peer_field(Peer, Keys) ->
    ias_vpn_runtime:field(Peer, Keys).

peer_state(undefined, _Peer, _VpnSummary) ->
    "-";
peer_state(_PeerId, _Peer, {error, _Reason}) ->
    unavailable;
peer_state(_PeerId, undefined, _VpnSummary) ->
    unknown;
peer_state(_PeerId, Peer, _VpnSummary) ->
    ias_vpn_runtime:state(Peer).

header(Columns) ->
    [#tr{cells = [#th{body = Column} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = value(Value)} || Value <- Values]}.

count(Label, Rows) ->
    [Label, ": ", integer_to_list(length(Rows))].

id(Map) ->
    maps:get(id, Map).

value(Value) when is_atom(Value) ->
    atom_to_list(Value);
value(Value) when is_integer(Value) ->
    integer_to_list(Value);
value(Value) ->
    Value.
