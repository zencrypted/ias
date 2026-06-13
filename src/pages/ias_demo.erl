-module(ias_demo).
-export([event/1]).
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
    nitro:qc(id).

detail(Object) ->
    #panel{class = <<"ias-placeholder">>, body = [
        breadcrumb(),
        #h2{body = ias_html:text("Demo Object")},
        #p{body = ias_html:text("Read-only metadata stored in ETS demo runtime state.")},
        #h3{body = title(Object)},
        key_value_table(rows(Object))
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
        {"CA Present", maps:get(ca_present, Object, false)},
        {"Client Certificate Present", maps:get(client_certificate_present, Object, false)},
        {"Private Key Present", maps:get(private_key_present, Object, false)},
        {"Private Key Stored", maps:get(private_key_stored, Object, false)},
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
        #td{body = ias_html:text(Value)}
    ]}.
