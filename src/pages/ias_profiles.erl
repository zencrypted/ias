-module(ias_profiles).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    Profiles = ias_security_profile:profiles(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Security Profiles")},
        #p{body = ias_html:text("Security profiles define attributes and permissions that will later be embedded into issued certificates.")},
        #h3{body = count("Profiles", Profiles)},
        table([
            #table{class = <<"ias-table">>,
                   header = header(["Profile", "Services", "Attributes", "Certificate Claims",
                                    "Certificate Role", "Trust Level", "Device Lock", "2FA"]),
                   body = #tbody{body =
                       [profile_row(Profile) || Profile <- Profiles]}}
        ]),
        #h3{body = ias_html:text("Profile Comparison")},
        table([
            #table{class = <<"ias-table">>,
                   header = header(["Profile", "Role", "Trust", "Device Lock", "2FA"]),
                   body = #tbody{body =
                       [comparison_row(Row) || Row <- ias_security_profile:comparison()]}}
        ])
    ]}.

profile_row(Profile) ->
    row([profile_link(Profile),
         ias_html:join_csv(maps:get(services, Profile, [])),
         ias_html:join_csv(maps:get(attributes, Profile, [])),
         certificate_claims(Profile),
         maps:get(certificate_role, Profile),
         maps:get(trust_level, Profile),
         ias_policy:device_lock(Profile),
         ias_policy:two_factor(Profile)]).

profile_link(Profile) ->
    ProfileId = ias_html:text(id(Profile)),
    #link{url = ias_html:join([<<"/app/profile.htm?id=">>, ProfileId]),
          body = ias_html:join([ProfileId, <<" - ">>, maps:get(name, Profile)])}.

comparison_row(Row) ->
    row([profile_link(Row),
         maps:get(role, Row, undefined),
         maps:get(trust_level, Row, undefined),
         maps:get(device_lock, Row, undefined),
         maps:get(two_factor, Row, undefined)]).

certificate_claims(Profile) ->
    ias_policy:format_claims(ias_policy:certificate_claims(Profile)).

header(Columns) ->
    [#tr{cells = [#th{body = ias_html:text(Column)} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = cell_body(Value)} || Value <- Values]}.

cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

table(Body) ->
    #panel{class = <<"ias-table-container">>, body = Body}.

count(Label, Rows) ->
    ias_html:join([Label, ": ", length(Rows)]).

id(Map) ->
    maps:get(id, Map).
