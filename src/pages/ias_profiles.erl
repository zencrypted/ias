-module(ias_profiles).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    Profiles = ias_demo_data:profiles(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Security Profiles"},
        #p{body = "Define reusable security posture templates when policy support is added."},
        #h3{body = count("Profiles", Profiles)},
        #table{class = <<"ias-table">>,
               header = header(["ID", "Description"]),
               body = #tbody{body =
                   [row([id(Profile), maps:get(description, Profile)])
                    || Profile <- Profiles]}}
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
