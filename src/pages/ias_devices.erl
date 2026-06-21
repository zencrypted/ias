-module(ias_devices).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(create_demo_device) ->
    Fields = #{name => nitro:q(device_name),
               type => nitro:q(device_type),
               tunnel_device => nitro:q(device_tunnel_device),
               transport => nitro:q(device_transport),
               endpoint => nitro:q(device_endpoint)},
    Result = ias_manual_device:create(Fields),
    nitro:update(device_create_result, create_device_result(Result)),
    nitro:update(device_runtime_objects, imported_demo_objects());
event(_) ->
    ok.

content() ->
    Devices = ias_demo_data:devices(),
    VpnSummary = ias_vpn_runtime:summary(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Devices")},
        #p{body = ias_html:text("Track endpoints and devices that will participate in IAS policies.")},
        #h3{body = count("Devices", Devices)},
        table([
            #table{class = <<"ias-table">>,
                   header = header(["Device", "Security Profile", "VPN Peer", "Peer IP",
                                    "State", "Remote Peer"]),
                   body = #tbody{body =
                       [device_row(Device, VpnSummary)
                        || Device <- Devices]}}
        ]),
        create_demo_device_panel(),
        #panel{id = device_runtime_objects, body = imported_demo_objects()}
    ]}.

create_demo_device_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Create Demo Device")},
        #p{style = <<"font-size:12px;margin:0 0 10px;color:#64748b;">>,
           body = ias_html:text("Creates a volatile demo runtime Device. Relationships are linked separately.")},
        input_row("Device Name", device_name, <<"">>),
        input_row("Device Type", device_type, <<"vpn-client">>),
        input_row("Tunnel Device", device_tunnel_device, <<"tun">>),
        transport_row(),
        input_row("Endpoint", device_endpoint, <<"">>),
        #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
               body = [
                   #link{id = device_create_button,
                         class = [button, sgreen],
                         body = ias_html:text("Create Device"),
                         source = [device_name, device_type, device_tunnel_device,
                                   device_transport, device_endpoint],
                         postback = create_demo_device},
                   #span{style = <<"font-size:12px;color:#64748b;">>,
                         body = ias_html:text("Demo runtime object only. No enrollment, keys, CSR or VPN connection is created.")}
               ]},
        #panel{id = device_create_result}
    ]}.

input_row(Label, Id, Value) ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = Id,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text(Label)},
               #input{id = Id,
                      type = <<"text">>,
                      value = ias_html:text(Value),
                      style = <<"min-width:260px;max-width:420px;width:100%;">>}
           ]}.

transport_row() ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = device_transport,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text("Transport")},
               #select{id = device_transport,
                       style = <<"min-width:260px;max-width:420px;width:100%;">>,
                       body = [
                           #option{value = <<"udp">>, selected = true, body = ias_html:text("udp")},
                           #option{value = <<"tcp">>, body = ias_html:text("tcp")}
                       ]}
           ]}.

create_device_result({ok, Device}) ->
    Id = maps:get(id, Device, undefined),
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Demo device created")},
               key_value_table([
                   {"Device", demo_link(Id)},
                   {"Source", maps:get(source, Device, undefined)},
                   {"Type", maps:get(type, Device, undefined)}
               ])
           ]};
create_device_result({error, Reason}) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;color:#991b1b;">>,
           body = [
               #h3{body = ias_html:text("Device was not created")},
               #p{body = ias_html:text(Reason)}
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
    [#tr{cells = [#th{body = ias_html:text(Column)} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = cell_body(Value)} || Value <- Values]}.

cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

imported_demo_objects() ->
    Records = ias_demo_store:devices(),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Runtime Demo Objects")},
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

key_value_table(Rows) ->
    table([
        #table{class = <<"ias-table">>,
               body = #tbody{body = [key_value_row(Label, Value) || {Label, Value} <- Rows]}}
    ]).

key_value_row(Label, Value) ->
    #tr{cells = [
        #th{body = ias_html:text(Label)},
        #td{body = cell_body(Value)}
    ]}.

table(Body) ->
    #panel{class = <<"ias-table-container">>, body = Body}.

count(Label, Rows) ->
    ias_html:join([Label, ": ", integer_to_list(length(Rows))]).

id(Map) ->
    maps:get(id, Map).
