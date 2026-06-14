-module(ias_user).
-export([event/1]).
-include_lib("n2o/include/n2o.hrl").
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    case ias_demo_store:get(query_id()) of
        {ok, #{kind := user} = User} -> detail(User);
        _ -> not_found()
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

detail(User) ->
    #panel{class = <<"ias-placeholder">>, body = [
        breadcrumb(),
        #h2{body = ias_html:text("User")},
        #h3{body = ias_html:text("User Metadata")},
        key_value_table([
            {"User", maps:get(name, User, maps:get(id, User, undefined))},
            {"Role", maps:get(role, User, undefined)},
            {"Security Profile", profile_link(maps:get(profile_id, User, undefined))}
        ]),
        #h3{body = ias_html:text("Issued Certificates")},
        key_value_table([
            {"Certificates", issued_certificates(User)}
        ])
    ]}.

not_found() ->
    #panel{class = <<"ias-placeholder">>, body = [
        breadcrumb(),
        #h2{body = ias_html:text("User Not Found")},
        #p{body = ias_html:text("The requested user is not available.")}
    ]}.

breadcrumb() ->
    #p{style = <<"font-size:12px;color:#64748b;">>,
       body = [#link{url = <<"/app/users.htm">>, body = ias_html:text("Users")},
               ias_html:text(" -> User")]}.

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

profile_link(undefined) ->
    <<"not found">>;
profile_link(ProfileId) ->
    TextId = ias_html:text(ProfileId),
    #link{url = ias_html:join([<<"/app/profile.htm?id=">>, TextId]),
          body = TextId}.

issued_certificates(User) ->
    Links = [certificate_link(maps:get(id, Certificate, undefined))
             || Certificate <- ias_user_detail:issued_certificates(User)],
    links_or_not_found(Links).

certificate_link(Id) ->
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
          body = ias_html:join([<<"Certificate #">>, TextId])}.

links_or_not_found([]) ->
    <<"not found">>;
links_or_not_found(Links) ->
    #panel{body = join_links(Links, [])}.

join_links([], Acc) ->
    lists:reverse(Acc);
join_links([Link | Rest], []) ->
    join_links(Rest, [Link]);
join_links([Link | Rest], Acc) ->
    join_links(Rest, [Link, #br{} | Acc]).
