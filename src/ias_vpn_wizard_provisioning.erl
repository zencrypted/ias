-module(ias_vpn_wizard_provisioning).
-export([provision/1]).

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
    case bind_runtime_peer(DeviceId) of
        {ok, RuntimePeerId} ->
            case ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, upsert) of
                {ok, DeliveryResult} ->
                    {ok, #{wizard_id => maps:get(id, Draft),
                           device_id => DeviceId,
                           runtime_peer_id => RuntimePeerId,
                           provisioning_id => maps:get(id, Transaction, undefined),
                           transaction => Transaction,
                           command => maps:get(command, DeliveryResult, #{}),
                           delivery => maps:get(delivery, DeliveryResult, #{})}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

bind_runtime_peer(DeviceId) ->
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} ->
            RuntimePeerId = configured_runtime_peer_id(Device),
            Updated = Device#{runtime_peer_id => RuntimePeerId,
                              vpn_peer => RuntimePeerId},
            _ = ias_demo_store:put_runtime_object(Updated),
            {ok, RuntimePeerId};
        _ ->
            {error, device_required}
    end.

configured_runtime_peer_id(Device) ->
    case first_present([maps:get(runtime_peer_id, Device, undefined),
                        maps:get(vpn_peer, Device, undefined),
                        application:get_env(ias,
                                            vpn_provisioning_runtime_peer_id,
                                            undefined)]) of
        undefined -> maps:get(id, Device);
        RuntimePeerId -> RuntimePeerId
    end.

first_present([undefined | Rest]) -> first_present(Rest);
first_present([<<>> | Rest]) -> first_present(Rest);
first_present([Value | _]) -> Value;
first_present([]) -> undefined.
