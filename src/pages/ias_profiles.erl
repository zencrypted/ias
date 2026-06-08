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
        #h2{body = ias_html:text("Security Profiles")},
        #p{body = ias_html:text("Security profiles define attributes and permissions that will later be embedded into issued certificates.")},
        #h3{body = count("Profiles", Profiles)},
        #table{class = <<"ias-table">>,
               header = header(["Profile", "Services", "Certificate Role", "Trust Level", "Attributes"]),
               body = #tbody{body =
                   [profile_row(Profile) || Profile <- Profiles]}}
    ]}.

profile_row(Profile) ->
    row([profile_name(Profile),
         ias_html:join_csv(maps:get(services, Profile, [])),
         maps:get(certificate_role, Profile),
         maps:get(trust_level, Profile),
         ias_html:join_csv(maps:get(attributes, Profile, []))]).

profile_name(Profile) ->
    ias_html:join([id(Profile), " - ", maps:get(name, Profile)]).

header(Columns) ->
    [#tr{cells = [#th{body = ias_html:text(Column)} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = ias_html:text(Value)} || Value <- Values]}.

count(Label, Rows) ->
    ias_html:join([Label, ": ", length(Rows)]).

id(Map) ->
    maps:get(id, Map).
