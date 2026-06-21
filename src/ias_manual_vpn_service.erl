-module(ias_manual_vpn_service).
-export([create/1]).

create(Fields) when is_map(Fields) ->
    Values = normalize_fields(Fields),
    case validate(Values) of
        ok -> {ok, store_service(Values)};
        {error, Reason} -> {error, Reason}
    end.

normalize_fields(Fields) ->
    #{name => trim(maps:get(name, Fields, <<>>)),
      endpoint => trim(maps:get(endpoint, Fields, <<>>)),
      port => trim(maps:get(port, Fields, <<"1194">>)),
      protocol => trim(maps:get(protocol, Fields, <<"udp">>))}.

validate(#{name := <<>>}) ->
    {error, <<"Service Name is required">>};
validate(#{endpoint := <<>>}) ->
    {error, <<"Endpoint is required">>};
validate(#{port := Port, protocol := Protocol}) ->
    case valid_port(Port) of
        false -> {error, <<"Port must be an integer from 1 to 65535">>};
        true -> validate_protocol(Protocol)
    end.

%% Runtime protocol values remain binaries; no atoms are created from input.

validate_protocol(<<"udp">>) -> ok;
validate_protocol(<<"tcp">>) -> ok;
validate_protocol(_) -> {error, <<"Protocol must be udp or tcp">>}.

valid_port(Port) ->
    case catch binary_to_integer(Port) of
        Value when is_integer(Value), Value >= 1, Value =< 65535 -> true;
        _ -> false
    end.

store_service(Values) ->
    Id = service_id(),
    Endpoint = maps:get(endpoint, Values),
    Port = maps:get(port, Values),
    Protocol = maps:get(protocol, Values),
    Service = #{id => Id,
                kind => vpn_service,
                source => manual_vpn_service,
                import_id => Id,
                service => openvpn,
                name => maps:get(name, Values),
                remote => ias_html:join([Endpoint, <<":">>, Port]),
                remote_host => Endpoint,
                remote_port => Port,
                protocol => Protocol,
                cipher => not_configured,
                compression => false,
                routes => 0,
                tls_auth => not_configured,
                created_at => created_at()},
    ias_demo_store:put_runtime_object(Service).

trim(Value) ->
    Text = ias_html:text(Value),
    re:replace(Text, <<"^\\s+|\\s+$">>, <<>>, [global, {return, binary}]).

service_id() ->
    ias_html:join([<<"manual_vpn_service_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
