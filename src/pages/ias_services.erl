-module(ias_services).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    Services = ias_demo_data:services(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Services"},
        #p{body = "Register services that will later use IAS identity and access controls."},
        #h3{body = count("Services", Services)},
        #table{class = <<"ias-table">>,
               header = header(["ID", "Name"]),
               body = #tbody{body =
                   [row([id(Service), maps:get(name, Service)])
                    || Service <- Services]}}
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
