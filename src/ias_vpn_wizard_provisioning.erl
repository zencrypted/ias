-module(ias_vpn_wizard_provisioning).
-export([provision/1, runtime_peer_id/2]).

provision(WizardId) ->
    case ias_provisioning_wizard_store:get(WizardId) of
        {ok, Draft} ->
            provision_ready_draft(Draft);
        not_found ->
            {error, not_found}
    end.

provision_ready_draft(Draft) ->
    case ias_provisioning_wizard_store:material_readiness_ready(Draft) of
        false ->
            {error, material_readiness_blocked};
        true ->
            WizardId = maps:get(id, Draft),
            case ias_provisioning_wizard_store:create_provisioning(WizardId) of
                {ok, CompletedDraft, Transaction} ->
                    DeviceId = maps:get(device_id, Transaction,
                                        maps:get(device_id, CompletedDraft, undefined)),
                    deliver(CompletedDraft, Transaction, DeviceId);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

deliver(_Draft, _Transaction, undefined) ->
    {error, device_required};
deliver(Draft, Transaction, DeviceId) ->
    case ensure_runtime_allocation(DeviceId) of
        ok ->
            case synchronize_draft_allocation(Draft, DeviceId) of
                {ok, SyncedDraft} ->
                    deliver_with_runtime_allocation(SyncedDraft,
                                                    Transaction,
                                                    DeviceId);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

deliver_with_runtime_allocation(Draft, Transaction, DeviceId) ->
    case bind_runtime_peer(DeviceId, Draft) of
        {ok, RuntimePeerId} ->
            ok = synchronize_runtime_revision(DeviceId, RuntimePeerId),
            AuditContext = #{provisioning_transaction_id =>
                                 maps:get(id, Transaction, undefined),
                             wizard_id => maps:get(id, Draft, undefined)},
            case ias_vpn_provisioning_delivery:build_and_deliver(
                   DeviceId, upsert, AuditContext) of
                {ok, DeliveryResult} ->
                    {ok, #{wizard_id => maps:get(id, Draft),
                           user_id => maps:get(user_id, Draft, undefined),
                           device_id => DeviceId,
                           runtime_peer_id => RuntimePeerId,
                           allocation_id => device_field(DeviceId, vpn_allocation_id),
                           gateway_peer_id => device_field(DeviceId, vpn_gateway_peer_id),
                           allocator_instance_id => device_field(DeviceId, vpn_allocator_instance_id),
                           provisioning_id => maps:get(id, Transaction, undefined),
                           transaction => Transaction,
                           dynamic_pair => maps:get(dynamic_pair, DeliveryResult, undefined),
                           command => maps:get(command, DeliveryResult, #{}),
                           delivery => maps:get(delivery, DeliveryResult, #{})}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

bind_runtime_peer(DeviceId, Draft) ->
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} ->
            RuntimePeerId = runtime_peer_id(Device, Draft),
            Updated = Device#{runtime_peer_id => RuntimePeerId,
                              vpn_peer => RuntimePeerId},
            _ = ias_demo_store:put_runtime_object(Updated),
            {ok, RuntimePeerId};
        _ ->
            {error, device_required}
    end.

runtime_peer_id(Device, Draft) when is_map(Device), is_map(Draft) ->
    UserId = maps:get(user_id, Draft, maps:get(owner, Device, undefined)),
    case first_present([dynamic_peer_id(Device),
                        maps:get(runtime_peer_id, Device, undefined),
                        configured_user_runtime_peer_id(UserId),
                        maps:get(vpn_peer, Device, undefined),
                        application:get_env(ias,
                                            vpn_provisioning_runtime_peer_id,
                                            undefined)]) of
        undefined -> maps:get(id, Device);
        RuntimePeerId -> RuntimePeerId
    end.

configured_user_runtime_peer_id(undefined) ->
    undefined;
configured_user_runtime_peer_id(UserId) ->
    Slots = application:get_env(ias, vpn_provisioning_runtime_peer_slots, #{}),
    lookup_runtime_slot(UserId, Slots).

lookup_runtime_slot(UserId, Slots) when is_map(Slots) ->
    maps:get(UserId, Slots, maps:get(normalize_slot_key(UserId), Slots, undefined));
lookup_runtime_slot(UserId, Slots) when is_list(Slots) ->
    proplists:get_value(UserId,
                        Slots,
                        proplists:get_value(normalize_slot_key(UserId), Slots));
lookup_runtime_slot(_UserId, _Slots) ->
    undefined.

normalize_slot_key(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
normalize_slot_key(Value) when is_binary(Value) -> Value;
normalize_slot_key(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
normalize_slot_key(Value) -> Value.

first_present([undefined | Rest]) -> first_present(Rest);
first_present([<<>> | Rest]) -> first_present(Rest);
first_present([Value | _]) -> Value;
first_present([]) -> undefined.


synchronize_runtime_revision(DeviceId, RuntimePeerId) ->
    case application:get_env(ias, vpn_provisioning_transport, disabled) of
        erlang_rpc ->
            synchronize_runtime_revision(DeviceId, RuntimePeerId, vpn_node());
        <<"erlang_rpc">> ->
            synchronize_runtime_revision(DeviceId, RuntimePeerId, vpn_node());
        _ ->
            ok
    end.

synchronize_runtime_revision(DeviceId, RuntimePeerId, Node) ->
    Timeout = application:get_env(ias, vpn_provisioning_rpc_timeout, 5000),
    case rpc:call(Node, vpn_peer_registry, get, [RuntimePeerId], Timeout) of
        {ok, Peer} when is_map(Peer) ->
            Revision = maps:get(revision, Peer, 0),
            ias_vpn_provisioning_state:ensure_minimum_revision(DeviceId, Revision);
        {error, not_found} ->
            ok;
        {badrpc, _Reason} ->
            ok;
        _ ->
            ok
    end.

ensure_runtime_allocation(DeviceId) ->
    case ias_vpn_dynamic_pair:enabled() of
        false -> ok;
        true ->
            case ias_vpn_allocation:ensure(DeviceId) of
                {ok, _Allocation} -> ok;
                disabled -> {error, vpn_dynamic_allocation_required};
                {error, Reason} -> {error, Reason}
            end
    end.

synchronize_draft_allocation(Draft, DeviceId) ->
    case ias_vpn_dynamic_pair:enabled() of
        false ->
            {ok, Draft};
        true ->
            case ias_demo_store:get(DeviceId) of
                {ok, #{kind := device} = Device} ->
                    case maps:get(vpn_allocation_id, Device, undefined) of
                        undefined ->
                            {error, vpn_dynamic_allocation_required};
                        <<>> ->
                            {error, vpn_dynamic_allocation_required};
                        _AllocationId ->
                            Updates = maps:with(
                                        [vpn_allocation_id,
                                         vpn_allocator_instance_id,
                                         vpn_client_peer_id,
                                         vpn_gateway_peer_id,
                                         vpn_allocation_slot,
                                         vpn_allocation_generation,
                                         vpn_allocation_state,
                                         vpn_allocation_persistence,
                                         vpn_allocation_created_at],
                                        Device),
                            ias_provisioning_wizard_store:update(
                              maps:get(id, Draft),
                              Updates)
                    end;
                _ ->
                    {error, device_required}
            end
    end.

dynamic_peer_id(Device) ->
    case ias_vpn_dynamic_pair:enabled() of
        true -> maps:get(vpn_client_peer_id, Device, undefined);
        false -> undefined
    end.

device_field(DeviceId, Key) ->
    case ias_demo_store:get(DeviceId) of
        {ok, Device} -> maps:get(Key, Device, undefined);
        _ -> undefined
    end.

vpn_node() ->
    application:get_env(ias, vpn_provisioning_vpn_node, 'vpn@127.0.0.1').
