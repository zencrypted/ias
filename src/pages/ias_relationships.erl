-module(ias_relationships).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    Users = ias_demo_data:users(),
    Devices = ias_demo_data:devices(),
    Certificates = ias_demo_data:certificates(),
    Services = ias_demo_data:services(),
    VpnSummary = ias_vpn_client:summary(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Relationships"},
        #p{body = "User to device, certificate and service relationships."},
        counters(Users, Devices, Certificates, Services),
        #panel{class = <<"ias-relationship-tree">>,
               body = hierarchy(Users, Devices, Certificates, Services, VpnSummary)}
    ]}.

counters(Users, Devices, Certificates, Services) ->
    #panel{class = <<"ias-summary">>, body = [
        summary("Users", Users),
        summary("Devices", Devices),
        summary("Certificates", Certificates),
        summary("Services", Services)
    ]}.

summary(Label, Rows) ->
    #panel{class = <<"ias-summary-item">>,
           body = [Label, ": ", integer_to_list(length(Rows))]}.

hierarchy(Users, Devices, Certificates, Services, VpnSummary) ->
    join_blocks([user_tree(User, Devices, Certificates, Services, VpnSummary) || User <- Users]).

user_tree(User, Devices, Certificates, Services, VpnSummary) ->
    UserDevices = [find(DeviceId, Devices) || DeviceId <- maps:get(devices, User, [])],
    [tree_line(value(maps:get(name, User))),
     device_lines(UserDevices, Certificates, Services, VpnSummary)].

device_lines(Devices, Certificates, Services, VpnSummary) ->
    lists:append([device_tree(Device, Certificates, Services, VpnSummary) || Device <- Devices]).

device_tree(Device, Certificates, Services, VpnSummary) ->
    Certificate = find(maps:get(certificate, Device), Certificates),
    DeviceServices = [find(ServiceId, Services) || ServiceId <- maps:get(services, Device, [])],
    [tree_line(["  +- ", value(maps:get(id, Device))]),
     tree_line(["  |  +- ", value(maps:get(id, Certificate))])
     | service_lines(Device, DeviceServices, VpnSummary)].

service_lines(Device, Services, VpnSummary) ->
    [tree_line(["  |  `- ", service_label(Device, Service, VpnSummary)]) || Service <- Services].

service_label(Device, #{id := vpn}, VpnSummary) ->
    format_vpn_service(Device, VpnSummary);
service_label(_Device, Service, _VpnSummary) ->
    value(maps:get(id, Service)).

format_vpn_service(Device, VpnSummary) ->
    PeerId = maps:get(vpn_peer, Device, undefined),
    ["vpn -> ", value(PeerId), " -> ", atom_to_list(vpn_peer_status(PeerId, VpnSummary))].

vpn_peer_status(undefined, _VpnSummary) ->
    unknown;
vpn_peer_status(_PeerId, {error, _Reason}) ->
    unavailable;
vpn_peer_status(PeerId, {ok, Data}) when is_map(Data) ->
    case find_vpn_peer(PeerId, vpn_peers(Data)) of
        undefined -> unknown;
        Peer -> running_state(Peer)
    end;
vpn_peer_status(_PeerId, _VpnSummary) ->
    unavailable.

vpn_peers(Data) ->
    case maps:get(<<"peers">>, Data, []) of
        Peers when is_list(Peers) -> [Peer || Peer <- Peers, is_map(Peer)];
        _ -> []
    end.

find_vpn_peer(PeerId, Peers) ->
    case [Peer || Peer <- Peers, maps:get(<<"id">>, Peer, undefined) =:= PeerId] of
        [Peer | _] -> Peer;
        [] -> undefined
    end.

running_state(Peer) ->
    case maps:get(<<"running">>, Peer, field(Peer, [running, is_running, status])) of
        true -> running;
        <<"running">> -> running;
        <<"up">> -> running;
        "running" -> running;
        "up" -> running;
        _ -> stopped
    end.

field(Map, Keys) ->
    field(Map, Keys, undefined).

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

find(Id, Rows) ->
    case [Row || Row <- Rows, maps:get(id, Row) =:= Id] of
        [Row | _] -> Row;
        [] -> #{id => Id}
    end.

join_blocks([]) ->
    [];
join_blocks([Block]) ->
    Block;
join_blocks([Block | Rest]) ->
    [Block, tree_line(""), join_blocks(Rest)].

tree_line(Body) ->
    #panel{class = <<"ias-tree-line">>, body = tree_text(Body)}.

tree_text(Parts) when is_list(Parts) ->
    [tree_text(Part) || Part <- Parts];
tree_text(Part) ->
    #span{body = escape(value(Part))}.

escape(Value) when is_binary(Value) ->
    escape(binary_to_list(Value));
escape(Value) when is_atom(Value) ->
    escape(atom_to_list(Value));
escape(Value) when is_integer(Value) ->
    integer_to_list(Value);
escape(Value) when is_list(Value) ->
    escape_list(Value).

escape_list([]) ->
    [];
escape_list([$& | Rest]) ->
    ["&amp;" | escape_list(Rest)];
escape_list([$< | Rest]) ->
    ["&lt;" | escape_list(Rest)];
escape_list([$> | Rest]) ->
    ["&gt;" | escape_list(Rest)];
escape_list([Char | Rest]) ->
    [Char | escape_list(Rest)].

value(Value) when is_atom(Value) ->
    atom_to_list(Value);
value(Value) ->
    Value.
