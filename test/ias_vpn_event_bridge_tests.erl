-module(ias_vpn_event_bridge_tests).

-include_lib("eunit/include/eunit.hrl").

event_bridge_pushes_fresh_runtime_snapshots_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(#{bridge := BridgePid,
           bus := BusPid,
           stream_id := StreamId,
           summary := Summary}) ->
             [?_test(begin
                          ?assert(wait_until(
                                    fun() ->
                                            case gen_server:call(BridgePid,
                                                                 status) of
                                                #{connected := true} -> true;
                                                _ -> false
                                            end
                                    end,
                                    100)),
                          {ok, SubscriptionStatus} =
                              gen_server:call(BridgePid,
                                              {subscribe, self()}),
                          ?assertEqual(true,
                                       maps:get(connected,
                                                SubscriptionStatus)),

                          %% A retry message that was already queued before a
                          %% successful nodeup reconnect must be harmless.
                          BridgePid ! connect,
                          receive
                              {direct, StaleRetryUpdate} ->
                                  error({stale_retry_repaint,
                                         StaleRetryUpdate})
                          after 50 ->
                              ok
                          end,

                          Event1 = #{schema_version => 1,
                                     type => runtime_reconciled,
                                     stream_id => StreamId,
                                     sequence => 1,
                                     result => #{outcome => ok,
                                                 peer_ids => [peer_a]}},
                          BridgePid ! {vpn_event, Event1},
                          receive
                              {direct,
                               {vpn_runtime_event,
                                Event1,
                                Summary,
                                EventStatus1}} ->
                                  ?assertEqual(1,
                                               maps:get(sequence,
                                                        EventStatus1)),
                                  ?assertEqual(event,
                                               maps:get(sync_reason,
                                                        EventStatus1))
                          after 1000 ->
                              error(vpn_runtime_event_timeout)
                          end,

                          %% Duplicate/out-of-order delivery must not repaint
                          %% the page with an older snapshot.
                          BridgePid ! {vpn_event, Event1},
                          receive
                              {direct, {vpn_runtime_event, _, _, _}} ->
                                  error(duplicate_vpn_runtime_event)
                          after 50 ->
                              ok
                          end,

                          ManualEvent = #{schema_version => 1,
                                          type => peer_runtime_changed,
                                          stream_id => StreamId,
                                          sequence => 2,
                                          source => external_command,
                                          action => stop,
                                          peer_id => peer_a},
                          BridgePid ! {vpn_event, ManualEvent},
                          receive
                              {direct,
                               {vpn_runtime_event,
                                ManualEvent,
                                Summary,
                                ManualEventStatus}} ->
                                  ?assertEqual(2,
                                               maps:get(sequence,
                                                        ManualEventStatus)),
                                  ?assertEqual(event,
                                               maps:get(sync_reason,
                                                        ManualEventStatus))
                          after 1000 ->
                              error(vpn_peer_runtime_changed_event_timeout)
                          end,

                          Event3 = Event1#{sequence => 4},
                          BridgePid ! {vpn_event, Event3},
                          receive
                              {direct,
                               {vpn_runtime_event,
                                Event3,
                                Summary,
                                EventStatus3}} ->
                                  ?assertEqual(sequence_gap,
                                               maps:get(sync_reason,
                                                        EventStatus3))
                          after 1000 ->
                              error(vpn_runtime_gap_event_timeout)
                          end,

                          exit(BusPid, kill),
                          receive
                              {direct,
                               {vpn_runtime_event_status,
                                #{connected := false,
                                  snapshot_status := stale,
                                  last_error := {vpn_event_bus_down, _}}}} ->
                                  ok
                          after 1000 ->
                              error(vpn_runtime_disconnect_timeout)
                          end,

                          %% The bridge may retry quietly when the event bus can
                          %% recover without a node transition, but the same
                          %% disconnected state must not repaint the page again.
                          receive
                              {direct, DuplicateDisconnectUpdate} ->
                                  error({duplicate_vpn_disconnect_update,
                                         DuplicateDisconnectUpdate})
                          after 150 ->
                              ok
                          end
                      end)]
     end}.



event_bridge_keeps_subscription_connected_when_snapshot_load_fails_test_() ->
    {setup,
     fun setup_snapshot_failure/0,
     fun cleanup/1,
     fun(#{bridge := BridgePid}) ->
             [?_test(begin
                          ?assert(wait_until(
                                    fun() ->
                                            case gen_server:call(BridgePid,
                                                                 status) of
                                                #{connected := true,
                                                  snapshot_status := unavailable,
                                                  last_snapshot_error := snapshot_rpc_failed} ->
                                                    true;
                                                _ ->
                                                    false
                                            end
                                    end,
                                    100)),
                          Status = gen_server:call(BridgePid, status),
                          ?assertEqual(true, maps:get(connected, Status)),
                          ?assertEqual(unavailable,
                                       maps:get(snapshot_status, Status)),
                          ?assertEqual(snapshot_rpc_failed,
                                       maps:get(last_snapshot_error, Status))
                      end)]
     end}.

setup() ->
    TestPid = self(),
    BusPid = spawn(fun bus_loop/0),
    StreamId = {vpn_test_stream, 1},
    Summary = {ok, #{<<"counts">> => #{<<"configured">> => 1,
                                           <<"running">> => 1},
                     <<"peers">> => [#{<<"id">> => <<"peer_a">>,
                                        <<"running">> => true}]}},
    RpcFun = fun(_Node,
                 vpn_event_bus,
                 subscribe,
                 [SubscriberPid],
                 _Timeout) ->
                     case erlang:is_process_alive(BusPid) of
                         true ->
                             TestPid ! {remote_subscribed, SubscriberPid},
                             {ok, #{schema_version => 1,
                                    stream_id => StreamId,
                                    sequence => 0}};
                         false ->
                             {badrpc, nodedown}
                     end;
                (_Node,
                 erlang,
                 whereis,
                 [vpn_event_bus],
                 _Timeout) ->
                     BusPid;
                (_Node,
                 vpn_event_bus,
                 unsubscribe,
                 [SubscriberPid],
                 _Timeout) ->
                     TestPid ! {remote_unsubscribed, SubscriberPid},
                     ok
             end,
    SummaryFun = fun() -> Summary end,
    {ok, BridgePid} = ias_vpn_event_bridge:start_link(
                        #{vpn_node => node(),
                          rpc_timeout => 100,
                          retry_ms => 20,
                          rpc_fun => RpcFun,
                          summary_fun => SummaryFun}),
    #{bridge => BridgePid,
      bus => BusPid,
      stream_id => StreamId,
      summary => Summary}.


setup_snapshot_failure() ->
    TestPid = self(),
    BusPid = spawn(fun bus_loop/0),
    StreamId = {vpn_test_stream, snapshot_failure},
    RpcFun = fun(_Node,
                 vpn_event_bus,
                 subscribe,
                 [SubscriberPid],
                 _Timeout) ->
                     TestPid ! {remote_subscribed, SubscriberPid},
                     {ok, #{schema_version => 1,
                            stream_id => StreamId,
                            sequence => 0}};
                (_Node,
                 erlang,
                 whereis,
                 [vpn_event_bus],
                 _Timeout) ->
                     BusPid;
                (_Node,
                 vpn_event_bus,
                 unsubscribe,
                 [SubscriberPid],
                 _Timeout) ->
                     TestPid ! {remote_unsubscribed, SubscriberPid},
                     ok
             end,
    SummaryFun = fun() -> {error, snapshot_rpc_failed} end,
    {ok, BridgePid} = ias_vpn_event_bridge:start_link(
                        #{vpn_node => node(),
                          rpc_timeout => 100,
                          retry_ms => 1000,
                          rpc_fun => RpcFun,
                          summary_fun => SummaryFun}),
    #{bridge => BridgePid,
      bus => BusPid}.

cleanup(#{bridge := BridgePid,
          bus := BusPid}) ->
    _ = catch gen_server:call(BridgePid, {unsubscribe, self()}),
    case is_process_alive(BridgePid) of
        true ->
            unlink(BridgePid),
            exit(BridgePid, shutdown),
            wait_until_stopped(BridgePid, 50);
        false -> ok
    end,
    case is_process_alive(BusPid) of
        true -> exit(BusPid, kill);
        false -> ok
    end,
    flush_test_messages(),
    ok.

bus_loop() ->
    receive
        stop -> ok
    end.

wait_until(_Fun, 0) -> false;
wait_until(Fun, Attempts) ->
    case Fun() of
        true -> true;
        false -> timer:sleep(10), wait_until(Fun, Attempts - 1)
    end.

wait_until_stopped(_Pid, 0) -> ok;
wait_until_stopped(Pid, Attempts) ->
    case is_process_alive(Pid) of
        false -> ok;
        true -> timer:sleep(10), wait_until_stopped(Pid, Attempts - 1)
    end.

flush_test_messages() ->
    receive
        {remote_subscribed, _} -> flush_test_messages();
        {remote_unsubscribed, _} -> flush_test_messages();
        {direct, _} -> flush_test_messages()
    after 0 ->
        ok
    end.
