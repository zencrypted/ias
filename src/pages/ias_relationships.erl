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
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Relationships"},
        #p{body = "User to device, certificate and service relationships."},
        counters(Users, Devices, Certificates, Services),
        #pre{class = <<"ias-relationship-tree">>,
             body = hierarchy(Users, Devices, Certificates, Services)}
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

hierarchy(Users, Devices, Certificates, Services) ->
    join_lines([user_tree(User, Devices, Certificates, Services) || User <- Users]).

user_tree(User, Devices, Certificates, Services) ->
    UserDevices = [find(DeviceId, Devices) || DeviceId <- maps:get(devices, User, [])],
    [value(maps:get(name, User)), "\n",
     device_lines(UserDevices, Certificates, Services)].

device_lines(Devices, Certificates, Services) ->
    join_lines([device_tree(Device, Certificates, Services) || Device <- Devices]).

device_tree(Device, Certificates, Services) ->
    Certificate = find(maps:get(certificate, Device), Certificates),
    DeviceServices = [find(ServiceId, Services) || ServiceId <- maps:get(services, Device, [])],
    ["  +- ", value(maps:get(id, Device)), "\n",
     "  |  +- ", value(maps:get(id, Certificate)), "\n",
     service_lines(DeviceServices)].

service_lines(Services) ->
    join_lines([["  |  `- ", value(maps:get(id, Service))] || Service <- Services]).

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
