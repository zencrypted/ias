-module(ias_ovpn_import).
-export([import_map/1]).

import_map(Preview) ->
    #{device => #{type => <<"vpn-client">>,
                  endpoint => endpoint(Preview),
                  transport => missing_text(maps:get(proto, Preview, not_found)),
                  tunnel_device => missing_text(maps:get(dev, Preview, not_found))},
      certificate => #{ca_present => maps:get(has_ca, Preview, false),
                       client_certificate_present => maps:get(has_cert, Preview, false),
                       private_key_present => maps:get(has_key, Preview, false),
                       tls_auth_present => maps:get(tls_auth, Preview, false)},
      vpn_service => #{service => openvpn,
                       remote => endpoint(Preview),
                       protocol => missing_text(maps:get(proto, Preview, not_found)),
                       cipher => missing_text(maps:get(cipher, Preview, not_found)),
                       compression => maps:get(compression, Preview, false),
                       routes => maps:get(route_count, Preview, 0)}}.

endpoint(Preview) ->
    Host = maps:get(remote_host, Preview, not_found),
    Port = maps:get(remote_port, Preview, not_found),
    case {Host, Port} of
        {not_found, _} -> <<"not found">>;
        {_, not_found} -> <<"not found">>;
        _ -> ias_html:join([Host, <<":">>, Port])
    end.

missing_text(not_found) ->
    <<"not found">>;
missing_text(Value) ->
    Value.
