-module(ias_manual_device).
-export([create/1]).

create(Fields) when is_map(Fields) ->
    Values = normalize_fields(Fields),
    case validate(Values) of
        ok ->
            {ok, store_device(Values)};
        {error, Reason} ->
            {error, Reason}
    end.

normalize_fields(Fields) ->
    #{name => trim(maps:get(name, Fields, <<>>)),
      type => trim(maps:get(type, Fields, <<"vpn-client">>)),
      tunnel_device => trim(maps:get(tunnel_device, Fields, <<"tun">>)),
      transport => trim(maps:get(transport, Fields, <<"udp">>)),
      endpoint => trim(maps:get(endpoint, Fields, <<>>)),
      private_key_provider => trim(maps:get(private_key_provider, Fields, <<"device_file">>)),
      private_key_ref => trim(maps:get(private_key_ref, Fields, <<"client.key">>))}.

validate(#{name := <<>>}) ->
    {error, <<"Device Name is required">>};
validate(#{type := <<>>}) ->
    {error, <<"Device Type is required">>};
validate(#{tunnel_device := <<>>}) ->
    {error, <<"Tunnel Device is required">>};
validate(#{transport := <<>>}) ->
    {error, <<"Transport is required">>};
validate(#{transport := Transport} = Values) ->
    case allowed_transport(Transport) of
        true -> validate_private_key_ref(Values);
        false -> {error, <<"Transport must be udp or tcp">>}
    end.

validate_private_key_ref(Values) ->
    case ias_device_key_ref:validate(Values) of
        {ok, _Safe} -> ok;
        {error, Reason} -> {error, Reason}
    end.

allowed_transport(<<"udp">>) ->
    true;
allowed_transport(<<"tcp">>) ->
    true;
allowed_transport(_Transport) ->
    false.

store_device(Values) ->
    Id = device_id(),
    Device = #{
        id => Id,
        kind => device,
        source => manual_device,
        import_id => Id,
        name => maps:get(name, Values),
        type => maps:get(type, Values),
        tunnel_device => maps:get(tunnel_device, Values),
        transport => maps:get(transport, Values),
        endpoint => endpoint_value(maps:get(endpoint, Values)),
        private_key_provider => maps:get(private_key_provider, Values),
        private_key_ref => maps:get(private_key_ref, Values),
        created_at => created_at(),
        private_key_stored => false,
        certificate_body_stored => false,
        ca_body_stored => false
    },
    ias_demo_store:put_runtime_object(Device).

endpoint_value(<<>>) ->
    <<"">>;
endpoint_value(Endpoint) ->
    Endpoint.

trim(Value) ->
    Text = ias_html:text(Value),
    re:replace(Text, <<"^\\s+|\\s+$">>, <<>>, [global, {return, binary}]).

device_id() ->
    ias_html:join([<<"manual_device_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
