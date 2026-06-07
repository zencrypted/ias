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
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Users"},
        #p{body = "Manage identities that will access IAS-controlled services."},
        #h3{body = count("Users", Users)},
        #table{class = <<"ias-table">>,
               header = header(["ID", "Name", "Role"]),
               body = #tbody{body =
                   [row([id(User), maps:get(name, User), maps:get(role, User)])
                    || User <- Users]}}
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
