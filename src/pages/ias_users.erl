-module(ias_users).
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
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Users")},
        #p{body = ias_html:text("Review users through their devices, certificates, services and VPN peers.")},
        #h3{body = count("Users", Users)},
        table([
            #table{class = <<"ias-table">>,
                   header = header(["User", "Role", "Devices", "VPN Peers", "Certificates", "Services"]),
                   body = #tbody{body =
                       [user_row(User, Devices, Certificates)
                        || User <- Users]}}
        ])
    ]}.

user_row(User, Devices, Certificates) ->
    UserDevices = user_devices(User, Devices),
    row([maps:get(name, User),
         maps:get(role, User),
         length(UserDevices),
         ias_html:join_csv(vpn_peers(UserDevices)),
         length(user_certificates(UserDevices, Certificates)),
         ias_html:join_csv(services(UserDevices))]).

user_devices(User, Devices) ->
    [Device || DeviceId <- maps:get(devices, User, []),
               Device <- [find(DeviceId, Devices)],
               maps:is_key(id, Device)].

user_certificates(Devices, Certificates) ->
    [Certificate || Device <- Devices,
                    CertificateId <- certificate_ids(Device),
                    Certificate <- [find(CertificateId, Certificates)],
                    maps:is_key(id, Certificate)].

certificate_ids(Device) ->
    case maps:get(certificate, Device, undefined) of
        undefined -> [];
        CertificateId -> [CertificateId]
    end.

vpn_peers(Devices) ->
    unique([Peer || Device <- Devices,
                    Peer <- [maps:get(vpn_peer, Device, undefined)],
                    Peer =/= undefined]).

services(Devices) ->
    unique(lists:append([maps:get(services, Device, []) || Device <- Devices])).

unique(Values) ->
    unique(Values, []).

unique([], Acc) ->
    lists:reverse(Acc);
unique([Value | Rest], Acc) ->
    case lists:member(Value, Acc) of
        true -> unique(Rest, Acc);
        false -> unique(Rest, [Value | Acc])
    end.

find(Id, Rows) ->
    case [Row || Row <- Rows, maps:get(id, Row) =:= Id] of
        [Row | _] -> Row;
        [] -> #{}
    end.

header(Columns) ->
    [#tr{cells = [#th{body = ias_html:text(Column)} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = value(Value)} || Value <- Values]}.

table(Body) ->
    #panel{class = <<"ias-table-container">>, body = Body}.

count(Label, Rows) ->
    ias_html:join([Label, ": ", length(Rows)]).

value(undefined) ->
    ias_html:text("-");
value(Value) when is_atom(Value) ->
    ias_html:text(Value);
value(Value) when is_integer(Value) ->
    ias_html:text(Value);
value(Value) ->
    ias_html:text(Value).
