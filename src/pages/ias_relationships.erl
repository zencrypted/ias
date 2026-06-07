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
    VpnState = vpn_state(ias_vpn_client:summary()),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Relationships"},
        #p{body = "User to device, certificate and service relationships."},
        counters(Users, Devices, Certificates, Services),
        #pre{class = <<"ias-relationship-tree">>,
             body = hierarchy(Users, Devices, Certificates, Services, VpnState)}
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

hierarchy(Users, Devices, Certificates, Services, VpnState) ->
    join_lines([user_tree(User, Devices, Certificates, Services, VpnState) || User <- Users]).

user_tree(User, Devices, Certificates, Services, VpnState) ->
    UserDevices = [find(DeviceId, Devices) || DeviceId <- maps:get(devices, User, [])],
    [value(maps:get(name, User)), "\n",
     device_lines(UserDevices, Certificates, Services, VpnState)].

device_lines(Devices, Certificates, Services, VpnState) ->
    join_lines([device_tree(Device, Certificates, Services, VpnState) || Device <- Devices]).

device_tree(Device, Certificates, Services, VpnState) ->
    Certificate = find(maps:get(certificate, Device), Certificates),
    DeviceServices = [find(ServiceId, Services) || ServiceId <- maps:get(services, Device, [])],
    ["  +- ", value(maps:get(id, Device)), "\n",
     "  |  +- ", value(maps:get(id, Certificate)), "\n",
     service_lines(DeviceServices, VpnState)].

service_lines(Services, VpnState) ->
    join_lines([["  |  `- ", service_label(Service, VpnState)] || Service <- Services]).

service_label(#{id := vpn}, VpnState) ->
    ["vpn (", atom_to_list(VpnState), ")"];
service_label(Service, _VpnState) ->
    value(maps:get(id, Service)).

vpn_state({error, _Reason}) ->
    offline;
vpn_state({ok, Data}) ->
    case running_count(peers(Data)) of
        0 -> stopped;
        _ -> running
    end.

peers(Data) when is_map(Data) ->
    case field(Data, [<<"peers">>, peers, configured_peers_list, peer_status]) of
        Peers when is_list(Peers) -> [Peer || Peer <- Peers, is_map(Peer)];
        _ -> []
    end;
peers(_) ->
    [].

running_count(Peers) ->
    length([Peer || Peer <- Peers, running(Peer)]).

running(Peer) ->
    case field(Peer, [<<"running">>, running, is_running, status]) of
        true -> true;
        <<"running">> -> true;
        <<"up">> -> true;
        "running" -> true;
        "up" -> true;
        _ -> false
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

join_lines([]) ->
    [];
join_lines([Line]) ->
    Line;
join_lines([Line | Rest]) ->
    [Line, "\n", join_lines(Rest)].

value(Value) when is_atom(Value) ->
    atom_to_list(Value);
value(Value) ->
    Value.
