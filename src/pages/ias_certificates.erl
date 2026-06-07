-module(ias_certificates).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    Certificates = ias_demo_data:certificates(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Certificates"},
        #p{body = "Review issued certificates when certificate management is enabled."},
        #h3{body = count("Certificates", Certificates)},
        #table{class = <<"ias-table">>,
               header = header(["ID", "Owner", "Status"]),
               body = #tbody{body =
                   [row([id(Certificate),
                         maps:get(owner, Certificate),
                         maps:get(status, Certificate)])
                    || Certificate <- Certificates]}}
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
