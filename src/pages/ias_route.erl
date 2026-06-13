-module(ias_route).
-include_lib("n2o/include/n2o.hrl").
-export([init/2, finish/2]).

finish(State, Ctx) -> {ok, State, Ctx}.
init(State, #cx{req=Req}=Cx) ->
    #{path:=Path}=Req,
    Fix = route_prefix(Path),
    {ok, State, Cx#cx{path=Path,module=Fix}}.

route_prefix(<<"/ws/",P/binary>>) -> route(P);
route_prefix(<<"/",   P/binary>>) -> route(P);
route_prefix(P)                   -> route(P).

route(<<>>)                              -> ias_index;
route(<<"app/index",        _/binary>>) -> ias_index;
route(<<"app/users",        _/binary>>) -> ias_users;
route(<<"app/devices",      _/binary>>) -> ias_devices;
route(<<"app/services",     _/binary>>) -> ias_services;
route(<<"app/certificates", _/binary>>) -> ias_certificates;
route(<<"app/profiles",     _/binary>>) -> ias_profiles;
route(<<"app/relationships", _/binary>>) -> ias_relationships;
route(<<"app/vpn",          _/binary>>) -> ias_vpn;
route(<<"app/ovpn",         _/binary>>) -> ias_ovpn;
route(<<"app/demo",         _/binary>>) -> ias_demo;
route(<<"app/issue",        _/binary>>) -> ias_issue_cert;
route(<<"app/verify",       _/binary>>) -> ias_verify_cert;
route(_)                                 -> ias_index.
