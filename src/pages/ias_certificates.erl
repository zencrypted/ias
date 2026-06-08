-module(ias_certificates).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    VpnSummary = ias_vpn_runtime:summary(),
    Peers = ias_vpn_runtime:peers(VpnSummary),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Certificates"},
        #p{body = "Review live VPN certificate metadata from the VPN admin API."},
        #h3{body = count("Certificates", Peers)},
        status(VpnSummary),
        table([
            #table{class = <<"ias-table">>,
                   header = header(["Peer", "Subject CN", "Issuer CN", "Valid From",
                                    "Valid To", "Trusted", "Key Match"]),
                   body = #tbody{body =
                       [certificate_row(Peer) || Peer <- Peers]}}
        ])
    ]}.

status({error, _Reason}) ->
    #panel{class = <<"ias-status-card">>, body = "VPN certificate metadata unavailable."};
status(_VpnSummary) ->
    [].

certificate_row(Peer) ->
    row([ias_vpn_runtime:field(Peer, [<<"id">>, id, peer, name]),
         ias_vpn_runtime:certificate_field(Peer, [subject_cn]),
         ias_vpn_runtime:certificate_field(Peer, [issuer_cn]),
         ias_vpn_runtime:certificate_field(Peer, [not_before]),
         ias_vpn_runtime:certificate_field(Peer, [not_after]),
         ias_vpn_runtime:certificate_field(Peer, [trusted]),
         ias_vpn_runtime:certificate_field(Peer, [key_match])]).

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
value(true) ->
    "yes";
value(false) ->
    "no";
value(Value) when is_atom(Value) ->
    atom_to_list(Value);
value(Value) when is_integer(Value) ->
    integer_to_list(Value);
value(Value) ->
    Value.
