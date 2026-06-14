-module(ias_demo).
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
        {ok, Object} -> detail(Object);
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

detail(Object) ->
    #panel{class = <<"ias-placeholder">>, body = [
        breadcrumb(),
        #h2{body = ias_html:text("Demo Object")},
        #p{body = ias_html:text("Read-only metadata stored in ETS demo runtime state.")},
        #h3{body = title(Object)},
        key_value_table(rows(Object)),
        relationship_preview(Object)
    ]}.

not_found() ->
    #panel{class = <<"ias-placeholder">>, body = [
        breadcrumb(),
        #h2{body = ias_html:text("Demo Object Not Found")},
        #p{body = ias_html:text("The requested demo object is not available in ETS runtime state.")}
    ]}.

breadcrumb() ->
    #p{style = <<"font-size:12px;color:#64748b;">>,
       body = [#link{url = <<"/app/index.htm">>, body = ias_html:text("IAS")},
               ias_html:text(" -> Demo Object")]}.

title(#{kind := device}) ->
    <<"Device Metadata">>;
title(#{kind := certificate}) ->
    <<"Certificate Metadata">>;
title(#{kind := vpn_service}) ->
    <<"VPN Service Metadata">>;
title(_) ->
    <<"Demo Metadata">>.

rows(#{kind := device} = Object) ->
    common_rows(Object) ++ [
        {"Type", maps:get(type, Object, undefined)},
        {"Endpoint", maps:get(endpoint, Object, undefined)},
        {"Transport", maps:get(transport, Object, undefined)},
        {"Tunnel Device", maps:get(tunnel_device, Object, undefined)}
    ] ++ created_row(Object);
rows(#{kind := certificate} = Object) ->
    common_rows(Object) ++ [
        {"Subject", maps:get(subject, Object, undefined)},
        {"Issuer", maps:get(issuer, Object, undefined)},
        {"Not Before", maps:get(not_before, Object, undefined)},
        {"Not After", maps:get(not_after, Object, undefined)},
        {"Requested CN", maps:get(requested_cn, Object, undefined)},
        {"Enrollment CN", maps:get(enrollment_cn, Object, undefined)},
        {"Profile", maps:get(profile, Object, undefined)},
        {"CMP Server", maps:get(cmp_server, Object, undefined)},
        {"CA Present", maps:get(ca_present, Object, false)},
        {"Client Certificate Present", maps:get(client_certificate_present, Object, false)},
        {"Private Key Present", maps:get(private_key_present, Object, false)},
        {"Private Key Stored", maps:get(private_key_stored, Object, false)},
        {"Certificate Body Stored", maps:get(certificate_body_stored, Object, false)},
        {"TLS Auth Present", maps:get(tls_auth_present, Object, false)}
    ] ++ created_row(Object);
rows(#{kind := vpn_service} = Object) ->
    common_rows(Object) ++ [
        {"Service", maps:get(service, Object, undefined)},
        {"Remote", maps:get(remote, Object, undefined)},
        {"Protocol", maps:get(protocol, Object, undefined)},
        {"Cipher", maps:get(cipher, Object, undefined)},
        {"Compression", maps:get(compression, Object, false)},
        {"Routes", maps:get(routes, Object, 0)}
    ] ++ created_row(Object);
rows(Object) ->
    common_rows(Object) ++ created_row(Object).

common_rows(Object) ->
    [{"ID", maps:get(id, Object, undefined)},
     {"Import ID", maps:get(import_id, Object, undefined)}].

created_row(Object) ->
    [{"Created At", maps:get(created_at, Object, undefined)}].

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

relationship_preview(Object) ->
    case ias_relationship_preview:preview(Object) of
        #{kind := device} = Preview ->
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("Relationship Preview")},
                key_value_table([
                    {"Related Certificate", not_linked(maps:get(related_certificate, Preview))},
                    {"Related VPN Service", not_linked(maps:get(related_vpn_service, Preview))}
                ]),
                #h3{body = ias_html:text("Suggested Relationships")},
                key_value_table([
                    {"Suggested Certificate", candidate_links(maps:get(suggested_certificates, Preview, []))},
                    {"Suggested VPN Service", candidate_links(maps:get(suggested_services, Preview, []))}
                ])
            ]};
        #{kind := certificate} = Preview ->
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("Relationship Preview")},
                key_value_table([
                    {"Used By Device", not_linked(maps:get(used_by_device, Preview))}
                ]),
                #h3{body = ias_html:text("Suggested Relationships")},
                key_value_table([
                    {"Suggested Devices", candidate_links(maps:get(suggested_devices, Preview, []))}
                ])
            ]};
        #{kind := vpn_service} = Preview ->
            #panel{class = <<"ias-status-card">>, body = [
                #h3{body = ias_html:text("Relationship Preview")},
                key_value_table([
                    {"Used By Device", not_linked(maps:get(used_by_device, Preview))}
                ]),
                #h3{body = ias_html:text("Suggested Relationships")},
                key_value_table([
                    {"Suggested Devices", candidate_links(maps:get(suggested_devices, Preview, []))}
                ])
            ]};
        _ ->
            []
    end.

not_linked(not_linked) ->
    <<"not linked yet">>;
not_linked(Value) ->
    Value.

candidate_links([]) ->
    <<"not found">>;
candidate_links(Candidates) ->
    #panel{body = candidate_links(Candidates, [])}.

candidate_links([], Acc) ->
    lists:reverse(Acc);
candidate_links([Candidate | Rest], []) ->
    candidate_links(Rest, [candidate_link(Candidate)]);
candidate_links([Candidate | Rest], Acc) ->
    candidate_links(Rest, [candidate_link(Candidate), #br{} | Acc]).

candidate_link(Candidate) ->
    Id = maps:get(id, Candidate, undefined),
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
          body = ias_html:join([candidate_label(Candidate), <<" #">>, TextId,
                                <<" (score ">>, maps:get(relationship_score, Candidate, 0),
                                <<")">>])}.

candidate_label(#{kind := certificate}) ->
    <<"Certificate">>;
candidate_label(#{kind := vpn_service}) ->
    <<"VPN Service">>;
candidate_label(#{kind := device}) ->
    <<"Device">>;
candidate_label(_Object) ->
    <<"Demo Object">>.
