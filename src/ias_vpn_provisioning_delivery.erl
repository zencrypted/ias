-module(ias_vpn_provisioning_delivery).
-export([deliver/1,
         build_and_deliver/2,
         status/1,
         history/1,
         reset/0]).

-define(TABLE, ias_vpn_provisioning_delivery_history).
-define(OWNER, ias_vpn_provisioning_delivery_history_owner).
-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_DYNAMIC_TIMEOUT, 30000).

deliver(Command) when is_map(Command) ->
    case deliver_with_runtime(Command) of
        {ok, Record, _DynamicPair} -> {ok, Record};
        {error, _Reason} = Error -> Error
    end;
deliver(_Command) ->
    {error, invalid_command}.

build_and_deliver(DeviceId, Operation) ->
    case ias_vpn_provisioning_command:build(DeviceId, Operation) of
        {ok, Command} ->
            case deliver_with_runtime(Command) of
                {ok, Delivery, DynamicPair} ->
                    Result0 = #{command => Command, delivery => Delivery},
                    {ok, maybe_put(dynamic_pair, DynamicPair, Result0)};
                {error, _Reason} = Error ->
                    Error
            end;
        Error ->
            Error
    end.

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

status(DeviceId) ->
    ensure(),
    DeviceKey = normalize_id(DeviceId),
    Attempts = history(DeviceKey),
    case Attempts of
        [Latest | _] ->
            #{device_id => DeviceKey,
              attempts => length(Attempts),
              current_revision => ias_vpn_provisioning_state:current_revision(DeviceKey),
              last_delivery_status => maps:get(delivery_status, Latest, undefined),
              last_delivered_at => maps:get(delivered_at, Latest, undefined),
              last_operation => maps:get(operation, Latest, undefined),
              last_revision => maps:get(revision, Latest, undefined)};
        [] ->
            #{device_id => DeviceKey,
              attempts => 0,
              current_revision => ias_vpn_provisioning_state:current_revision(DeviceKey),
              last_delivery_status => undefined,
              last_delivered_at => undefined,
              last_operation => undefined,
              last_revision => undefined}
    end.

history(DeviceId) ->
    ensure(),
    DeviceKey = normalize_id(DeviceId),
    case ets:lookup(?TABLE, DeviceKey) of
        [{DeviceKey, Records}] -> Records;
        [] -> []
    end.

reset() ->
    ensure(),
    ets:delete_all_objects(?TABLE),
    ok.

deliver_with_runtime(Command) ->
    ensure(),
    Summary = ias_vpn_provisioning_command:summary(Command),
    case delivery_route(Command) of
        {dynamic, DeviceId} ->
            case deliver_dynamic_command(DeviceId, Command) of
                {ok, Delivery, DynamicPair} ->
                    Record = delivery_record(Summary, Delivery),
                    store(Record),
                    {ok, Record, DynamicPair};
                {error, Reason, Delivery} ->
                    Record = delivery_record(Summary, Delivery),
                    store(Record),
                    {error, Reason}
            end;
        static ->
            Delivery = deliver_command(Command),
            Record = delivery_record(Summary, Delivery),
            store(Record),
            {ok, Record, undefined};
        {error, Reason} ->
            {error, Reason}
    end.

delivery_route(#{operation := upsert, desired_state := Desired}) when is_map(Desired) ->
    case maps:get(device_id, Desired, undefined) of
        undefined -> static;
        DeviceId ->
            case ias_vpn_dynamic_pair:delivery_mode(DeviceId) of
                dynamic -> {dynamic, normalize_id(DeviceId)};
                static -> static;
                {error, _Reason} = Error -> Error
            end
    end;
delivery_route(_Command) ->
    static.

deliver_command(Command) ->
    case transport() of
        disabled ->
            #{delivery_status => disabled, vpn_result => disabled};
        erlang_rpc ->
            normalize_rpc_result(call_vpn(Command));
        Transport ->
            #{delivery_status => transport_error,
              vpn_result => {unsupported_transport, Transport}}
    end.

deliver_dynamic_command(DeviceId, Command) ->
    case transport() of
        disabled ->
            {ok, #{delivery_status => disabled, vpn_result => disabled}, undefined};
        erlang_rpc ->
            normalize_dynamic_rpc_result(DeviceId,
                                         Command,
                                         call_vpn_dynamic(DeviceId, Command));
        Transport ->
            {ok, #{delivery_status => transport_error,
                   vpn_result => {unsupported_transport, Transport}},
             undefined}
    end.

call_vpn(Command) ->
    case rpc_fun() of
        Fun when is_function(Fun, 5) ->
            Fun(vpn_node(), vpn_provisioning, apply, [Command], rpc_timeout());
        undefined ->
            rpc:call(vpn_node(), vpn_provisioning, apply, [Command], rpc_timeout())
    end.

call_vpn_dynamic(DeviceId, Command) ->
    case rpc_fun() of
        Fun when is_function(Fun, 5) ->
            Fun(vpn_node(),
                vpn_provisioning,
                apply_dynamic,
                [DeviceId, Command],
                dynamic_rpc_timeout());
        undefined ->
            rpc:call(vpn_node(),
                     vpn_provisioning,
                     apply_dynamic,
                     [DeviceId, Command],
                     dynamic_rpc_timeout())
    end.

normalize_dynamic_rpc_result(DeviceId, Command, {ok, unchanged}) ->
    case ias_vpn_dynamic_pair:needs_binding_recovery(DeviceId) of
        false ->
            {ok, #{delivery_status => unchanged, vpn_result => unchanged}, undefined};
        true ->
            recover_dynamic_binding(DeviceId, Command);
        {error, Reason} ->
            {error,
             Reason,
             #{delivery_status => unexpected_result,
               vpn_result => {dynamic_pair_binding_state_invalid,
                              sanitize_scalar(Reason)}}}
    end;
normalize_dynamic_rpc_result(DeviceId,
                             Command,
                             {ok, #{operation := upsert, pair := PairStatus}})
  when is_map(PairStatus) ->
    case ias_vpn_dynamic_pair:accept(DeviceId, Command, PairStatus) of
        {ok, SafePair} ->
            {ok, #{delivery_status => applied,
                   vpn_result => {ok, #{operation => upsert,
                                       pair => SafePair}}},
             SafePair};
        {error, Reason} ->
            {error,
             Reason,
             #{delivery_status => unexpected_result,
               vpn_result => {invalid_dynamic_pair_result,
                              sanitize_scalar(Reason)}}}
    end;
normalize_dynamic_rpc_result(_DeviceId, _Command, {ok, Other}) ->
    {error,
     invalid_vpn_dynamic_pair_result,
     #{delivery_status => unexpected_result,
       vpn_result => sanitize_vpn_result({ok, Other})}};
normalize_dynamic_rpc_result(_DeviceId, _Command, Result) ->
    {ok, normalize_rpc_result(Result), undefined}.

recover_dynamic_binding(DeviceId, Command) ->
    case call_vpn_dynamic_status(DeviceId) of
        {ok, PairStatus} when is_map(PairStatus) ->
            case ias_vpn_dynamic_pair:accept(DeviceId, Command, PairStatus) of
                {ok, SafePair} ->
                    {ok, #{delivery_status => unchanged,
                           vpn_result => unchanged},
                     SafePair};
                {error, Reason} ->
                    binding_recovery_error(Reason)
            end;
        Other ->
            binding_recovery_error({unexpected_vpn_dynamic_pair_status_result,
                                    sanitize_vpn_result(Other)})
    end.

binding_recovery_error(Reason) ->
    {error,
     {vpn_dynamic_pair_binding_recovery_failed, Reason},
     #{delivery_status => unexpected_result,
       vpn_result => {dynamic_pair_binding_recovery_failed,
                      sanitize_scalar(Reason)}}}.

call_vpn_dynamic_status(DeviceId) ->
    case rpc_fun() of
        Fun when is_function(Fun, 5) ->
            Fun(vpn_node(),
                vpn_dynamic_pair,
                status,
                [DeviceId],
                dynamic_rpc_timeout());
        undefined ->
            rpc:call(vpn_node(),
                     vpn_dynamic_pair,
                     status,
                     [DeviceId],
                     dynamic_rpc_timeout())
    end.

normalize_rpc_result({ok, unchanged}) ->
    #{delivery_status => unchanged, vpn_result => unchanged};
normalize_rpc_result({ok, Result}) ->
    #{delivery_status => applied, vpn_result => sanitize_vpn_result({ok, Result})};
normalize_rpc_result({error, _Reason} = Result) ->
    #{delivery_status => rejected, vpn_result => sanitize_vpn_result(Result)};
normalize_rpc_result({badrpc, timeout}) ->
    #{delivery_status => timeout, vpn_result => timeout};
normalize_rpc_result({badrpc, nodedown}) ->
    #{delivery_status => node_unavailable, vpn_result => nodedown};
normalize_rpc_result({badrpc, Reason}) ->
    #{delivery_status => transport_error,
      vpn_result => sanitize_vpn_result({badrpc, Reason})};
normalize_rpc_result(Result) ->
    #{delivery_status => unexpected_result,
      vpn_result => sanitize_vpn_result(Result)}.

delivery_record(Summary, Delivery) ->
    Summary#{
        delivery_status => maps:get(delivery_status, Delivery),
        vpn_result => maps:get(vpn_result, Delivery),
        delivered_at => delivered_at()
    }.

store(Record) ->
    DeviceKey = normalize_id(maps:get(device_id, Record, undefined)),
    Existing = history(DeviceKey),
    true = ets:insert(?TABLE, {DeviceKey, [Record | Existing]}),
    ok.

sanitize_vpn_result({ok, #{operation := Operation, peer := Peer}}) ->
    {ok, #{operation => Operation, peer => sanitize_peer(Peer)}};
sanitize_vpn_result({ok, #{operation := Operation, pair := Pair}}) ->
    {ok, #{operation => Operation, pair => sanitize_pair(Pair)}};
sanitize_vpn_result({error, Reason}) when is_atom(Reason); is_binary(Reason) ->
    {error, Reason};
sanitize_vpn_result({badrpc, Reason}) when is_atom(Reason); is_binary(Reason) ->
    {badrpc, Reason};
sanitize_vpn_result(unchanged) ->
    unchanged;
sanitize_vpn_result(timeout) ->
    timeout;
sanitize_vpn_result(nodedown) ->
    nodedown;
sanitize_vpn_result(Map) when is_map(Map) ->
    maps:map(fun(_Key, Value) -> sanitize_scalar(Value) end, maps:with([operation], Map));
sanitize_vpn_result(Other) ->
    sanitize_scalar(Other).

sanitize_pair(Pair) when is_map(Pair) ->
    Base = maps:with([allocation_id,
                      allocator_instance_id,
                      device_id,
                      client_peer_id,
                      gateway_peer_id,
                      state,
                      outcome],
                     Pair),
    maybe_put(gateway,
              sanitize_pair_side(maps:get(gateway, Pair, undefined)),
              maybe_put(client,
                        sanitize_pair_side(maps:get(client, Pair, undefined)),
                        Base));
sanitize_pair(_Pair) ->
    #{}.

sanitize_pair_side(Side) when is_map(Side) ->
    Registry = maps:get(registry, Side, #{}),
    #{peer_id => maps:get(peer_id, Side, undefined),
      running => maps:get(running, Side, undefined),
      handshake_status => maps:get(handshake_status, Side, undefined),
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
                            Registry)};
sanitize_pair_side(_Side) ->
    undefined.

sanitize_peer(Peer) when is_map(Peer) ->
    maps:with([id,
               enabled,
               provisioning_source,
               device_id,
               authorization_mode,
               authorized,
               authorization_reason,
               profile_id,
               certificate_fingerprint,
               revision,
               revoked,
               last_provisioning_operation,
               updated_at],
              Peer);
sanitize_peer(_Peer) ->
    #{}.

sanitize_scalar(Value) when is_atom(Value); is_binary(Value); is_integer(Value);
                           is_boolean(Value) ->
    Value;
sanitize_scalar(Value) when is_list(Value) ->
    [sanitize_scalar(Item) || Item <- Value];
sanitize_scalar(_Value) ->
    undefined.

ensure() ->
    case ets:info(?TABLE) of
        undefined -> ensure_owner();
        _ -> ok
    end.

ensure_owner() ->
    case whereis(?OWNER) of
        undefined ->
            Parent = self(),
            Pid = spawn(fun() -> owner(Parent) end),
            receive
                {Pid, ready} -> ok
            after 5000 ->
                exit({vpn_provisioning_delivery_start_timeout, Pid})
            end;
        _Pid ->
            wait_for_table(50)
    end.

owner(Parent) ->
    case catch register(?OWNER, self()) of
        true ->
            _ = ets:new(?TABLE, [named_table, public, set,
                                 {read_concurrency, true},
                                 {write_concurrency, true}]),
            Parent ! {self(), ready},
            owner_loop();
        _ ->
            Parent ! {self(), ready}
    end.

owner_loop() ->
    receive
        stop -> ok;
        _ -> owner_loop()
    end.

wait_for_table(0) -> ok;
wait_for_table(Attempts) ->
    case ets:info(?TABLE) of
        undefined -> timer:sleep(10), wait_for_table(Attempts - 1);
        _ -> ok
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

dynamic_rpc_timeout() ->
    application:get_env(ias,
                        vpn_dynamic_pair_rpc_timeout,
                        ?DEFAULT_DYNAMIC_TIMEOUT).

rpc_fun() ->
    case application:get_env(ias, vpn_provisioning_rpc_fun) of
        {ok, Fun} when is_function(Fun, 5) -> Fun;
        _ -> undefined
    end.

normalize_id(undefined) ->
    undefined;
normalize_id(Id) ->
    ias_html:text(Id).

delivered_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
