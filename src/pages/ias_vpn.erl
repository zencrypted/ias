-module(ias_vpn).
-export([event/1, content/1, create_vpn_service/4]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    render();
event(create_vpn_service) ->
    Name = field_value(nitro:q(vpn_service_name), <<"OpenVPN">>),
    Host = field_value(nitro:q(vpn_remote_host), <<>>),
    Port = field_value(nitro:q(vpn_remote_port), <<"1194">>),
    Protocol = protocol_value(nitro:q(vpn_protocol)),
    Result = create_vpn_service(Name, Host, Port, Protocol),
    nitro:update(vpn_service_create_result, create_result(Result)),
    nitro:update(vpn_services_list, managed_services_panel());
event(_) ->
    ok.

render() ->
    logger:info("IAS VPN page init"),
    Summary = ias_vpn_runtime:summary(),
    logger:info("IAS VPN summary result: ~p", [summary_shape(Summary)]),
    nitro:clear(stand),
    nitro:insert_bottom(stand, content(Summary)).

content(Summary) ->
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("VPN")},
        #p{body = ias_html:text("VPN runtime status and manually managed VPN service definitions for IAS provisioning.")},
        create_service_panel(),
        #panel{id = vpn_services_list, body = managed_services_panel()},
        render_summary(Summary)
    ]}.

create_service_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Create VPN Service")},
        #p{style = <<"font-size:12px;margin:0 0 10px;color:#64748b;">>,
           body = ias_html:text("Creates a demo VPN service endpoint used later by OVPN export provisioning.")},
        input_row("Name", vpn_service_name, <<"OpenVPN">>),
        input_row("Remote Host", vpn_remote_host, <<"vpn.example.com">>),
        input_row("Remote Port", vpn_remote_port, <<"1194">>),
        protocol_row(),
        #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
               body = [
                   #link{id = vpn_create_service_button,
                         class = [button, sgreen],
                         body = ias_html:text("Create VPN Service"),
                         source = [vpn_service_name, vpn_remote_host, vpn_remote_port, vpn_protocol],
                         postback = create_vpn_service},
                   #span{style = <<"font-size:12px;color:#64748b;">>,
                         body = ias_html:text("Demo runtime object only. No VPN server is started.")}
               ]},
        #panel{id = vpn_service_create_result}
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

protocol_row() ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = vpn_protocol,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text("Protocol")},
               #select{id = vpn_protocol,
                       body = [
                           #option{value = <<"udp">>, selected = true, body = ias_html:text("udp")},
                           #option{value = <<"tcp">>, body = ias_html:text("tcp")}
                       ]}
           ]}.

create_vpn_service(_Name, <<>>, _Port, _Protocol) ->
    {error, <<"remote host is required">>};
create_vpn_service(Name, Host, Port, Protocol) ->
    Id = vpn_service_id(),
    Remote = ias_html:join([Host, <<":">>, normalize_port(Port)]),
    Service = ias_demo_store:add_service(#{
        id => Id,
        source => manual_vpn_service,
        import_id => Id,
        service => openvpn,
        name => Name,
        remote => Remote,
        remote_host => Host,
        remote_port => normalize_port(Port),
        protocol => Protocol,
        cipher => not_configured,
        compression => false,
        routes => 0
    }),
    {ok, Service}.

vpn_service_id() ->
    ias_html:join([<<"manual_vpn_service_">>, integer_to_binary(erlang:unique_integer([positive, monotonic]))]).

normalize_port(<<>>) ->
    <<"1194">>;
normalize_port(Port) ->
    ias_html:text(Port).

protocol_value(undefined) ->
    udp;
protocol_value(Value) ->
    case ias_html:text(Value) of
        <<"tcp">> -> tcp;
        <<"udp">> -> udp;
        _ -> udp
    end.

field_value(undefined, Default) ->
    Default;
field_value(<<>>, Default) ->
    Default;
field_value(Value, _Default) ->
    ias_html:text(Value).

create_result({ok, Service}) ->
    Id = maps:get(id, Service, undefined),
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("VPN service created")},
               key_value_table([
                   {"Service", maps:get(name, Service, <<"OpenVPN">>)},
                   {"Remote", maps:get(remote, Service, undefined)},
                   {"Protocol", maps:get(protocol, Service, undefined)},
                   {"Runtime", <<"demo state only">>}
               ]),
               #link{url = ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]),
                     style = <<"display:inline-block;margin-top:8px;padding:7px 10px;border:1px solid #93c5fd;border-radius:5px;background:#ffffff;color:#1d4ed8;text-decoration:none;font-size:12px;font-weight:600;">>,
                     body = ias_html:text("View Demo Object")}
           ]};
create_result({error, Reason}) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("VPN service was not created")},
               #p{body = ias_html:text(Reason)}
           ]}.

managed_services_panel() ->
    Records = ias_demo_store:services(),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Managed VPN Services")},
        managed_services(Records)
    ]}.

managed_services([]) ->
    #p{body = ias_html:text("No managed VPN services yet. Create one above or import an OVPN profile.")};
managed_services(Records) ->
    table([
        #table{class = <<"ias-table">>,
               header = header(["ID", "Service", "Remote", "Protocol", "Source"]),
               body = #tbody{body = [managed_service_row(Record) || Record <- Records]}}
    ]).

managed_service_row(Record) ->
    row([demo_link(maps:get(id, Record, undefined)),
         maps:get(name, Record, maps:get(service, Record, undefined)),
         maps:get(remote, Record, undefined),
         maps:get(protocol, Record, undefined),
         maps:get(source, Record, undefined)]).

demo_link(undefined) ->
    undefined;
demo_link(Id) ->
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
          body = TextId}.

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
        #h3{body = ias_html:text("VPN service unavailable")},
        #p{body = ias_html:text("IAS is running normally. VPN runtime status will appear when the VPN admin API is reachable.")}
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
    #panel{class = <<"ias-summary-item">>, body = ias_html:join([Label, ": ", Value])}.

peers_table([]) ->
    #panel{class = <<"ias-status-card">>, body = ias_html:text("No VPN peers reported.")};
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
    [#tr{cells = [#th{body = ias_html:text(Column)} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = cell_body(Value)} || Value <- Values]}.

cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

key_value_table(Rows) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [key_value_row(Label, Value) || {Label, Value} <- Rows]}}
    ]}.

key_value_row(Label, Value) ->
    #tr{cells = [
        #th{body = ias_html:text(Label)},
        #td{body = cell_body(Value)}
    ]}.

table(Body) ->
    #panel{class = <<"ias-table-container">>, body = Body}.
