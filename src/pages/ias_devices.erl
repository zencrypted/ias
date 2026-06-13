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
        table([
            #table{class = <<"ias-table">>,
                   header = header(["Device", "Security Profile", "VPN Peer", "Peer IP",
                                    "State", "Remote Peer"]),
                   body = #tbody{body =
                       [device_row(Device, VpnSummary)
                        || Device <- Devices]}}
        ]),
        imported_demo_objects()
    ]}.

device_row(Device, VpnSummary) ->
    PeerId = maps:get(vpn_peer, Device, undefined),
    Peer = ias_vpn_runtime:peer(PeerId, VpnSummary),
    row([id(Device),
         maps:get(profile_id, Device, undefined),
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
    #tr{cells = [#td{body = cell_body(Value)} || Value <- Values]}.

cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

imported_demo_objects() ->
    Records = ias_demo_store:devices(),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Imported Demo Objects")},
        imported_devices(Records)
    ]}.

imported_devices([]) ->
    #p{body = ias_html:text("No imported demo objects yet.")};
imported_devices(Records) ->
    table([
        #table{class = <<"ias-table">>,
               header = header(["ID", "Type", "Endpoint", "Transport", "Tunnel Device",
                                "Source", "Import ID"]),
               body = #tbody{body = [imported_device_row(Record) || Record <- Records]}}
    ]).

imported_device_row(Record) ->
    row([demo_link(maps:get(id, Record, undefined)),
         maps:get(type, Record, undefined),
         maps:get(endpoint, Record, undefined),
         maps:get(transport, Record, undefined),
         maps:get(tunnel_device, Record, undefined),
         maps:get(source, Record, undefined),
         maps:get(import_id, Record, undefined)]).

demo_link(undefined) ->
    undefined;
demo_link(Id) ->
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
          body = TextId}.

table(Body) ->
    #panel{class = <<"ias-table-container">>, body = Body}.

count(Label, Rows) ->
    [Label, ": ", integer_to_list(length(Rows))].

id(Map) ->
    maps:get(id, Map).
