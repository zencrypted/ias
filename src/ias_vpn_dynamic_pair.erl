-module(ias_vpn_dynamic_pair).
-export([enabled/0, ensure/2, delivery_mode/1, accept/3, needs_binding_recovery/1]).

-define(DEFAULT_TIMEOUT, 30000).

%% IAS routes allocator-backed upserts through vpn_provisioning:apply_dynamic/2
%% only when a Device carries a complete reservation. This module validates the
%% returned safe pair projection and persists the public runtime binding. The
%% legacy ensure/2 path remains only for compatibility with older delivery code.
%% VPN remains the owner of transport and identity material.
enabled() ->
    case application:get_env(ias, vpn_dynamic_pair_delivery, false) of
        true -> true;
        enabled -> true;
        <<"enabled">> -> true;
        <<"true">> -> true;
        _ -> false
    end.

delivery_mode(DeviceId0) ->
    case enabled() of
        false ->
            static;
        true ->
            with_device(
              DeviceId0,
              fun(_DeviceId, Device) ->
                  case reservation(Device) of
                      {ok, _Reservation} -> dynamic;
                      not_dynamic -> static;
                      {error, _Reason} = Error -> Error
                  end
              end)
    end.

accept(DeviceId0, Command, Status) when is_map(Command), is_map(Status) ->
    with_device(
      DeviceId0,
      fun(DeviceId, Device) ->
          case reservation(Device) of
              {ok, Reservation} ->
                  accept_provisioned_status(DeviceId,
                                            Device,
                                            Reservation,
                                            Command,
                                            Status);
              not_dynamic ->
                  {error, vpn_dynamic_allocation_required};
              {error, _Reason} = Error ->
                  Error
          end
      end);
accept(_DeviceId, _Command, _Status) ->
    {error, invalid_vpn_dynamic_pair_status}.

needs_binding_recovery(DeviceId0) ->
    with_device(
      DeviceId0,
      fun(_DeviceId, Device) ->
          case reservation(Device) of
              {ok, Reservation} ->
                  ClientPeerId = maps:get(client_peer_id, Reservation),
                  not (maps:get(runtime_peer_id, Device, undefined) =:= ClientPeerId
                       andalso maps:get(vpn_peer, Device, undefined) =:= ClientPeerId
                       andalso nonempty_binary(
                                 maps:get(vpn_runtime_certificate_fingerprint,
                                          Device,
                                          undefined))
                       andalso maps:get(vpn_dynamic_pair_state,
                                        Device,
                                        undefined) =:= established);
              not_dynamic ->
                  false;
              {error, _Reason} = Error ->
                  Error
          end
      end).

ensure(DeviceId0, Desired0) when is_map(Desired0) ->
    case enabled() of
        false ->
            disabled;
        true ->
            case transport() of
                erlang_rpc ->
                    with_device(
                      DeviceId0,
                      fun(DeviceId, Device) ->
                          case reservation(Device) of
                              not_dynamic ->
                                  not_dynamic;
                              {error, Reason} ->
                                  {error, Reason};
                              {ok, Reservation} ->
                                  Desired = dynamic_desired(DeviceId, Desired0),
                                  case call_rpc(vpn_dynamic_pair,
                                                ensure,
                                                [DeviceId, Desired]) of
                                      {ok, Status} when is_map(Status) ->
                                          accept_status(Device,
                                                        Reservation,
                                                        Status);
                                      {error, Reason} ->
                                          {error, {vpn_dynamic_pair_failed,
                                                   Reason}};
                                      {badrpc, Reason} ->
                                          {error, {vpn_dynamic_pair_rpc_failed,
                                                   Reason}};
                                      Other ->
                                          {error,
                                           {unexpected_vpn_dynamic_pair_result,
                                            Other}}
                                  end
                          end
                      end);
                disabled ->
                    {error, vpn_transport_disabled};
                Other ->
                    {error, {unsupported_vpn_transport, Other}}
            end
    end;
ensure(_DeviceId, _Desired) ->
    {error, invalid_desired_state}.

with_device(DeviceId0, Fun) ->
    DeviceId = normalize_id(DeviceId0),
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} -> Fun(DeviceId, Device);
        _ -> {error, device_required}
    end.

reservation(Device) ->
    Values = #{allocation_id => maps:get(vpn_allocation_id, Device, undefined),
               allocator_instance_id => maps:get(vpn_allocator_instance_id,
                                                 Device, undefined),
               client_peer_id => maps:get(vpn_client_peer_id, Device, undefined),
               gateway_peer_id => maps:get(vpn_gateway_peer_id, Device, undefined),
               slot => maps:get(vpn_allocation_slot, Device, undefined),
               generation => maps:get(vpn_allocation_generation, Device, undefined),
               state => maps:get(vpn_allocation_state, Device, undefined)},
    Present = [Value =/= undefined || Value <- maps:values(Values)],
    case lists:any(fun(Value) -> Value end, Present) of
        false ->
            not_dynamic;
        true ->
            case valid_reservation(Values) of
                true -> {ok, Values};
                false -> {error, invalid_vpn_allocation_binding}
            end
    end.

valid_reservation(Reservation) ->
    nonempty_binary(maps:get(allocation_id, Reservation))
        andalso nonempty_binary(maps:get(allocator_instance_id, Reservation))
        andalso nonempty_binary(maps:get(client_peer_id, Reservation))
        andalso nonempty_binary(maps:get(gateway_peer_id, Reservation))
        andalso positive_integer(maps:get(slot, Reservation))
        andalso positive_integer(maps:get(generation, Reservation))
        andalso maps:get(state, Reservation) =:= reserved.

dynamic_desired(DeviceId, Desired) ->
    maps:remove(
      certificate_fingerprint,
      maps:with([device_id,
                 profile_id,
                 authorization_mode,
                 authorized,
                 authorization_reason,
                 enabled,
                 revoked],
                Desired#{device_id => DeviceId})).

accept_status(Device, Reservation, Status) ->
    accept_status(Device, Reservation, Status, legacy).

accept_provisioned_status(DeviceId, Device, Reservation, Command, Status) ->
    Desired = maps:get(desired_state, Command, #{}),
    Revision = maps:get(revision, Command, undefined),
    Source = maps:get(source, Command, undefined),
    Checks = [maps:get(operation, Command, undefined) =:= upsert,
              maps:get(peer_id, Command, undefined) =:=
                  maps:get(client_peer_id, Reservation),
              maps:get(device_id, Desired, DeviceId) =:= DeviceId,
              is_integer(Revision) andalso Revision > 0],
    case lists:all(fun(Value) -> Value =:= true end, Checks) of
        true ->
            accept_status(Device,
                          Reservation,
                          Status,
                          #{revision => Revision, source => Source});
        false ->
            {error, invalid_vpn_dynamic_pair_status}
    end.

accept_status(Device, Reservation, Status, Expectations) ->
    case safe_status(Device, Reservation, Status, Expectations) of
        {ok, Safe, ClientRegistry} ->
            Fingerprint = maps:get(certificate_fingerprint, ClientRegistry),
            Updated = Device#{runtime_peer_id => maps:get(client_peer_id, Reservation),
                              vpn_peer => maps:get(client_peer_id, Reservation),
                              vpn_runtime_certificate_fingerprint => Fingerprint,
                              vpn_dynamic_pair_state => established,
                              vpn_dynamic_pair_reconciled_at => erlang:system_time(second)},
            _ = ias_demo_store:put_runtime_object(Updated),
            {ok, Safe};
        {error, Reason} ->
            {error, Reason}
    end.

safe_status(Device, Reservation, Status, Expectations) ->
    Client = maps:get(client, Status, #{}),
    Gateway = maps:get(gateway, Status, #{}),
    ClientRegistry = maps:get(registry, Client, #{}),
    GatewayRegistry = maps:get(registry, Gateway, #{}),
    DeviceId = maps:get(id, Device),
    Checks = [maps:get(device_id, Status, undefined) =:= DeviceId,
              maps:get(allocation_id, Status, undefined) =:=
                  maps:get(allocation_id, Reservation),
              maps:get(allocator_instance_id, Status, undefined) =:=
                  maps:get(allocator_instance_id, Reservation),
              maps:get(client_peer_id, Status, undefined) =:=
                  maps:get(client_peer_id, Reservation),
              maps:get(gateway_peer_id, Status, undefined) =:=
                  maps:get(gateway_peer_id, Reservation),
              valid_side(Client, client, Reservation, DeviceId, Expectations),
              valid_side(Gateway, gateway, Reservation, DeviceId, Expectations),
              nonempty_binary(maps:get(certificate_fingerprint,
                                       ClientRegistry,
                                       undefined)),
              maps:get(allocation_role, ClientRegistry, undefined) =:= client,
              maps:get(allocation_role, GatewayRegistry, undefined) =:= gateway],
    case lists:all(fun(Value) -> Value =:= true end, Checks) of
        true ->
            {ok,
             #{allocation_id => maps:get(allocation_id, Reservation),
               allocator_instance_id => maps:get(allocator_instance_id, Reservation),
               device_id => DeviceId,
               client_peer_id => maps:get(client_peer_id, Reservation),
               gateway_peer_id => maps:get(gateway_peer_id, Reservation),
               state => established,
               client => safe_side(Client),
               gateway => safe_side(Gateway)},
             ClientRegistry};
        false ->
            {error, invalid_vpn_dynamic_pair_status}
    end.

valid_side(Side, Role, Reservation, DeviceId, Expectations) when is_map(Side) ->
    Registry = maps:get(registry, Side, #{}),
    PeerId = case Role of
                 client -> maps:get(client_peer_id, Reservation);
                 gateway -> maps:get(gateway_peer_id, Reservation)
             end,
    maps:get(peer_id, Side, undefined) =:= PeerId
        andalso maps:get(running, Side, false) =:= true
        andalso maps:get(handshake_status, Side, undefined) =:= established
        andalso maps:get(id, Registry, undefined) =:= PeerId
        andalso maps:get(device_id, Registry, undefined) =:= DeviceId
        andalso maps:get(allocation_id, Registry, undefined) =:=
                    maps:get(allocation_id, Reservation)
        andalso maps:get(allocator_instance_id, Registry, undefined) =:=
                    maps:get(allocator_instance_id, Reservation)
        andalso maps:get(allocation_slot, Registry, undefined) =:=
                    maps:get(slot, Reservation)
        andalso maps:get(allocation_generation, Registry, undefined) =:=
                    maps:get(generation, Reservation)
        andalso maps:get(allocation_role, Registry, undefined) =:= Role
        andalso valid_provisioning_metadata(Registry, Expectations);
valid_side(_Side, _Role, _Reservation, _DeviceId, _Expectations) ->
    false.

valid_provisioning_metadata(_Registry, legacy) ->
    true;
valid_provisioning_metadata(Registry, #{revision := Revision, source := Source}) ->
    maps:get(revision, Registry, undefined) =:= Revision
        andalso maps:get(provisioning_source, Registry, undefined) =:= Source
        andalso maps:get(last_provisioning_operation, Registry, undefined) =:= upsert.

safe_side(Side) ->
    Registry = maps:get(registry, Side, #{}),
    #{peer_id => maps:get(peer_id, Side),
      running => maps:get(running, Side),
      handshake_status => maps:get(handshake_status, Side),
      registry => maps:with([id,
                             device_id,
                             profile_id,
                             enabled,
                             authorized,
                             authorization_mode,
                             authorization_reason,
                             certificate_fingerprint,
                             revision,
                             revoked,
                             provisioning_source,
                             allocation_id,
                             allocator_instance_id,
                             allocation_slot,
                             allocation_generation,
                             allocation_role,
                             last_provisioning_operation,
                             updated_at],
                            Registry)}.

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
    application:get_env(ias, vpn_dynamic_pair_rpc_timeout, ?DEFAULT_TIMEOUT).

rpc_fun() ->
    case application:get_env(ias, vpn_provisioning_rpc_fun) of
        {ok, Fun} when is_function(Fun, 5) -> Fun;
        _ -> undefined
    end.

nonempty_binary(Value) when is_binary(Value) -> byte_size(Value) > 0;
nonempty_binary(_) -> false.

positive_integer(Value) -> is_integer(Value) andalso Value > 0.

normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) -> ias_html:text(Id).
