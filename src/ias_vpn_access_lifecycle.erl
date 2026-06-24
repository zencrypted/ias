-module(ias_vpn_access_lifecycle).
-export([status/1,
         disable/1,
         enable/1,
         revoke/1,
         decommission/1,
         decommission/2]).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_DYNAMIC_PAIR_TIMEOUT, 30000).

status(DeviceId) ->
    case device(DeviceId) of
        {ok, Device} ->
            RuntimePeerId = runtime_peer_id(Device),
            DeliveryStatus = ias_vpn_provisioning_delivery:status(DeviceId),
            Allocation = allocation_status(Device),
            Decommission = decommission_status(Device),
            #{device_id => maps:get(id, Device),
              runtime_peer_id => RuntimePeerId,
              binding_mode => binding_mode(Allocation, Decommission),
              allocation => Allocation,
              decommission => Decommission,
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

decommission(DeviceId) ->
    decommission(DeviceId, #{}).

decommission(DeviceId, Options0) when is_map(Options0) ->
    case normalize_decommission_options(Options0) of
        {ok, Options} ->
            case device(DeviceId) of
                {ok, Device} ->
                    decommission_device(Device, Options);
                not_found ->
                    {error, not_found}
            end;
        {error, _} = Error ->
            Error
    end;
decommission(_DeviceId, _Options) ->
    {error, invalid_vpn_decommission_request}.

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

decommission_device(Device, Options) ->
    case allocation_status(Device) of
        undefined ->
            {error, dynamic_vpn_allocation_required};
        Allocation ->
            case transport() of
                erlang_rpc ->
                    DeviceId = normalize_id(maps:get(id, Device)),
                    case call_rpc(vpn_dynamic_pair,
                                  decommission,
                                  [DeviceId, Options],
                                  dynamic_pair_rpc_timeout()) of
                        {ok, Summary} when is_map(Summary) ->
                            accept_decommission(Device, Allocation, Summary);
                        {error, {dynamic_identity_cleanup_failed,
                                 Reason,
                                 Summary}} when is_map(Summary) ->
                            case accept_decommission(Device, Allocation, Summary) of
                                {ok, Result} ->
                                    {error,
                                     {vpn_decommission_identity_cleanup_failed,
                                      Reason,
                                      Result}};
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, Reason} ->
                            {error, {vpn_decommission_failed, Reason}};
                        {badrpc, Reason} ->
                            {error, {vpn_decommission_rpc_failed, Reason}};
                        Other ->
                            {error, {unexpected_vpn_decommission_result, Other}}
                    end;
                disabled ->
                    {error, vpn_transport_disabled};
                Other ->
                    {error, {unsupported_vpn_transport, Other}}
            end
    end.

accept_decommission(Device, Allocation, Summary) ->
    case safe_decommission_summary(Device, Allocation, Summary) of
        {ok, Safe0} ->
            RecordedAt = erlang:system_time(second),
            Safe = Safe0#{ias_recorded_at => RecordedAt},
            History0 = maps:get(vpn_decommission_history, Device, []),
            History = case is_list(History0) of
                          true -> [Safe | History0];
                          false -> [Safe]
                      end,
            ClearedDevice0 = maps:without(vpn_binding_fields(), Device),
            ClearedDevice = ClearedDevice0#{vpn_last_decommission => Safe,
                                            vpn_decommission_history => History,
                                            vpn_decommissioned_at =>
                                                maps:get(decommissioned_at,
                                                         Safe,
                                                         RecordedAt)},
            _ = ias_demo_store:put_runtime_object(ClearedDevice),
            {ok, DraftsCleared} =
                ias_provisioning_wizard_store:clear_vpn_allocation_for_device(
                  maps:get(id, Device)),
            {ok, Safe#{operation => decommission,
                       user_id => maps:get(owner, Device, undefined),
                       runtime_peer_id => runtime_peer_id(Device),
                       wizard_drafts_cleared => DraftsCleared}};
        {error, _} = Error ->
            Error
    end.

safe_decommission_summary(Device, Allocation, Summary) ->
    Allowed = [device_id,
               allocation_id,
               allocator_instance_id,
               slot,
               generation,
               client_peer_id,
               gateway_peer_id,
               state,
               allocation_state,
               registry_state,
               persistence,
               identity_state,
               decommissioned_at],
    Safe = maps:with(Allowed, Summary),
    Checks = [maps:get(device_id, Safe, undefined) =:=
                  normalize_id(maps:get(id, Device)),
              maps:get(allocation_id, Safe, undefined) =:=
                  maps:get(allocation_id, Allocation),
              maps:get(allocator_instance_id, Safe, undefined) =:=
                  maps:get(allocator_instance_id, Allocation),
              maps:get(slot, Safe, undefined) =:= maps:get(slot, Allocation),
              maps:get(generation, Safe, undefined) =:=
                  maps:get(generation, Allocation),
              maps:get(client_peer_id, Safe, undefined) =:=
                  maps:get(client_peer_id, Allocation),
              maps:get(gateway_peer_id, Safe, undefined) =:=
                  maps:get(gateway_peer_id, Allocation),
              maps:get(state, Safe, undefined) =:= decommissioned,
              maps:get(allocation_state, Safe, undefined) =:= released,
              maps:get(registry_state, Safe, undefined) =:= removed,
              valid_identity_state(maps:get(identity_state, Safe, undefined)),
              valid_persistence(maps:get(persistence, Safe, undefined)),
              valid_timestamp(maps:get(decommissioned_at, Safe, undefined))],
    case lists:all(fun(Value) -> Value =:= true end, Checks) of
        true -> {ok, Safe};
        false -> {error, invalid_vpn_decommission_summary}
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

decommission_status(Device) ->
    case maps:get(vpn_last_decommission, Device, undefined) of
        Summary when is_map(Summary) -> Summary;
        _ -> undefined
    end.

binding_mode(Allocation, _Decommission) when is_map(Allocation) -> dynamic;
binding_mode(undefined, Decommission) when is_map(Decommission) -> decommissioned;
binding_mode(undefined, _Decommission) -> static.

runtime_peer_id(Device) ->
    case first_present([maps:get(runtime_peer_id, Device, undefined),
                        maps:get(vpn_peer, Device, undefined)]) of
        undefined ->
            case has_dynamic_binding_history(Device) of
                true -> undefined;
                false -> maps:get(peer_id, Device, undefined)
            end;
        RuntimePeerId ->
            RuntimePeerId
    end.

has_dynamic_binding_history(Device) ->
    maps:get(vpn_allocation_id, Device, undefined) =/= undefined orelse
    maps:get(vpn_last_decommission, Device, undefined) =/= undefined.

vpn_binding_fields() ->
    [runtime_peer_id,
     vpn_peer,
     vpn_allocation_id,
     vpn_allocator_instance_id,
     vpn_client_peer_id,
     vpn_gateway_peer_id,
     vpn_allocation_slot,
     vpn_allocation_generation,
     vpn_allocation_state,
     vpn_allocation_persistence,
     vpn_allocation_created_at,
     vpn_dynamic_pair_state,
     vpn_dynamic_pair_reconciled_at,
     vpn_runtime_certificate_fingerprint].

valid_identity_state(retained) -> true;
valid_identity_state(removed) -> true;
valid_identity_state(absent) -> true;
valid_identity_state(_) -> false.

valid_persistence(volatile) -> true;
valid_persistence(durable) -> true;
valid_persistence(_) -> false.

valid_timestamp(Value) -> is_integer(Value) andalso Value >= 0.

normalize_decommission_options(Options) ->
    Unknown = maps:keys(maps:without([remove_identity], Options)),
    Normalized = maps:merge(#{remove_identity => false}, Options),
    case {Unknown, maps:get(remove_identity, Normalized)} of
        {[], Value} when is_boolean(Value) -> {ok, Normalized};
        {[_ | _], _} -> {error, {unknown_vpn_decommission_options, Unknown}};
        {[], _} -> {error, invalid_remove_identity_option}
    end.

normalize_id(Id) ->
    ias_html:text(Id).

device(DeviceId) ->
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} -> {ok, Device};
        _ -> not_found
    end.

call_rpc(Module, Function, Args) ->
    call_rpc(Module, Function, Args, rpc_timeout()).

call_rpc(Module, Function, Args, Timeout) ->
    case rpc_fun() of
        Fun when is_function(Fun, 5) ->
            Fun(vpn_node(), Module, Function, Args, Timeout);
        undefined ->
            rpc:call(vpn_node(), Module, Function, Args, Timeout)
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

dynamic_pair_rpc_timeout() ->
    application:get_env(ias,
                        vpn_dynamic_pair_rpc_timeout,
                        ?DEFAULT_DYNAMIC_PAIR_TIMEOUT).

rpc_fun() ->
    case application:get_env(ias, vpn_provisioning_rpc_fun) of
        {ok, Fun} when is_function(Fun, 5) -> Fun;
        _ -> undefined
    end.

first_present([undefined | Rest]) -> first_present(Rest);
first_present([<<>> | Rest]) -> first_present(Rest);
first_present([Value | _]) -> Value;
first_present([]) -> undefined.
