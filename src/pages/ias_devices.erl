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
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Devices"},
        #p{body = "Track endpoints and devices that will participate in IAS policies."},
        #h3{body = count("Devices", Devices)},
        #table{class = <<"ias-table">>,
               header = header(["ID", "Owner", "Type"]),
               body = #tbody{body =
                   [row([id(Device), maps:get(owner, Device), maps:get(type, Device)])
                    || Device <- Devices]}}
    ]}.

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
value(Value) ->
    Value.
