-module(ias_relationships).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    Content = content(),
    Html = iolist_to_binary(nitro:render(Content)),
    SafeHtml = nitro:js_escape(Html),
    nitro:wire(["qi('stand').innerHTML='", SafeHtml, "';"]);
event(_) ->
    ok.

content() ->
    Users = ias_demo_data:users(),
    Devices = ias_demo_data:devices(),
    Certificates = ias_demo_data:certificates(),
    Services = ias_demo_data:services(),
    Profiles = ias_demo_data:profiles(),
    VpnSummary = ias_vpn_runtime:summary(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Relationships"},
        #p{body = "User to device, certificate and service relationships."},
        counters(Users, Devices, Certificates, Services),
        #panel{class = <<"ias-relationship-tree">>,
               body = hierarchy(Users, Devices, Certificates, Services, Profiles, VpnSummary)}
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

hierarchy(Users, Devices, Certificates, Services, Profiles, VpnSummary) ->
    join_blocks([user_tree(User, Devices, Certificates, Services, Profiles, VpnSummary) || User <- Users]).

user_tree(User, Devices, Certificates, Services, Profiles, VpnSummary) ->
    UserDevices = [find(DeviceId, Devices) || DeviceId <- maps:get(devices, User, [])],
    [tree_line(value(maps:get(name, User))),
     device_lines(UserDevices, Certificates, Services, Profiles, VpnSummary)].

device_lines(Devices, Certificates, Services, Profiles, VpnSummary) ->
    lists:append([device_tree(Device, Certificates, Services, Profiles, VpnSummary) || Device <- Devices]).

device_tree(Device, Certificates, Services, Profiles, VpnSummary) ->
    Certificate = find(maps:get(certificate, Device), Certificates),
    DeviceServices = [find(ServiceId, Services) || ServiceId <- maps:get(services, Device, [])],
    [tree_line(["  +- ", value(maps:get(id, Device))]),
     tree_line(["  |  +- ", value(maps:get(id, Certificate))])
     | service_lines(Device, DeviceServices, Profiles, VpnSummary)].

service_lines(Device, Services, Profiles, VpnSummary) ->
    lists:append([service_tree(Device, Service, Profiles, VpnSummary) || Service <- Services]).

service_tree(Device, #{id := vpn}, Profiles, VpnSummary) ->
    vpn_service_lines(Device, Profiles, VpnSummary);
service_tree(_Device, Service, _Profiles, _VpnSummary) ->
    [tree_line(["  |  `- ", value(maps:get(id, Service))])].

vpn_service_lines(Device, Profiles, VpnSummary) ->
    PeerId = maps:get(vpn_peer, Device, undefined),
    ProfileId = maps:get(profile_id, Device, undefined),
    Profile = profile(ProfileId, Profiles),
    Policy = ias_policy:evaluate_vpn(Profile),
    [tree_line(["  |  `- vpn -> ", value(PeerId), " -> ",
                atom_to_list(vpn_peer_status(PeerId, VpnSummary))]),
     tree_line(["  |      profile: ", value(ProfileId)]),
     tree_line(["  |      authorized: ", value(maps:get(authorized, Policy, false))]),
     tree_line(["  |      reason: ", value(maps:get(reason, Policy, undefined))])].

vpn_peer_status(undefined, _VpnSummary) ->
    unknown;
vpn_peer_status(_PeerId, {error, _Reason}) ->
    unavailable;
vpn_peer_status(PeerId, {ok, Data}) when is_map(Data) ->
    case ias_vpn_runtime:peer(PeerId, Data) of
        undefined -> unknown;
        Peer -> ias_vpn_runtime:state(Peer)
    end;
vpn_peer_status(_PeerId, _VpnSummary) ->
    unavailable.

profile(undefined, _Profiles) ->
    #{};
profile(ProfileId, Profiles) ->
    case [Profile || Profile <- Profiles, maps:get(id, Profile) =:= ProfileId] of
        [Profile | _] -> Profile;
        [] -> #{}
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
    #panel{class = <<"ias-tree-line">>, body = #span{body = line_text(Body)}}.

line_text(Value) ->
    unicode:characters_to_binary(text_chars(Value)).

text_chars(Value) when is_binary(Value) ->
    binary_to_list(Value);
text_chars(Value) when is_atom(Value) ->
    atom_to_list(Value);
text_chars(Value) when is_integer(Value) ->
    integer_to_list(Value);
text_chars(Value) when is_list(Value) ->
    case is_charlist(Value) of
        true -> Value;
        false -> lists:append([text_chars(Part) || Part <- Value])
    end.

is_charlist([]) ->
    true;
is_charlist([Char | Rest]) when is_integer(Char), Char >= 0 ->
    is_charlist(Rest);
is_charlist(_) ->
    false.

value(undefined) ->
    "-";
value(true) ->
    "yes";
value(false) ->
    "no";
value(Value) when is_atom(Value) ->
    atom_to_list(Value);
value(Value) ->
    Value.
