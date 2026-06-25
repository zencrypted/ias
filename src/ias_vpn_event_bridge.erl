%%%-------------------------------------------------------------------
%% @doc Bridges VPN runtime completion events to active IAS VPN pages.
%%
%% The VPN event payload is only a wake-up notification. After every accepted
%% event this process reads the current runtime summary through the existing IAS
%% client and pushes the fresh snapshot to local N2O websocket processes.
%%%-------------------------------------------------------------------
-module(ias_vpn_event_bridge).

-behaviour(gen_server).

-export([start_link/0,
         start_link/1,
         subscribe/1,
         unsubscribe/1,
         status/0]).
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2]).

-define(SERVER, ?MODULE).
-define(DEFAULT_RETRY_MS, 5000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, #{}, []).

%% Unregistered start is useful for isolated contract tests.
start_link(Options) when is_map(Options) ->
    gen_server:start_link(?MODULE, Options, []).

subscribe(SubscriberPid) when is_pid(SubscriberPid) ->
    call_server({subscribe, SubscriberPid});
subscribe(_SubscriberPid) ->
    {error, invalid_subscriber}.

unsubscribe(SubscriberPid) when is_pid(SubscriberPid) ->
    call_server({unsubscribe, SubscriberPid});
unsubscribe(_SubscriberPid) ->
    {error, invalid_subscriber}.

status() ->
    call_server(status).

call_server(Request) ->
    case whereis(?SERVER) of
        undefined -> {error, not_started};
        _Pid -> gen_server:call(?SERVER, Request)
    end.

init(Options) ->
    State = #{vpn_node => option(vpn_node,
                                  Options,
                                  application:get_env(ias,
                                                      vpn_provisioning_vpn_node,
                                                      undefined)),
              rpc_timeout => option(rpc_timeout,
                                    Options,
                                    application:get_env(ias,
                                                        vpn_provisioning_rpc_timeout,
                                                        5000)),
              retry_ms => option(retry_ms,
                                 Options,
                                 application:get_env(ias,
                                                     vpn_event_retry_interval_ms,
                                                     ?DEFAULT_RETRY_MS)),
              rpc_fun => option(rpc_fun, Options, fun rpc:call/5),
              summary_fun => option(summary_fun,
                                    Options,
                                    fun ias_vpn_runtime:summary/0),
              connected => false,
              ever_connected => false,
              stream_id => undefined,
              sequence => undefined,
              remote_bus_pid => undefined,
              remote_monitor_ref => undefined,
              retry_ref => undefined,
              last_event => undefined,
              last_event_at => undefined,
              last_error => undefined,
              snapshot_status => not_loaded,
              last_snapshot_at => undefined,
              last_snapshot_error => undefined,
              sync_reason => starting,
              subscribers => #{},
              monitors => #{}},
    self() ! connect,
    {ok, State}.

handle_call({subscribe, SubscriberPid}, _From, State0) ->
    Subscribers0 = maps:get(subscribers, State0),
    case maps:find(SubscriberPid, Subscribers0) of
        {ok, _MonitorRef} ->
            {reply, {ok, public_status(State0)}, State0};
        error ->
            MonitorRef = erlang:monitor(process, SubscriberPid),
            State1 = State0#{
                       subscribers => Subscribers0#{SubscriberPid => MonitorRef},
                       monitors => (maps:get(monitors, State0))#{MonitorRef => SubscriberPid}},
            {reply, {ok, public_status(State1)}, State1}
    end;
handle_call({unsubscribe, SubscriberPid}, _From, State0) ->
    {reply, ok, remove_local_subscriber(SubscriberPid, State0)};
handle_call(status, _From, State) ->
    {reply, public_status(State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_operation}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(connect, #{connected := true} = State0) ->
    %% A cancelled retry can already be in the mailbox when nodeup reconnects.
    %% Ignore that stale timer instead of resubscribing and repainting again.
    {noreply, State0#{retry_ref => undefined}};
handle_info(connect, State0) ->
    State1 = State0#{retry_ref => undefined},
    {noreply, connect_remote(State1)};
handle_info({vpn_event, Event}, State0) when is_map(Event) ->
    {noreply, accept_remote_event(Event, State0)};
handle_info({'DOWN', MonitorRef, process, _Pid, Reason}, State0) ->
    case MonitorRef =:= maps:get(remote_monitor_ref, State0, undefined) of
        true ->
            DisconnectReason = {vpn_event_bus_down, Reason},
            State1 = mark_disconnected(DisconnectReason, State0),
            maybe_broadcast_status_change(State0, State1),
            {noreply, reconnect_after_failure(DisconnectReason, State1)};
        false ->
            {noreply, remove_local_monitor(MonitorRef, State0)}
    end;
handle_info({nodedown, VpnNode}, #{vpn_node := VpnNode} = State0) ->
    State1 = mark_disconnected(vpn_node_down, State0),
    maybe_broadcast_status_change(State0, State1),
    %% nodeup triggers an immediate reconnect. Keep the timer only as a quiet
    %% safety net because distributed Erlang does not discover a restarted node
    %% until some connection attempt is made.
    {noreply, schedule_retry(State1)};
handle_info({nodeup, VpnNode}, #{vpn_node := VpnNode,
                                connected := false} = State0) ->
    {noreply, schedule_connect_now(State0)};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = unsubscribe_remote(State),
    _ = disable_node_monitor(State),
    ok.

option(Key, Options, Default) ->
    maps:get(Key, Options, Default).

connect_remote(#{vpn_node := undefined} = State0) ->
    State1 = mark_disconnected(vpn_node_not_configured, State0),
    maybe_broadcast_status_change(State0, State1),
    schedule_retry(State1);
connect_remote(State0) ->
    State1 = clear_remote_monitor(State0),
    VpnNode = maps:get(vpn_node, State1),
    _ = enable_node_monitor(VpnNode),
    case remote_subscribe(State1) of
        {ok, Subscription, RemoteBusPid} ->
            MonitorRef = erlang:monitor(process, RemoteBusPid),
            Reconnected = maps:get(ever_connected, State1),
            SyncReason = case Reconnected of
                             true -> reconnected;
                             false -> subscribed
                         end,
            State2 = State1#{connected => true,
                             ever_connected => true,
                             stream_id => maps:get(stream_id,
                                                   Subscription,
                                                   undefined),
                             sequence => maps:get(sequence,
                                                  Subscription,
                                                  undefined),
                             remote_bus_pid => RemoteBusPid,
                             remote_monitor_ref => MonitorRef,
                             last_error => undefined,
                             sync_reason => SyncReason},
            Summary = read_summary(State2),
            publish_snapshot_result(SyncReason, Summary, State2);
        {error, Reason} ->
            State2 = mark_disconnected(Reason, State1),
            maybe_broadcast_status_change(State0, State2),
            reconnect_after_failure(Reason, State2)
    end.

remote_subscribe(State) ->
    VpnNode = maps:get(vpn_node, State),
    Timeout = maps:get(rpc_timeout, State),
    case rpc_call(State,
                  VpnNode,
                  vpn_event_bus,
                  subscribe,
                  [self()],
                  Timeout) of
        {ok, _InitialSubscription} ->
            case rpc_call(State,
                          VpnNode,
                          erlang,
                          whereis,
                          [vpn_event_bus],
                          Timeout) of
                RemoteBusPid when is_pid(RemoteBusPid) ->
                    %% Subscribe once more after resolving the process PID. If
                    %% the event bus restarted between the first call and the
                    %% lookup, this idempotent call binds us to the new stream.
                    case rpc_call(State,
                                  VpnNode,
                                  vpn_event_bus,
                                  subscribe,
                                  [self()],
                                  Timeout) of
                        {ok, Subscription} when is_map(Subscription) ->
                            {ok, Subscription, RemoteBusPid};
                        Other ->
                            {error, {vpn_event_subscribe_failed, Other}}
                    end;
                Other ->
                    {error, {vpn_event_bus_unavailable, Other}}
            end;
        Other ->
            {error, {vpn_event_subscribe_failed, Other}}
    end.

accept_remote_event(Event, State0) ->
    case event_order(Event, State0) of
        duplicate ->
            State0;
        {accept, SyncReason} ->
            Summary = read_summary(State0),
            State1 = State0#{connected => true,
                             ever_connected => true,
                             stream_id => maps:get(stream_id,
                                                   Event,
                                                   maps:get(stream_id,
                                                            State0,
                                                            undefined)),
                             sequence => maps:get(sequence,
                                                  Event,
                                                  maps:get(sequence,
                                                           State0,
                                                           undefined)),
                             last_event => Event,
                             last_event_at => erlang:system_time(millisecond),
                             last_error => undefined,
                             sync_reason => SyncReason},
            publish_event_result(Event, Summary, State1);
        {reject, Reason} ->
            State0#{last_error => Reason,
                    sync_reason => invalid_event}
    end.


publish_snapshot_result(SyncReason, {ok, SummaryData} = Summary, State0)
  when is_map(SummaryData) ->
    State1 = mark_snapshot_fresh(State0),
    broadcast({vpn_runtime_snapshot,
               SyncReason,
               Summary,
               public_status(State1)},
              State1),
    State1;
publish_snapshot_result(SyncReason, Summary, State0) ->
    State1 = mark_snapshot_unavailable(Summary, State0),
    broadcast({vpn_runtime_snapshot_failed,
               SyncReason,
               Summary,
               public_status(State1)},
              State1),
    State1.

publish_event_result(Event, {ok, SummaryData} = Summary, State0)
  when is_map(SummaryData) ->
    State1 = mark_snapshot_fresh(State0),
    broadcast({vpn_runtime_event,
               Event,
               Summary,
               public_status(State1)},
              State1),
    State1;
publish_event_result(Event, Summary, State0) ->
    State1 = mark_snapshot_unavailable(Summary, State0),
    broadcast({vpn_runtime_snapshot_failed,
               Event,
               Summary,
               public_status(State1)},
              State1),
    State1.

mark_snapshot_fresh(State) ->
    State#{snapshot_status => fresh,
           last_snapshot_at => erlang:system_time(millisecond),
           last_snapshot_error => undefined}.

mark_snapshot_unavailable(Summary, State) ->
    State#{snapshot_status => unavailable,
           last_snapshot_error => snapshot_error(Summary)}.

snapshot_error({error, Reason}) ->
    Reason;
snapshot_error({ok, Value}) ->
    {invalid_summary, Value};
snapshot_error(Value) ->
    Value.

event_order(#{schema_version := 1,
              type := runtime_reconciled,
              stream_id := EventStream,
              sequence := EventSequence},
            State)
  when is_integer(EventSequence), EventSequence >= 0 ->
    CurrentStream = maps:get(stream_id, State, undefined),
    CurrentSequence = maps:get(sequence, State, undefined),
    case {CurrentStream, CurrentSequence} of
        {undefined, _} -> {accept, first_event};
        {EventStream, Sequence} when is_integer(Sequence),
                                    EventSequence =< Sequence -> duplicate;
        {EventStream, Sequence} when is_integer(Sequence),
                                    EventSequence =:= Sequence + 1 -> {accept, event};
        {EventStream, Sequence} when is_integer(Sequence),
                                    EventSequence > Sequence + 1 -> {accept, sequence_gap};
        {EventStream, _Sequence} -> {accept, event};
        {_OtherStream, _Sequence} -> {accept, stream_reset}
    end;
event_order(Event, _State) ->
    {reject, {invalid_vpn_event, maps:with([schema_version,
                                           type,
                                           stream_id,
                                           sequence],
                                          Event)}}.

read_summary(State) ->
    SummaryFun = maps:get(summary_fun, State),
    try SummaryFun() of
        Result -> Result
    catch
        Class:Reason -> {error, {summary_failed, Class, Reason}}
    end.

rpc_call(State, Node, Module, Function, Arguments, Timeout) ->
    RpcFun = maps:get(rpc_fun, State),
    try RpcFun(Node, Module, Function, Arguments, Timeout) of
        Result -> Result
    catch
        Class:Reason -> {badrpc, {Class, Reason}}
    end.

broadcast(Payload, State) ->
    maps:foreach(fun(SubscriberPid, _MonitorRef) ->
                         SubscriberPid ! {direct, Payload}
                 end,
                 maps:get(subscribers, State)),
    ok.

maybe_broadcast_status_change(State0, State1) ->
    case status_transition_key(State0) =:= status_transition_key(State1) of
        true -> ok;
        false -> broadcast({vpn_runtime_event_status, public_status(State1)}, State1)
    end.

%% Retry details such as the most recent RPC error are useful through status/0,
%% but they are not UI state transitions. Keeping them out of this key prevents
%% an unavailable VPN node from repainting every subscribed page on each retry.
status_transition_key(State) ->
    {maps:get(connected, State, false),
     maps:get(snapshot_status, State, not_loaded),
     maps:get(sync_reason, State, starting)}.

reconnect_after_failure(_Reason, State) ->
    %% Retry is a backend recovery mechanism, not a UI notification. nodeup
    %% cancels this timer and reconnects immediately when distribution notices
    %% the node first; otherwise the timer itself re-establishes the connection.
    schedule_retry(State).

mark_disconnected(Reason, State0) ->
    State1 = clear_remote_monitor(State0),
    SnapshotStatus = case maps:get(snapshot_status, State1, not_loaded) of
                         fresh -> stale;
                         Current -> Current
                     end,
    State1#{connected => false,
            remote_bus_pid => undefined,
            remote_monitor_ref => undefined,
            last_error => normalize_disconnect_reason(Reason),
            snapshot_status => SnapshotStatus,
            sync_reason => disconnected}.

normalize_disconnect_reason(Reason) ->
    case contains_node_disconnect(Reason) of
        true -> vpn_node_down;
        false -> Reason
    end.

contains_node_disconnect(nodedown) ->
    true;
contains_node_disconnect(noconnection) ->
    true;
contains_node_disconnect(Reason) when is_tuple(Reason) ->
    lists:any(fun contains_node_disconnect/1, tuple_to_list(Reason));
contains_node_disconnect(Reason) when is_list(Reason) ->
    lists:any(fun contains_node_disconnect/1, Reason);
contains_node_disconnect(_Reason) ->
    false.

clear_remote_monitor(State0) ->
    case maps:get(remote_monitor_ref, State0, undefined) of
        undefined -> State0;
        MonitorRef ->
            _ = erlang:demonitor(MonitorRef, [flush]),
            State0#{remote_monitor_ref => undefined,
                    remote_bus_pid => undefined}
    end.

schedule_retry(#{retry_ref := undefined} = State0) ->
    RetryRef = erlang:send_after(maps:get(retry_ms, State0), self(), connect),
    State0#{retry_ref => RetryRef};
schedule_retry(State) ->
    State.

schedule_connect_now(State0) ->
    State1 = cancel_retry(State0),
    self() ! connect,
    State1.

cancel_retry(State0) ->
    case maps:get(retry_ref, State0, undefined) of
        undefined -> State0;
        RetryRef ->
            _ = erlang:cancel_timer(RetryRef),
            State0#{retry_ref => undefined}
    end.

remove_local_subscriber(SubscriberPid, State0) ->
    Subscribers0 = maps:get(subscribers, State0),
    case maps:take(SubscriberPid, Subscribers0) of
        {MonitorRef, Subscribers1} ->
            _ = erlang:demonitor(MonitorRef, [flush]),
            State0#{subscribers => Subscribers1,
                    monitors => maps:remove(MonitorRef,
                                            maps:get(monitors, State0))};
        error ->
            State0
    end.

remove_local_monitor(MonitorRef, State0) ->
    Monitors0 = maps:get(monitors, State0),
    case maps:take(MonitorRef, Monitors0) of
        {SubscriberPid, Monitors1} ->
            State0#{subscribers => maps:remove(SubscriberPid,
                                               maps:get(subscribers, State0)),
                    monitors => Monitors1};
        error ->
            State0
    end.

unsubscribe_remote(#{connected := true,
                     vpn_node := VpnNode} = State) ->
    rpc_call(State,
             VpnNode,
             vpn_event_bus,
             unsubscribe,
             [self()],
             maps:get(rpc_timeout, State));
unsubscribe_remote(_State) ->
    ok.

enable_node_monitor(VpnNode) when is_atom(VpnNode) ->
    case VpnNode =:= node() of
        true -> ok;
        false -> erlang:monitor_node(VpnNode, true)
    end;
enable_node_monitor(_VpnNode) ->
    ok.

disable_node_monitor(#{vpn_node := VpnNode}) when is_atom(VpnNode) ->
    case VpnNode =:= node() of
        true -> ok;
        false -> erlang:monitor_node(VpnNode, false)
    end;
disable_node_monitor(_State) ->
    ok.

public_status(State) ->
    #{connected => maps:get(connected, State),
      vpn_node => maps:get(vpn_node, State),
      stream_id => maps:get(stream_id, State),
      sequence => maps:get(sequence, State),
      last_event_at => maps:get(last_event_at, State),
      last_error => maps:get(last_error, State),
      snapshot_status => maps:get(snapshot_status, State),
      last_snapshot_at => maps:get(last_snapshot_at, State),
      last_snapshot_error => maps:get(last_snapshot_error, State),
      sync_reason => maps:get(sync_reason, State),
      subscriber_count => map_size(maps:get(subscribers, State))}.
