-module(ias_profile).
-export([event/1]).
-include_lib("n2o/include/n2o.hrl").
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    case ias_security_profile:profile(query_id()) of
        {ok, Profile} -> detail(Profile);
        not_found -> not_found()
    end.

query_id() ->
    Cx = get(context),
    Req = Cx#cx.req,
    case Req of
        #{qs := QS} ->
            proplists:get_value(<<"id">>, uri_string:dissect_query(nitro:to_binary(QS)));
        #{query_string := QS} ->
            proplists:get_value(<<"id">>, uri_string:dissect_query(nitro:to_binary(QS)));
        _ ->
            nitro:qc(id)
    end.

detail(Profile) ->
    Effects = ias_security_profile:policy_effects(Profile),
    Relationships = ias_security_profile:relationship_preview(Profile),
    #panel{class = <<"ias-placeholder">>, body = [
        breadcrumb(),
        #h2{body = ias_html:text("Security Profile")},
        #h3{body = ias_html:text("Security Profile Metadata")},
        key_value_table(metadata_rows(Profile)),
        #h3{body = ias_html:text("Security Policy")},
        key_value_table(security_policy_rows(Profile)),
        #h3{body = ias_html:text("Policy Effects")},
        key_value_table([
            {"VPN", maps:get(vpn, Effects, deny)},
            {"IAS", maps:get(ias, Effects, deny)}
        ]),
        #h3{body = ias_html:text("Certificate Issuance")},
        key_value_table([
            {"Role", maps:get(certificate_role, Profile, undefined)},
            {"Trust", maps:get(trust_level, Profile, undefined)}
        ]),
        #h3{body = ias_html:text("Certificate Preview")},
        key_value_table(security_policy_rows(Profile)),
        #h3{body = ias_html:text("Relationship Preview")},
        key_value_table([
            {"Users using this profile", users_list(maps:get(users, Relationships, []))},
            {"Certificates issued from this profile", object_list(maps:get(certificates, Relationships, []))},
            {"Devices using this profile", object_list(maps:get(devices, Relationships, []))}
        ])
    ]}.

not_found() ->
    #panel{class = <<"ias-placeholder">>, body = [
        breadcrumb(),
        #h2{body = ias_html:text("Security Profile Not Found")},
        #p{body = ias_html:text("The requested security profile is not available.")}
    ]}.

breadcrumb() ->
    #p{style = <<"font-size:12px;color:#64748b;">>,
       body = [#link{url = <<"/app/profiles.htm">>, body = ias_html:text("Security Profiles")},
               ias_html:text(" -> Security Profile")]}.

metadata_rows(Profile) ->
    [
        {"Profile", maps:get(id, Profile, undefined)},
        {"Role", maps:get(certificate_role, Profile, undefined)},
        {"Services", ias_html:join_csv(maps:get(services, Profile, []))},
        {"Attributes", ias_html:join_csv(maps:get(attributes, Profile, []))},
        {"Trust Level", maps:get(trust_level, Profile, undefined)}
    ].

security_policy_rows(Profile) ->
    [
        {"Device Lock", ias_policy:device_lock(Profile)},
        {"2FA", ias_policy:two_factor(Profile)}
    ].

key_value_table(Rows) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [key_value_row(Label, Value) || {Label, Value} <- Rows]}}
    ]}.

key_value_row(Label, Value) ->
    #tr{cells = [
        #th{body = ias_html:text(Label)},
        #td{body = cell_body(Value)}
    ]}.

cell_body(#panel{} = Panel) ->
    Panel;
cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

users_list([]) ->
    <<"not linked yet">>;
users_list(Users) ->
    #panel{body = join_values([maps:get(name, User, maps:get(id, User, undefined))
                               || User <- Users], [])}.

object_list([]) ->
    <<"not linked yet">>;
object_list(Objects) ->
    #panel{body = join_values([object_ref(Object) || Object <- Objects], [])}.

join_values([], Acc) ->
    lists:reverse(Acc);
join_values([Value | Rest], []) ->
    join_values(Rest, [cell_body(Value)]);
join_values([Value | Rest], Acc) ->
    join_values(Rest, [cell_body(Value), #br{} | Acc]).

object_ref(Object) ->
    Id = maps:get(id, Object, undefined),
    case ias_demo_store:get(Id) of
        {ok, DemoObject} ->
            Kind = maps:get(kind, DemoObject, maps:get(kind, Object, undefined)),
            TextId = ias_html:text(Id),
            #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
                  body = ias_html:join([object_label(Kind), <<" #">>, TextId])};
        not_found ->
            <<"not found">>
    end.

object_label(device) ->
    <<"Device">>;
object_label(certificate) ->
    <<"Certificate">>;
object_label(vpn_service) ->
    <<"VPN Service">>;
object_label(Kind) ->
    ias_html:text(Kind).
