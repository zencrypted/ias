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
        #p{body = "Security profiles define attributes and permissions that will later be embedded into issued certificates."},
        #h3{body = count("Profiles", Profiles)},
        #table{class = <<"ias-table">>,
               header = header(["Profile", "Services", "Certificate Role", "Trust Level", "Attributes"]),
               body = #tbody{body =
                   [profile_row(Profile) || Profile <- Profiles]}}
    ]}.

profile_row(Profile) ->
    row([profile_name(Profile),
         join_values(maps:get(services, Profile, [])),
         maps:get(certificate_role, Profile),
         maps:get(trust_level, Profile),
         join_values(maps:get(attributes, Profile, []))]).

profile_name(Profile) ->
    text([id(Profile), " - ", maps:get(name, Profile)]).

header(Columns) ->
    [#tr{cells = [#th{body = Column} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = text(Value)} || Value <- Values]}.

count(Label, Rows) ->
    [Label, ": ", integer_to_list(length(Rows))].

id(Map) ->
    maps:get(id, Map).

text(Value) when is_binary(Value) ->
    Value;
text(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
text(Value) when is_integer(Value) ->
    integer_to_binary(Value);
text(Value) when is_list(Value) ->
    iolist_to_binary([text(Part) || Part <- Value]).

join_values([]) ->
    <<"-">>;
join_values(Values) ->
    join_values(Values, []).

join_values([], Acc) ->
    iolist_to_binary(lists:reverse(Acc));
join_values([Value], Acc) ->
    join_values([], [text(Value) | Acc]);
join_values([Value | Rest], Acc) ->
    join_values(Rest, [<<", ">>, text(Value) | Acc]).
