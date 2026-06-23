-module(ias_vpn).
-export([event/1, content/1, create_vpn_service/4, create_vpn_service/6,
         runtime_status_panel/1, runtime_summary_panel/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    render();
event(refresh_vpn_runtime) ->
    Summary = ias_vpn_runtime:summary(),
    nitro:update(vpn_runtime_refresh_status, runtime_status_panel(Summary)),
    nitro:update(vpn_runtime_summary, runtime_summary_panel(Summary)),
    nitro:wire(<<"window.iasVpnRefreshBusy=false;">>);
event(create_vpn_service) ->
    Name = field_value(nitro:q(vpn_service_name), <<"OpenVPN">>),
    Host = field_value(nitro:q(vpn_remote_host), <<>>),
    Port = field_value(nitro:q(vpn_remote_port), <<"1194">>),
    Protocol = protocol_value(nitro:q(vpn_protocol)),
    PolicyId = optional_value(nitro:q(vpn_security_policy)),
    CaCertificateId = optional_value(nitro:q(vpn_ca_certificate)),
    Result = create_vpn_service(Name, Host, Port, Protocol, PolicyId, CaCertificateId),
    nitro:update(vpn_service_create_result, create_result(Result)),
    nitro:update(vpn_services_list, managed_services_panel());
event(_) ->
    ok.

render() ->
    logger:info("IAS VPN page init"),
    Summary = ias_vpn_runtime:summary(),
    logger:info("IAS VPN summary result: ~p", [summary_shape(Summary)]),
    nitro:clear(stand),
    nitro:insert_bottom(stand, content(Summary)),
    nitro:wire(auto_refresh_js()).

content(Summary) ->
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("VPN")},
        #p{body = ias_html:text("VPN runtime status and manually managed VPN service definitions for IAS provisioning.")},
        create_service_panel(),
        #panel{id = vpn_services_list, body = managed_services_panel()},
        runtime_refresh_controls(Summary),
        runtime_summary_panel(Summary)
    ]}.

runtime_refresh_controls(Summary) ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:12px 0 8px;">>,
           body = [
               runtime_status_panel(Summary),
               #link{id = vpn_runtime_refresh_now,
                     class = [button, sgreen],
                     body = ias_html:text("Refresh now"),
                     postback = refresh_vpn_runtime},
               #link{id = vpn_runtime_auto_refresh,
                     style = <<"display:none;">>,
                     body = ias_html:text("Auto refresh VPN runtime"),
                     postback = refresh_vpn_runtime}
           ]}.

runtime_status_panel(Summary) ->
    #panel{id = vpn_runtime_refresh_status,
           style = <<"font-size:12px;color:#64748b;">>,
           body = refresh_status(Summary)}.

runtime_summary_panel(Summary) ->
    #panel{id = vpn_runtime_summary, body = render_summary(Summary)}.

refresh_status({ok, Data}) when is_map(Data) ->
    ias_html:join([<<"Runtime: connected | Last update: ">>,
                   utc_time_text(),
                   <<" UTC | Auto-refresh: 2s">>]);
refresh_status(_) ->
    ias_html:join([<<"Runtime: unavailable | Last attempt: ">>,
                   utc_time_text(),
                   <<" UTC | Auto-refresh: 2s">>]).

utc_time_text() ->
    {{_Year, _Month, _Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    iolist_to_binary(io_lib:format("~2..0B:~2..0B:~2..0B", [Hour, Minute, Second])).

auto_refresh_js() ->
    <<"if(window.iasVpnRefreshTimer){clearInterval(window.iasVpnRefreshTimer);}",
      "window.iasVpnRefreshBusy=false;",
      "window.iasVpnRefreshTimer=setInterval(function(){",
      "if(document.hidden||window.iasVpnRefreshBusy){return;}",
      "var refresh=document.getElementById('vpn_runtime_auto_refresh');",
      "if(refresh){window.iasVpnRefreshBusy=true;refresh.click();}",
      "},2000);">>.

create_service_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Create VPN Service")},
        #p{style = <<"font-size:12px;margin:0 0 10px;color:#64748b;">>,
           body = ias_html:text("Creates a demo VPN service endpoint used later by OVPN export provisioning.")},
        input_row("Name", vpn_service_name, <<"OpenVPN">>),
        input_row("Remote Host", vpn_remote_host, <<"vpn.example.com">>),
        input_row("Remote Port", vpn_remote_port, <<"1194">>),
        protocol_row(),
        security_policy_row(),
        ca_certificate_row(),
        #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
               body = [
                   #link{id = vpn_create_service_button,
                         class = [button, sgreen],
                         body = ias_html:text("Create VPN Service"),
                         source = [vpn_service_name, vpn_remote_host, vpn_remote_port, vpn_protocol,
                                   vpn_security_policy, vpn_ca_certificate],
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

security_policy_row() ->
    select_row("Security Policy", vpn_security_policy,
               [#option{value = <<"">>, body = ias_html:text("not linked yet")}
                | [#option{value = maps:get(id, Policy),
                           body = ias_html:join([maps:get(name, Policy, maps:get(id, Policy)),
                                                 <<" (#">>, maps:get(id, Policy), <<")">>])}
                   || Policy <- ias_demo_store:security_policies()]]).

ca_certificate_row() ->
    select_row("CA Certificate", vpn_ca_certificate,
               [#option{value = <<"">>, body = ias_html:text("not linked yet")}
                | [#option{value = maps:get(id, Certificate),
                           body = ias_html:join([certificate_class_label(Certificate), <<" #">>,
                                                 maps:get(id, Certificate)])}
                   || Certificate <- ias_demo_store:certificates()]]).

select_row(Label, Id, Options) ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = Id,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text(Label)},
               #select{id = Id,
                       style = <<"min-width:260px;max-width:420px;width:100%;">>,
                       body = Options}
           ]}.

certificate_class_label(Certificate) ->
    ias_certificate_detail:certificate_class(Certificate).

create_vpn_service(Name, Host, Port, Protocol) ->
    create_vpn_service(Name, Host, Port, Protocol, not_linked, not_linked).

create_vpn_service(_Name, <<>>, _Port, _Protocol, _PolicyId, _CaCertificateId) ->
    {error, <<"remote host is required">>};
create_vpn_service(Name, Host, Port, Protocol, PolicyId, CaCertificateId) ->
    Id = vpn_service_id(),
    Remote = ias_html:join([Host, <<":">>, normalize_port(Port)]),
    Service0 = ias_demo_store:add_service(#{
        id => Id,
        source => manual_vpn_service,
        import_id => Id,
        service => openvpn,
        name => Name,
        remote => Remote,
        remote_host => Host,
        remote_port => normalize_port(Port),
        protocol => Protocol,
        ca_certificate_id => metadata_id(CaCertificateId),
        security_policy_id => metadata_id(PolicyId),
        cipher => not_configured,
        compression => false,
        routes => 0
    }),
    ok = maybe_link(uses_security_policy, Id, PolicyId),
    ok = maybe_link(uses_ca_certificate, Id, CaCertificateId),
    {ok, Service0}.

vpn_service_id() ->
    ias_html:join([<<"manual_vpn_service_">>, integer_to_binary(erlang:unique_integer([positive, monotonic]))]).

normalize_port(<<>>) ->
    <<"1194">>;
normalize_port(Port) ->
    ias_html:text(Port).

optional_value(undefined) ->
    not_linked;
optional_value(<<>>) ->
    not_linked;
optional_value(Value) ->
    ias_html:text(Value).

metadata_id(not_linked) ->
    not_linked;
metadata_id(Value) ->
    ias_html:text(Value).

maybe_link(_RelationType, _SourceId, not_linked) ->
    ok;
maybe_link(RelationType, SourceId, TargetId) ->
    case ias_relationship_link:create(RelationType, SourceId, TargetId) of
        {ok, _Relationship} -> ok;
        {error, _Reason} -> ok
    end.

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
                   {"Security Policy", maps:get(security_policy_id, Service, not_linked)},
                   {"CA Certificate", maps:get(ca_certificate_id, Service, not_linked)},
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
               header = header(["ID", "Service", "Remote", "Protocol", "Security Policy", "CA Certificate", "Source"]),
               body = #tbody{body = [managed_service_row(Record) || Record <- Records]}}
    ]).

managed_service_row(Record) ->
    row([demo_link(maps:get(id, Record, undefined)),
         maps:get(name, Record, maps:get(service, Record, undefined)),
         maps:get(remote, Record, undefined),
         maps:get(protocol, Record, undefined),
         linked_policy_label(Record),
         linked_ca_label(Record),
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
    case authorization_mode(Peer) of
        development_bypass ->
            #{profile_id => undefined,
              authorized => runtime_authorized(Peer),
              reason => runtime_authorization_reason(Peer),
              authorization_mode => development_bypass};
        policy ->
            PeerId = ias_vpn_runtime:field(Peer, [<<"id">>, id, peer, name]),
            ProfileId = profile_id(PeerId, Devices),
            Profile = profile(ProfileId, Profiles),
            (ias_policy:evaluate_vpn(Profile))#{profile_id => ProfileId,
                                                authorization_mode => policy}
    end.

authorization_mode(Peer) ->
    case ias_vpn_runtime:field(Peer, [authorization_mode]) of
        development_bypass -> development_bypass;
        <<"development_bypass">> -> development_bypass;
        "development_bypass" -> development_bypass;
        _ -> policy
    end.

runtime_authorized(Peer) ->
    case ias_vpn_runtime:field(Peer, [authorized]) of
        true -> true;
        <<"true">> -> true;
        "true" -> true;
        _ -> false
    end.

runtime_authorization_reason(Peer) ->
    case ias_vpn_runtime:field(Peer, [authorization_reason]) of
        undefined -> <<"development bypass">>;
        null -> <<"development bypass">>;
        development_bypass -> <<"development bypass">>;
        <<"development_bypass">> -> <<"development bypass">>;
        "development_bypass" -> <<"development bypass">>;
        Reason -> Reason
    end.

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


linked_policy_label(Service) ->
    linked_target_label(Service, uses_security_policy, security_policy).

linked_ca_label(Service) ->
    linked_target_label(Service, uses_ca_certificate, certificate).

linked_target_label(Service, RelationType, TargetKind) ->
    ServiceId = maps:get(id, Service, undefined),
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_demo_store:relationships(),
             maps:get(relation_type, Relationship, undefined) =:= RelationType,
             maps:get(source_kind, Relationship, undefined) =:= vpn_service,
             maps:get(source_id, Relationship, undefined) =:= ServiceId,
             maps:get(target_kind, Relationship, undefined) =:= TargetKind] of
        [TargetId | _] -> TargetId;
        [] -> maps:get(linked_metadata_key(RelationType), Service, not_linked)
    end.

linked_metadata_key(uses_security_policy) -> security_policy_id;
linked_metadata_key(uses_ca_certificate) -> ca_certificate_id;
linked_metadata_key(_RelationType) -> undefined.
