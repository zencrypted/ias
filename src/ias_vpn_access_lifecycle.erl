-module(ias_vpn_access_lifecycle).
-export([status/1,
         disable/1,
         enable/1,
         revoke/1]).

-define(DEFAULT_TIMEOUT, 5000).

status(DeviceId) ->
    case device(DeviceId) of
        {ok, Device} ->
            RuntimePeerId = runtime_peer_id(Device),
            DeliveryStatus = ias_vpn_provisioning_delivery:status(DeviceId),
            Allocation = allocation_status(Device),
            #{device_id => maps:get(id, Device),
              runtime_peer_id => RuntimePeerId,
              binding_mode => binding_mode(Allocation),
              allocation => Allocation,
              provisioning => DeliveryStatus,
              runtime => runtime_status(RuntimePeerId)};
        not_found ->
            {error, not_found}
    end.

disable(DeviceId) ->
    apply_operation(DeviceId, disable).

enable(DeviceId) ->
    apply_operation(DeviceId, enable).

revoke(DeviceId) ->
    apply_operation(DeviceId, revoke).

apply_operation(DeviceId, Operation) ->
    case device(DeviceId) of
        {ok, Device} ->
            RuntimePeerId = runtime_peer_id(Device),
            case RuntimePeerId of
                undefined ->
                    {error, runtime_peer_not_bound};
                _ ->
                    ok = synchronize_runtime_revision(DeviceId, RuntimePeerId),
                    case ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, Operation) of
                        {ok, Result} ->
                            {ok, lifecycle_result(Device, RuntimePeerId, Result)};
                        Error ->
                            Error
                    end
            end;
        not_found ->
            {error, not_found}
    end.

lifecycle_result(Device, RuntimePeerId, Result) ->
    Command = maps:get(command, Result, #{}),
    Delivery = maps:get(delivery, Result, #{}),
    #{device_id => maps:get(id, Device),
      user_id => maps:get(owner, Device, undefined),
      runtime_peer_id => RuntimePeerId,
      operation => maps:get(operation, Command, undefined),
      revision => maps:get(revision, Command, undefined),
      delivery_status => maps:get(delivery_status, Delivery, undefined),
      runtime => delivered_runtime(Delivery),
      command => Command,
      delivery => Delivery}.

delivered_runtime(#{vpn_result := {ok, #{peer := Peer}}}) when is_map(Peer) ->
    {ok, sanitize_runtime_peer(Peer)};
delivered_runtime(_Delivery) ->
    undefined.

runtime_status(undefined) ->
    not_bound;
runtime_status(RuntimePeerId) ->
    case transport() of
        erlang_rpc ->
            case call_rpc(vpn_peer_registry, get, [RuntimePeerId]) of
                {ok, Peer} when is_map(Peer) -> {ok, sanitize_runtime_peer(Peer)};
                {error, not_found} -> not_found;
                {badrpc, Reason} -> {unavailable, Reason};
                Other -> {unavailable, Other}
            end;
        disabled ->
            disabled;
        Other ->
            {unavailable, {unsupported_transport, Other}}
    end.

sanitize_runtime_peer(Peer) ->
    maps:with([id,
               device_id,
               profile_id,
               enabled,
               authorized,
               authorization_reason,
               revision,
               revoked,
               last_provisioning_operation],
              Peer).

synchronize_runtime_revision(DeviceId, RuntimePeerId) ->
    case transport() of
        erlang_rpc ->
            case call_rpc(vpn_peer_registry, get, [RuntimePeerId]) of
                {ok, Peer} when is_map(Peer) ->
                    Revision = maps:get(revision, Peer, 0),
                    ias_vpn_provisioning_state:ensure_minimum_revision(DeviceId, Revision);
                {error, not_found} ->
                    ok;
                {badrpc, _Reason} ->
                    ok;
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

allocation_status(Device) ->
    Allocation = #{allocation_id => maps:get(vpn_allocation_id, Device, undefined),
                   allocator_instance_id => maps:get(vpn_allocator_instance_id,
                                                     Device,
                                                     undefined),
                   client_peer_id => maps:get(vpn_client_peer_id, Device, undefined),
                   gateway_peer_id => maps:get(vpn_gateway_peer_id, Device, undefined),
                   slot => maps:get(vpn_allocation_slot, Device, undefined),
                   generation => maps:get(vpn_allocation_generation, Device, undefined),
                   state => maps:get(vpn_allocation_state, Device, undefined),
                   persistence => maps:get(vpn_allocation_persistence,
                                           Device,
                                           undefined),
                   created_at => maps:get(vpn_allocation_created_at,
                                          Device,
                                          undefined),
                   pair_state => maps:get(vpn_dynamic_pair_state, Device, undefined),
                   reconciled_at => maps:get(vpn_dynamic_pair_reconciled_at,
                                             Device,
                                             undefined)},
    case maps:get(allocation_id, Allocation, undefined) of
        undefined -> undefined;
        <<>> -> undefined;
        _AllocationId -> Allocation
    end.

binding_mode(undefined) -> static;
binding_mode(_Allocation) -> dynamic.

runtime_peer_id(Device) ->
    first_present([maps:get(runtime_peer_id, Device, undefined),
                   maps:get(vpn_peer, Device, undefined),
                   maps:get(peer_id, Device, undefined)]).

device(DeviceId) ->
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} -> {ok, Device};
        _ -> not_found
    end.

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

first_present([undefined | Rest]) -> first_present(Rest);
first_present([<<>> | Rest]) -> first_present(Rest);
first_present([Value | _]) -> Value;
first_present([]) -> undefined.
