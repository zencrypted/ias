-module(ias_services).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    Services = ias_demo_data:services(),
    VpnSummary = ias_vpn_runtime:summary(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Services"},
        #p{body = "Register services that will later use IAS identity and access controls."},
        #h3{body = count("Services", Services)},
        table([
            #table{class = <<"ias-table">>,
                   header = header(["Service", "State", "Configured Peers", "Running Peers", "Certificates"]),
                   body = #tbody{body =
                       [service_row(Service, VpnSummary)
                        || Service <- Services]}}
        ]),
        imported_demo_objects()
    ]}.

service_row(#{id := vpn, name := Name}, VpnSummary) ->
    Counts = ias_vpn_runtime:counts(VpnSummary),
    Peers = ias_vpn_runtime:peers(VpnSummary),
    row([Name,
         vpn_state(VpnSummary, Peers),
         maps:get(<<"configured">>, Counts, length(Peers)),
         maps:get(<<"running">>, Counts, ias_vpn_runtime:running_count(Peers)),
         maps:get(<<"certificates">>, Counts, 0)]);
service_row(Service, _VpnSummary) ->
    row([maps:get(name, Service), "-", "-", "-", "-"]).

vpn_state({error, _Reason}, _Peers) ->
    unavailable;
vpn_state(_VpnSummary, Peers) ->
    case ias_vpn_runtime:running_count(Peers) of
        0 -> stopped;
        _ -> running
    end.

header(Columns) ->
    [#tr{cells = [#th{body = Column} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = cell_body(Value)} || Value <- Values]}.

cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

imported_demo_objects() ->
    Records = ias_demo_store:services(),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Imported Demo Objects")},
        imported_services(Records)
    ]}.

imported_services([]) ->
    #p{body = ias_html:text("No imported demo objects yet.")};
imported_services(Records) ->
    table([
        #table{class = <<"ias-table">>,
               header = header(["ID", "Service", "Remote", "Protocol", "Cipher",
                                "Compression", "Routes", "Source", "Import ID"]),
               body = #tbody{body = [imported_service_row(Record) || Record <- Records]}}
    ]).

imported_service_row(Record) ->
    row([demo_link(maps:get(id, Record, undefined)),
         maps:get(service, Record, undefined),
         maps:get(remote, Record, undefined),
         maps:get(protocol, Record, undefined),
         maps:get(cipher, Record, undefined),
         maps:get(compression, Record, false),
         maps:get(routes, Record, 0),
         maps:get(source, Record, undefined),
         maps:get(import_id, Record, undefined)]).

demo_link(undefined) ->
    undefined;
demo_link(Id) ->
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
          body = TextId}.

table(Body) ->
    #panel{class = <<"ias-table-container">>, body = Body}.

count(Label, Rows) ->
    [Label, ": ", integer_to_list(length(Rows))].
