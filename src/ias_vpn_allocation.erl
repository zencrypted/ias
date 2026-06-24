-module(ias_vpn_allocation).
-export([enabled/0, ensure/1, lookup/1]).

-define(DEFAULT_TIMEOUT, 5000).

%% IAS reserves VPN-owned runtime resources before CSR preparation, but keeps
%% only allocation identity metadata. Transport details and identity material
%% stay on the VPN node.
enabled() ->
    case application:get_env(ias, vpn_dynamic_allocation_reservation, false) of
        true -> true;
        enabled -> true;
        <<"enabled">> -> true;
        <<"true">> -> true;
        _ -> false
    end.

ensure(DeviceId0) ->
    with_feature(
      fun() ->
          with_device(
            DeviceId0,
            fun(DeviceId, Device) ->
                case call_rpc(vpn_peer_allocator, ensure, [DeviceId]) of
                    {ok, Allocation} when is_map(Allocation) ->
                        accept_allocation(DeviceId, Device, Allocation);
                    {error, Reason} ->
                        {error, {vpn_allocation_reservation_failed, Reason}};
                    {badrpc, Reason} ->
                        {error, {vpn_allocation_rpc_failed, Reason}};
                    Other ->
                        {error, {unexpected_vpn_allocation_result, Other}}
                end
            end)
      end).

lookup(DeviceId0) ->
    with_feature(
      fun() ->
          with_device(
            DeviceId0,
            fun(DeviceId, Device) ->
                case call_rpc(vpn_peer_allocator, lookup, [DeviceId]) of
                    {ok, Allocation} when is_map(Allocation) ->
                        accept_allocation(DeviceId, Device, Allocation);
                    {error, not_found} ->
                        {error, not_found};
                    {error, Reason} ->
                        {error, {vpn_allocation_lookup_failed, Reason}};
                    {badrpc, Reason} ->
                        {error, {vpn_allocation_rpc_failed, Reason}};
                    Other ->
                        {error, {unexpected_vpn_allocation_result, Other}}
                end
            end)
      end).

with_feature(Fun) ->
    case enabled() of
        true ->
            case transport() of
                erlang_rpc -> Fun();
                disabled -> {error, vpn_transport_disabled};
                Other -> {error, {unsupported_vpn_transport, Other}}
            end;
        false ->
            disabled
    end.

with_device(DeviceId0, Fun) ->
    DeviceId = normalize_id(DeviceId0),
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} -> Fun(DeviceId, Device);
        _ -> {error, device_required}
    end.

accept_allocation(DeviceId, Device, Allocation) ->
    case safe_allocation(DeviceId, Allocation) of
        {ok, Safe} ->
            UpdatedDevice = maps:merge(Device, device_updates(Safe)),
            _ = ias_demo_store:put_runtime_object(UpdatedDevice),
            {ok, Safe};
        {error, Reason} ->
            {error, Reason}
    end.

safe_allocation(DeviceId, Allocation) ->
    Safe = maps:with([allocation_id,
                      allocator_instance_id,
                      device_id,
                      client_peer_id,
                      gateway_peer_id,
                      slot,
                      generation,
                      state,
                      persistence,
                      created_at],
                     Allocation),
    case valid_allocation(DeviceId, Safe) of
        true -> {ok, Safe};
        false -> {error, invalid_vpn_allocation}
    end.

valid_allocation(DeviceId, Safe) ->
    maps:get(device_id, Safe, undefined) =:= DeviceId
        andalso nonempty_binary(maps:get(allocation_id, Safe, undefined))
        andalso nonempty_binary(maps:get(allocator_instance_id, Safe, undefined))
        andalso nonempty_binary(maps:get(client_peer_id, Safe, undefined))
        andalso nonempty_binary(maps:get(gateway_peer_id, Safe, undefined))
        andalso positive_integer(maps:get(slot, Safe, undefined))
        andalso positive_integer(maps:get(generation, Safe, undefined))
        andalso maps:get(state, Safe, undefined) =:= reserved
        andalso lists:member(maps:get(persistence, Safe, undefined),
                             [volatile, durable]).

nonempty_binary(Value) when is_binary(Value) -> byte_size(Value) > 0;
nonempty_binary(_) -> false.

positive_integer(Value) -> is_integer(Value) andalso Value > 0.

device_updates(Safe) ->
    #{vpn_allocation_id => maps:get(allocation_id, Safe),
      vpn_allocator_instance_id => maps:get(allocator_instance_id, Safe),
      vpn_client_peer_id => maps:get(client_peer_id, Safe),
      vpn_gateway_peer_id => maps:get(gateway_peer_id, Safe),
      vpn_allocation_slot => maps:get(slot, Safe),
      vpn_allocation_generation => maps:get(generation, Safe),
      vpn_allocation_state => maps:get(state, Safe),
      vpn_allocation_persistence => maps:get(persistence, Safe),
      vpn_allocation_created_at => maps:get(created_at, Safe, undefined)}.

call_rpc(Module, Function, Args) ->
    case rpc_fun() of
        Fun when is_function(Fun, 5) ->
            Fun(vpn_node(), Module, Function, Args, rpc_timeout());
        undefined ->
            rpc:call(vpn_node(), Module, Function, Args, rpc_timeout())
    end.

transport() ->
    case application:get_env(ias, vpn_provisioning_transport, disabled) of
        disabled -> disabled;
        erlang_rpc -> erlang_rpc;
        <<"disabled">> -> disabled;
        <<"erlang_rpc">> -> erlang_rpc;
        Value -> Value
    end.

vpn_node() ->
    application:get_env(ias, vpn_provisioning_vpn_node, 'vpn@127.0.0.1').

rpc_timeout() ->
    application:get_env(ias, vpn_provisioning_rpc_timeout, ?DEFAULT_TIMEOUT).

rpc_fun() ->
    case application:get_env(ias, vpn_provisioning_rpc_fun) of
        {ok, Fun} when is_function(Fun, 5) -> Fun;
        _ -> undefined
    end.

normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) -> ias_html:text(Id).
