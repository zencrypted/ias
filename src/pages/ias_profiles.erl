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
        table([
            #table{class = <<"ias-table">>,
                   header = header(["Profile", "Services", "Attributes", "Certificate Claims",
                                    "Certificate Role", "Trust Level"]),
                   body = #tbody{body =
                       [profile_row(Profile) || Profile <- Profiles]}}
        ])
    ]}.

profile_row(Profile) ->
    row([profile_name(Profile),
         ias_html:join_csv(maps:get(services, Profile, [])),
         ias_html:join_csv(maps:get(attributes, Profile, [])),
         certificate_claims(Profile),
         maps:get(certificate_role, Profile),
         maps:get(trust_level, Profile)]).

profile_name(Profile) ->
    ias_html:join([id(Profile), " - ", maps:get(name, Profile)]).

certificate_claims(Profile) ->
    ias_html:join(["role=", maps:get(certificate_role, Profile, undefined),
                   "; services=", join_claim_values(maps:get(services, Profile, [])),
                   "; attrs=", join_claim_values(maps:get(attributes, Profile, [])),
                   "; trust=", maps:get(trust_level, Profile, undefined)]).

join_claim_values([]) ->
    <<"-">>;
join_claim_values(Values) ->
    join_claim_values(Values, []).

join_claim_values([], Acc) ->
    iolist_to_binary(lists:reverse(Acc));
join_claim_values([Value], Acc) ->
    join_claim_values([], [ias_html:text(Value) | Acc]);
join_claim_values([Value | Rest], Acc) ->
    join_claim_values(Rest, [<<",">>, ias_html:text(Value) | Acc]).

header(Columns) ->
    [#tr{cells = [#th{body = ias_html:text(Column)} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = ias_html:text(Value)} || Value <- Values]}.

table(Body) ->
    #panel{class = <<"ias-table-container">>, body = Body}.

count(Label, Rows) ->
    ias_html:join([Label, ": ", length(Rows)]).

id(Map) ->
    maps:get(id, Map).
