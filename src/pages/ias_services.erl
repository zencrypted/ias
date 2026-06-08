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
        ])
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
    #tr{cells = [#td{body = value(Value)} || Value <- Values]}.

table(Body) ->
    #panel{class = <<"ias-table-container">>, body = Body}.

count(Label, Rows) ->
    [Label, ": ", integer_to_list(length(Rows))].

value(undefined) ->
    "-";
value(Value) when is_atom(Value) ->
    atom_to_list(Value);
value(Value) when is_integer(Value) ->
    integer_to_list(Value);
value(Value) ->
    Value.
