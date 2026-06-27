-module(ias_vpn).
-export([event/1, content/1, content/3, create_vpn_service/4, create_vpn_service/6,
         runtime_status_panel/1, runtime_summary_panel/1,
         runtime_connection_notice_panel/2,
         reconciliation_stale_notice/1,
         reconciliation_panel/2]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    _ = subscribe_runtime_events(),
    render();
event(terminate) ->
    _ = unsubscribe_runtime_events(),
    ok;
event({exit, _Reason}) ->
    _ = unsubscribe_runtime_events(),
    ok;
event(refresh_vpn_runtime) ->
    Summary = ias_vpn_runtime:summary(),
    BridgeStatus = runtime_event_bridge_status(),
    update_runtime_manual_refresh(Summary, BridgeStatus);
event({vpn_runtime_snapshot, Reason, Summary, BridgeStatus}) ->
    update_runtime_ui(Summary, BridgeStatus),
    maybe_refresh_reconciliation_after_snapshot(Reason);
event({vpn_runtime_event, Event, Summary, BridgeStatus}) ->
    update_runtime_ui(Summary, BridgeStatus),
    mark_reconciliation_stale(Event);
event({vpn_runtime_snapshot_failed, Reason, SummaryError, BridgeStatus}) ->
    update_runtime_snapshot_failure_ui(SummaryError, BridgeStatus),
    mark_reconciliation_stale({snapshot_failed, Reason});
event({vpn_runtime_event_status, BridgeStatus}) ->
    update_runtime_event_status_ui(BridgeStatus);
event(refresh_vpn_reconciliation) ->
    update_reconciliation_ui({ok, refreshed});
event(safe_replay_all) ->
    update_reconciliation_ui(ias_vpn_reconciliation:replay());
event({safe_replay, DeviceId}) ->
    update_reconciliation_ui(ias_vpn_reconciliation:replay(DeviceId));
event(scan_vpn_incidents) ->
    update_reconciliation_ui(ias_vpn_reconciliation:scan_incidents());
event({acknowledge_vpn_incident, DeviceId, Token, ActorId, NoteId}) ->
    Actor = field_value(nitro:q(ActorId), <<"ias-ui-admin">>),
    Note = field_value(nitro:q(NoteId), <<>>),
    Result = ias_vpn_reconciliation:acknowledge_incident(DeviceId,
                                                          Token,
                                                          Actor,
                                                          Note),
    update_reconciliation_ui(Result);
event({resolve_vpn_incident, DeviceId, Token, ActorId, NoteId}) ->
    Actor = field_value(nitro:q(ActorId), <<"ias-ui-admin">>),
    Note = field_value(nitro:q(NoteId), <<>>),
    Result = ias_vpn_reconciliation:resolve_incident(DeviceId,
                                                      Token,
                                                      Actor,
                                                      Note),
    update_reconciliation_ui(Result);
event({confirm_decommission_vpn_orphan,
       DeviceId, Token, ActorId, NoteId}) ->
    nitro:wire(#confirm{
        text = orphan_decommission_confirm_text(DeviceId),
        postback = {decommission_vpn_orphan,
                    DeviceId, Token, ActorId, NoteId}});
event({decommission_vpn_orphan, DeviceId, Token, ActorId, NoteId}) ->
    Actor = field_value(nitro:q(ActorId), <<"ias-ui-admin">>),
    Note = field_value(nitro:q(NoteId), <<>>),
    Result = ias_vpn_reconciliation:decommission_orphan(DeviceId,
                                                         Token,
                                                         Actor,
                                                         Note),
    update_reconciliation_ui(Result);
event(create_vpn_service) ->
    Name = field_value(nitro:q(vpn_service_name), <<"OpenVPN">>),
    Host = field_value(nitro:q(vpn_remote_host), <<>>),
    Port = field_value(nitro:q(vpn_remote_port), <<"1194">>),
    Protocol = protocol_value(nitro:q(vpn_protocol)),
    PolicyId = optional_value(nitro:q(vpn_security_policy)),
    CaCertificateId = optional_value(nitro:q(vpn_ca_certificate)),
    Result = create_vpn_service(Name, Host, Port, Protocol, PolicyId, CaCertificateId),
    nitro:update(vpn_service_create_result, create_result(Result)),
    nitro:update(vpn_services_list, managed_services_panel());
event(_) ->
    ok.

render() ->
    logger:info("IAS VPN page init"),
    Summary = ias_vpn_runtime:summary(),
    {Reconciliation, Incidents} = reconciliation_state(),
    logger:info("IAS VPN summary result: ~p", [summary_shape(Summary)]),
    nitro:clear(stand),
    nitro:insert_bottom(stand, content(Summary, Reconciliation, Incidents)).

content(Summary) ->
    content(Summary,
            {error, reconciliation_not_loaded},
            {ok, []}).

content(Summary, Reconciliation, Incidents) ->
    BridgeStatus = runtime_event_bridge_status(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("VPN")},
        #p{body = ias_html:text("VPN runtime status, reconciliation, and manually managed VPN service definitions for IAS provisioning.")},
        create_service_panel(),
        #panel{id = vpn_services_list, body = managed_services_panel()},
        runtime_refresh_controls(Summary, BridgeStatus),
        runtime_connection_notice_panel(Summary, BridgeStatus),
        runtime_summary_panel(Summary),
        reconciliation_fragment(Reconciliation, Incidents, none)
    ]}.

runtime_refresh_controls(Summary, BridgeStatus) ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:12px 0 8px;">>,
           body = [
               runtime_status_panel(Summary, BridgeStatus),
               runtime_event_status_panel(BridgeStatus),
               #link{id = vpn_runtime_refresh_now,
                     class = [button, sgreen],
                     body = ias_html:text("Refresh now"),
                     postback = refresh_vpn_runtime}
           ]}.

runtime_status_panel(Summary) ->
    runtime_status_panel(Summary, #{}).

runtime_status_panel(Summary, BridgeStatus) ->
    #panel{id = vpn_runtime_refresh_status,
           style = <<"font-size:12px;color:#64748b;">>,
           body = runtime_status_text(Summary, BridgeStatus)}.

runtime_event_status_panel(Status) ->
    #panel{id = vpn_runtime_event_status,
           style = <<"font-size:12px;color:#64748b;">>,
           body = runtime_event_status(Status)}.

runtime_summary_panel(Summary) ->
    #panel{id = vpn_runtime_summary, body = render_summary(Summary)}.

runtime_connection_notice_panel(Summary, BridgeStatus) ->
    #panel{id = vpn_runtime_connection_notice,
           body = runtime_connection_notice(Summary, BridgeStatus)}.

runtime_status_text({ok, SummaryData} = Summary, _BridgeStatus)
  when is_map(SummaryData) ->
    refresh_status(Summary);
runtime_status_text(_Summary,
                    #{connected := false,
                      last_error := vpn_node_down}) ->
    <<"Runtime: disconnected | Showing last known snapshot">>;
runtime_status_text(_Summary, #{connected := false}) ->
    <<"Runtime: live status unavailable | Showing last known snapshot">>;
runtime_status_text({error, _Reason},
                    #{connected := true,
                      snapshot_status := unavailable}) ->
    <<"Runtime: snapshot unavailable | Last known data retained">>;
runtime_status_text(Summary, _BridgeStatus) ->
    refresh_status(Summary).

refresh_status({ok, Data}) when is_map(Data) ->
    ias_html:join([<<"Runtime: connected | Last update: ">>,
                   utc_time_text(),
                   <<" UTC">>]);
refresh_status(_) ->
    ias_html:join([<<"Runtime: unavailable | Last attempt: ">>,
                   utc_time_text(),
                   <<" UTC">>]).

runtime_event_status(#{connected := true, sequence := Sequence}) ->
    ias_html:join([<<"Updates: VPN event stream connected">>,
                   sequence_text(Sequence)]);
runtime_event_status(#{connected := false, last_error := Error}) ->
    ias_html:join([<<"Updates: event stream unavailable; use Refresh now">>,
                   event_error_text(Error)]);
runtime_event_status({error, not_started}) ->
    <<"Updates: IAS event bridge unavailable; use Refresh now">>;
runtime_event_status(_) ->
    <<"Updates: connecting to VPN event stream">>.

sequence_text(Sequence) when is_integer(Sequence) ->
    ias_html:join([<<" | Sequence: ">>, Sequence]);
sequence_text(_Sequence) ->
    <<>>.

event_error_text(undefined) ->
    <<>>;
event_error_text(_Error) ->
    <<" | retrying in background">>.

runtime_connection_notice({ok, SummaryData}, #{connected := false})
  when is_map(SummaryData) ->
    runtime_warning(
      "A fresh runtime snapshot was loaded manually, but live VPN event delivery is unavailable. IAS is reconnecting in the background; use Refresh now again if the data may have changed.");
runtime_connection_notice(_Summary,
                          #{connected := false,
                            last_error := vpn_node_down}) ->
    runtime_warning(
      "VPN runtime disconnected. The table below is the last known snapshot and may be stale. IAS is reconnecting in the background.");
runtime_connection_notice(_Summary, #{connected := false}) ->
    runtime_warning(
      "Live VPN event delivery is unavailable. The table below is the last known snapshot and may be stale. Use Refresh now for a manual check while IAS retries in the background.");
runtime_connection_notice(_Summary,
                          #{connected := true,
                            snapshot_status := unavailable,
                            last_snapshot_error := _Error}) ->
    runtime_warning(
      "The VPN event stream is connected, but IAS could not load a fresh runtime snapshot. Existing rows are retained as last known data; use Refresh now to retry.");
runtime_connection_notice({error, _Reason}, _BridgeStatus) ->
    runtime_warning(
      "No live VPN runtime snapshot is available. Start or reconnect VPN, then use Refresh now.");
runtime_connection_notice(_Summary, _BridgeStatus) ->
    [].

runtime_warning(Message) ->
    #panel{style = <<"margin:8px 0 10px;padding:10px 12px;border:1px solid #f59e0b;border-radius:6px;background:#fffbeb;color:#92400e;font-size:12px;">>,
           body = ias_html:text(Message)}.

utc_time_text() ->
    {{_Year, _Month, _Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    iolist_to_binary(io_lib:format("~2..0B:~2..0B:~2..0B", [Hour, Minute, Second])).

subscribe_runtime_events() ->
    try ias_vpn_event_bridge:subscribe(self())
    catch
        exit:_ -> {error, not_started}
    end.

unsubscribe_runtime_events() ->
    try ias_vpn_event_bridge:unsubscribe(self())
    catch
        exit:_ -> ok
    end.

runtime_event_bridge_status() ->
    try ias_vpn_event_bridge:status()
    catch
        exit:_ -> {error, not_started}
    end.

update_runtime_ui(Summary, BridgeStatus) ->
    nitro:update(vpn_runtime_refresh_status,
                 runtime_status_panel(Summary, BridgeStatus)),
    nitro:update(vpn_runtime_event_status,
                 runtime_event_status_panel(BridgeStatus)),
    nitro:update(vpn_runtime_connection_notice,
                 runtime_connection_notice_panel(Summary, BridgeStatus)),
    nitro:update(vpn_runtime_summary, runtime_summary_panel(Summary)).

update_runtime_manual_refresh({ok, SummaryData} = Summary, BridgeStatus)
  when is_map(SummaryData) ->
    update_runtime_ui(Summary, BridgeStatus);
update_runtime_manual_refresh(SummaryError, BridgeStatus) ->
    update_runtime_snapshot_failure_ui(SummaryError, BridgeStatus).

update_runtime_snapshot_failure_ui(SummaryError, BridgeStatus) ->
    nitro:update(vpn_runtime_refresh_status,
                 runtime_status_panel(SummaryError, BridgeStatus)),
    nitro:update(vpn_runtime_event_status,
                 runtime_event_status_panel(BridgeStatus)),
    nitro:update(vpn_runtime_connection_notice,
                 runtime_connection_notice_panel(SummaryError, BridgeStatus)).

update_runtime_event_status_ui(#{connected := false} = BridgeStatus) ->
    SummaryError = {error, runtime_snapshot_stale},
    update_runtime_snapshot_failure_ui(SummaryError, BridgeStatus),
    nitro:update(vpn_reconciliation_controls,
                 reconciliation_controls({error, vpn_node_down})),
    mark_reconciliation_stale(disconnected);
update_runtime_event_status_ui(BridgeStatus) ->
    nitro:update(vpn_runtime_event_status,
                 runtime_event_status_panel(BridgeStatus)).

maybe_refresh_reconciliation_after_snapshot(subscribed) ->
    %% A page may have observed VPN as disconnected before the bridge ever
    %% completed its first subscription. Refresh only the read-only comparison
    %% and controls; incident editors remain untouched.
    refresh_reconciliation_read_only(connected);
maybe_refresh_reconciliation_after_snapshot(reconnected) ->
    refresh_reconciliation_read_only(reconnected);
maybe_refresh_reconciliation_after_snapshot(_Reason) ->
    ok.

refresh_reconciliation_read_only(ConnectionReason) ->
    Reconciliation = ias_vpn_reconciliation:report(),
    nitro:update(vpn_reconciliation_controls,
                 reconciliation_controls(Reconciliation)),
    nitro:update(vpn_reconciliation_read_only,
                 reconciliation_read_only_panel(Reconciliation)),
    case Reconciliation of
        {ok, _Report} ->
            nitro:update(vpn_reconciliation_stale_notice,
                         #panel{id = vpn_reconciliation_stale_notice});
        {error, _Reason} ->
            mark_reconciliation_stale(
              {reconciliation_refresh_failed, ConnectionReason})
    end.

mark_reconciliation_stale(Event) ->
    nitro:update(vpn_reconciliation_stale_notice,
                 reconciliation_stale_notice(Event)).

reconciliation_stale_notice(connected) ->
    reconciliation_stale_message(
      "VPN event delivery is connected and a fresh runtime snapshot was loaded. Refresh reconciliation before acting on incidents.");
reconciliation_stale_notice(reconnected) ->
    reconciliation_stale_message(
      "VPN event delivery reconnected and a fresh runtime snapshot was loaded. Refresh reconciliation before acting on incidents because changes may have occurred while IAS was disconnected.");
reconciliation_stale_notice(disconnected) ->
    reconciliation_stale_message(
      "VPN disconnected. This reconciliation snapshot may be stale. Wait for VPN to reconnect, then refresh reconciliation before acting on incidents.");
reconciliation_stale_notice({snapshot_failed, reconnected}) ->
    reconciliation_stale_message(
      "VPN event delivery reconnected, but IAS could not load a fresh runtime snapshot. Use Refresh now, then refresh reconciliation before acting on incidents.");
reconciliation_stale_notice({reconciliation_refresh_failed, reconnected}) ->
    reconciliation_stale_message(
      "VPN event delivery reconnected and the runtime snapshot is fresh, but IAS could not refresh the reconciliation comparison. Use Refresh reconciliation before acting on incidents.");
reconciliation_stale_notice({reconciliation_refresh_failed, _Reason}) ->
    reconciliation_stale_message(
      "VPN event delivery is connected and the runtime snapshot is fresh, but IAS could not refresh the reconciliation comparison. Use Refresh reconciliation before acting on incidents.");
reconciliation_stale_notice({snapshot_failed, _Reason}) ->
    reconciliation_stale_message(
      "IAS received a VPN runtime notification but could not load the current runtime snapshot. Use Refresh now, then refresh reconciliation before acting on incidents.");
reconciliation_stale_notice(Event) when is_map(Event) ->
    Sequence = maps:get(sequence, Event, undefined),
    reconciliation_stale_message(
      ias_html:join(["VPN runtime changed",
                     sequence_notice(Sequence),
                     ". Refresh reconciliation before acting on incidents."]));
reconciliation_stale_notice(_Event) ->
    reconciliation_stale_message(
      "VPN runtime changed. Refresh reconciliation before acting on incidents.").

reconciliation_stale_message(Message) ->
    #panel{id = vpn_reconciliation_stale_notice,
           style = <<"margin:12px 0;padding:10px 12px;border:1px solid #f59e0b;border-radius:6px;background:#fffbeb;color:#92400e;font-size:12px;">>,
           body = ias_html:text(Message)}.

sequence_notice(Sequence) when is_integer(Sequence) ->
    ias_html:join([" (event sequence ", Sequence, ")"]);
sequence_notice(_Sequence) ->
    <<>>.

reconciliation_state() ->
    {ias_vpn_reconciliation:report(),
     ias_vpn_reconciliation:incidents()}.

update_reconciliation_ui(Result) ->
    {Reconciliation, Incidents} = reconciliation_state(),
    nitro:update(vpn_reconciliation_fragment,
                 reconciliation_fragment(Reconciliation, Incidents, Result)).

reconciliation_fragment(Reconciliation, Incidents, Result) ->
    #panel{id = vpn_reconciliation_fragment,
           body = [
               reconciliation_controls(Reconciliation),
               #panel{id = vpn_reconciliation_stale_notice},
               reconciliation_action_result_panel(Result),
               reconciliation_content_panel(Reconciliation, Incidents)
           ]}.

reconciliation_action_result_panel(none) ->
    #panel{id = vpn_reconciliation_action_result};
reconciliation_action_result_panel(Result) ->
    #panel{id = vpn_reconciliation_action_result,
           body = reconciliation_action_result(Result)}.

reconciliation_content_panel(Reconciliation, Incidents) ->
    #panel{id = vpn_reconciliation_content,
           body = reconciliation_panel(Reconciliation, Incidents)}.

reconciliation_read_only_panel(Reconciliation) ->
    #panel{id = vpn_reconciliation_read_only,
           body = reconciliation_read_only(Reconciliation)}.

reconciliation_incidents_panel(Incidents) ->
    #panel{id = vpn_reconciliation_incidents,
           body = reconciliation_incident_content(Incidents)}.

reconciliation_controls(Reconciliation) ->
    #panel{id = vpn_reconciliation_controls,
           class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("VPN Reconciliation")},
        #p{style = <<"font-size:12px;margin:0 0 10px;color:#64748b;">>,
           body = ias_html:text("Compares durable IAS authority with the VPN projection. Refresh only reads state; safe replay repairs only recoverable drift; scan records dangerous drift as incidents.")},
        #panel{style = <<"display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
               body = [
                   #link{id = vpn_reconciliation_refresh,
                         class = [button, sgreen],
                         body = ias_html:text("Refresh reconciliation"),
                         postback = refresh_vpn_reconciliation},
                   replay_all_control(Reconciliation),
                   scan_incidents_control(Reconciliation)
               ]},
        #p{style = <<"font-size:11px;margin:8px 0 0;color:#64748b;">>,
           body = ias_html:text("Incident actor and note are entered per incident and saved only by Acknowledge or Resolve after verification. Unsafe overwrite and automatic orphan adoption are not available.")}
    ]}.

replay_all_control({ok, Report}) when is_map(Report) ->
    Counts = maps:get(counts, Report, #{}),
    Eligible = maps:get(vpn_behind, Counts, 0) + maps:get(missing_in_vpn, Counts, 0),
    case Eligible > 0 of
        true ->
            #link{id = vpn_reconciliation_replay_all,
                  class = [button, sgreen],
                  body = ias_html:join(["Safe replay all (", Eligible, ")"]),
                  postback = safe_replay_all};
        false ->
            #span{id = vpn_reconciliation_replay_all,
                  title = ias_html:text("No VPN Behind or Missing in VPN records are available for safe replay."),
                  style = <<"display:inline-block;padding:8px 12px;border-radius:4px;background:#cbd5e1;color:#64748b;font-size:12px;font-weight:600;cursor:not-allowed;">>,
                  body = ias_html:text("Safe replay all (0)")}
    end;
replay_all_control(_Reconciliation) ->
    #span{id = vpn_reconciliation_replay_all,
          style = <<"display:inline-block;padding:8px 12px;border-radius:4px;background:#cbd5e1;color:#64748b;font-size:12px;font-weight:600;cursor:not-allowed;">>,
          body = ias_html:text("Safe replay unavailable")}.

scan_incidents_control({ok, Report}) when is_map(Report) ->
    #link{id = vpn_reconciliation_scan_incidents,
          class = [button, sgreen],
          body = ias_html:text("Scan incidents"),
          postback = scan_vpn_incidents};
scan_incidents_control(_Reconciliation) ->
    #span{id = vpn_reconciliation_scan_incidents,
          title = ias_html:text("Refresh reconciliation before scanning incidents."),
          style = <<"display:inline-block;padding:8px 12px;border-radius:4px;background:#cbd5e1;color:#64748b;font-size:12px;font-weight:600;cursor:not-allowed;">>,
          body = ias_html:text("Scan incidents unavailable")}.

reconciliation_panel(Reconciliation, Incidents) ->
    [reconciliation_read_only_panel(Reconciliation),
     reconciliation_incidents_panel(Incidents)].

reconciliation_read_only({ok, Report}) when is_map(Report) ->
    [reconciliation_summary(Report),
     reconciliation_entries(maps:get(entries, Report, []))];
reconciliation_read_only({error, Reason}) ->
    reconciliation_unavailable(Reason);
reconciliation_read_only(_Report) ->
    reconciliation_unavailable(invalid_reconciliation_state).

reconciliation_incident_content({ok, Incidents}) when is_list(Incidents) ->
    reconciliation_incidents(Incidents);
reconciliation_incident_content({error, Reason}) ->
    incident_unavailable(Reason);
reconciliation_incident_content(_Incidents) ->
    incident_unavailable(invalid_incident_state).

reconciliation_summary(Report) ->
    Counts = maps:get(counts, Report, #{}),
    #panel{class = <<"ias-summary">>, body = [
        summary("Synchronized", maps:get(synchronized, Counts, 0)),
        summary("VPN Behind", maps:get(vpn_behind, Counts, 0)),
        summary("Missing in VPN", maps:get(missing_in_vpn, Counts, 0)),
        summary("Divergence", maps:get(divergence, Counts, 0)),
        summary("Orphan", maps:get(orphan, Counts, 0)),
        summary("Authority Only", maps:get(authority_only, Counts, 0))
    ]}.

reconciliation_entries([]) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Reconciliation Records")},
        #p{body = ias_html:text("No IAS-managed VPN authority records or VPN orphans were reported.")}
    ]};
reconciliation_entries(Entries) ->
    #panel{class = <<"ias-table-container">>, body = [
        #h3{body = ias_html:text("Reconciliation Records")},
        #table{class = <<"ias-table">>,
               header = header(["Device", "Status", "Reason", "IAS Revision",
                                "VPN Revision", "Digest", "Runtime Entries",
                                "Recovery", "Action"]),
               body = #tbody{body = [reconciliation_entry_row(Entry)
                                      || Entry <- Entries]}}
    ]}.

reconciliation_entry_row(Entry) ->
    DeviceId = maps:get(device_id, Entry, undefined),
    Status = maps:get(status, Entry, undefined),
    #tr{cells = [
        #td{body = ias_html:text(DeviceId)},
        #td{body = status_badge(Status)},
        #td{body = ias_html:text(maps:get(reason, Entry, undefined))},
        #td{body = ias_html:text(ias_revision(Entry))},
        #td{body = ias_html:text(vpn_revision(Entry))},
        #td{body = ias_html:text(maps:get(digest_match, Entry, undefined))},
        #td{body = ias_html:text(registry_count(Entry))},
        #td{body = recovery_preview_cell(Entry)},
        #td{body = replay_button(DeviceId, Status)}
    ]}.

ias_revision(#{ias := Ias}) when is_map(Ias) -> maps:get(revision, Ias, undefined);
ias_revision(_Entry) -> undefined.

vpn_revision(#{vpn := Vpn}) when is_map(Vpn) ->
    case maps:get(head, Vpn, undefined) of
        Head when is_map(Head) -> maps:get(revision, Head, undefined);
        _ -> undefined
    end;
vpn_revision(_Entry) -> undefined.

registry_count(#{vpn := Vpn}) when is_map(Vpn) ->
    case maps:get(registry, Vpn, []) of
        Registry when is_list(Registry) -> length(Registry);
        _ -> 0
    end;
registry_count(_Entry) -> 0.

recovery_preview_cell(#{status := orphan,
                        recoverable := true,
                        recovery := Recovery}) when is_map(Recovery) ->
    #panel{style = <<"font-size:11px;color:#166534;">>, body = [
        #p{style = <<"margin:0;font-weight:700;">>,
           body = ias_html:text("Recoverable preview")},
        #p{style = <<"margin:2px 0;">>,
           body = ias_html:join([maps:get(mode, Recovery, metadata_only),
                                 "; objects ",
                                 maps:get(object_count, Recovery, 0),
                                 "; relationships ",
                                 maps:get(relationship_count, Recovery, 0)])},
        #p{style = <<"margin:2px 0;color:#64748b;">>,
           body = ias_html:text("Stage 7A is read-only; recovery action is not enabled yet.")}
    ]};
recovery_preview_cell(#{status := orphan,
                        recovery := Recovery}) when is_map(Recovery) ->
    #span{style = <<"font-size:11px;color:#b91c1c;">>,
          body = ias_html:join(["Unavailable: ",
                                maps:get(reason, Recovery,
                                         recovery_manifest_missing)])};
recovery_preview_cell(_Entry) ->
    #span{style = <<"font-size:11px;color:#64748b;">>,
          body = ias_html:text("-")}.

replay_button(DeviceId, Status)
  when Status =:= vpn_behind; Status =:= missing_in_vpn ->
    #link{id = reconciliation_dom_id(<<"vpn_reconciliation_replay_">>, DeviceId),
          class = [button, sgreen],
          body = ias_html:text("Safe replay"),
          postback = {safe_replay, DeviceId}};
replay_button(_DeviceId, synchronized) ->
    #span{style = <<"font-size:12px;color:#15803d;">>,
          body = ias_html:text("No action")};
replay_button(_DeviceId, _Status) ->
    #span{style = <<"font-size:12px;color:#b91c1c;">>,
          body = ias_html:text("Blocked") }.

reconciliation_incidents([]) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Reconciliation Incidents")},
        #p{body = ias_html:text("No durable divergence or orphan incidents. Use Scan incidents after refreshing reconciliation.")}
    ]};
reconciliation_incidents(Incidents) ->
    #panel{class = <<"ias-table-container">>, body = [
        #h3{body = ias_html:text("Reconciliation Incidents")},
        #table{class = <<"ias-table">>,
               header = header(["Device", "Kind", "Reason", "State", "Occurrences",
                                "Snapshot Token", "Last Seen", "Action"]),
               body = #tbody{body = [incident_row(Incident)
                                      || Incident <- Incidents]}}
    ]}.

incident_row(Incident) ->
    DeviceId = maps:get(device_id, Incident, undefined),
    Token = maps:get(token, Incident, undefined),
    Status = maps:get(status, Incident, undefined),
    #tr{cells = [
        #td{body = ias_html:text(DeviceId)},
        #td{body = status_badge(maps:get(kind, Incident, undefined))},
        #td{body = ias_html:text(maps:get(reason, Incident, undefined))},
        #td{body = status_badge(Status)},
        #td{body = ias_html:text(maps:get(occurrences, Incident, 0))},
        #td{body = #span{style = <<"font-family:monospace;font-size:11px;">>,
                         body = incident_token_text(Token)}},
        #td{body = ias_html:text(maps:get(last_seen, Incident, undefined))},
        #td{body = incident_editor(Incident, DeviceId, Token, Status)}
    ]}.

incident_editor(Incident, DeviceId, Token, Status) ->
    Suffix = reconciliation_id_suffix(DeviceId),
    ActorId = <<"vpn_incident_actor_", Suffix/binary>>,
    NoteId = <<"vpn_incident_note_", Suffix/binary>>,
    #panel{id = <<"vpn_incident_editor_", Suffix/binary>>,
           style = <<"min-width:310px;">>, body = [
        incident_history(Incident),
        #panel{style = <<"display:grid;grid-template-columns:90px minmax(150px,1fr);gap:6px;align-items:center;margin:8px 0;">>, body = [
            #label{for = ActorId, style = <<"font-size:11px;font-weight:600;">>, body = ias_html:text("Admin actor")},
            #input{id = ActorId, type = <<"text">>, value = <<"ias-ui-admin">>},
            #label{for = NoteId, style = <<"font-size:11px;font-weight:600;">>, body = ias_html:text("Incident note")},
            #input{id = NoteId, type = <<"text">>, value = <<>>, placeholder = ias_html:text("Saved by Acknowledge or Resolve")}
        ]},
        incident_actions(Incident,
                         DeviceId,
                         Token,
                         Status,
                         ActorId,
                         NoteId,
                         Suffix)
    ]}.

incident_actions(Incident, DeviceId, Token, open, ActorId, NoteId, Suffix) ->
    #panel{style = <<"display:flex;gap:6px;flex-wrap:wrap;">>, body = [
        #link{id = <<"vpn_incident_acknowledge_", Suffix/binary>>,
              class = [button, sgreen],
              body = ias_html:text("Acknowledge"),
              source = [ActorId, NoteId],
              postback = {acknowledge_vpn_incident, DeviceId, Token, ActorId, NoteId}},
        #link{id = <<"vpn_incident_resolve_", Suffix/binary>>,
              class = [button, sgreen],
              body = ias_html:text("Resolve after verification"),
              source = [ActorId, NoteId],
              postback = {resolve_vpn_incident, DeviceId, Token, ActorId, NoteId}},
        orphan_decommission_control(Incident,
                                    DeviceId,
                                    Token,
                                    ActorId,
                                    NoteId,
                                    Suffix)
    ]};
incident_actions(Incident,
                 DeviceId,
                 Token,
                 acknowledged,
                 ActorId,
                 NoteId,
                 Suffix) ->
    #panel{style = <<"display:flex;gap:6px;flex-wrap:wrap;">>, body = [
        #link{id = <<"vpn_incident_resolve_", Suffix/binary>>,
              class = [button, sgreen],
              body = ias_html:text("Resolve after verification"),
              source = [ActorId, NoteId],
              postback = {resolve_vpn_incident, DeviceId, Token, ActorId, NoteId}},
        orphan_decommission_control(Incident,
                                    DeviceId,
                                    Token,
                                    ActorId,
                                    NoteId,
                                    Suffix)
    ]};
incident_actions(_Incident,
                 _DeviceId,
                 _Token,
                 resolved,
                 _ActorId,
                 _NoteId,
                 _Suffix) ->
    #span{style = <<"font-size:12px;color:#15803d;">>,
          body = ias_html:text("Verified resolved")};
incident_actions(_Incident,
                 _DeviceId,
                 _Token,
                 _Status,
                 _ActorId,
                 _NoteId,
                 _Suffix) ->
    #span{body = ias_html:text("Unavailable")}.

orphan_decommission_control(
  #{kind := orphan,
    snapshot := #{decommission := #{eligible := true}}},
  DeviceId,
  Token,
  ActorId,
  NoteId,
  Suffix) ->
    #link{id = <<"vpn_incident_decommission_", Suffix/binary>>,
          class = [button, more],
          style = <<"background:#b91c1c;color:#fff;border-color:#991b1b;">>,
          body = ias_html:text("Decommission from VPN"),
          source = [ActorId, NoteId],
          postback = {confirm_decommission_vpn_orphan,
                      DeviceId, Token, ActorId, NoteId}};
orphan_decommission_control(_Incident,
                            _DeviceId,
                            _Token,
                            _ActorId,
                            _NoteId,
                            _Suffix) ->
    [].

orphan_decommission_confirm_text(DeviceId) ->
    ias_html:join(["Permanently decommission orphan VPN state for Device ",
                   DeviceId,
                   "? VPN will compare the current revision, digest, peer set and allocation before removing runtime peers, registry entries, allocator state and the provisioning head. Local identity files are retained for explicit follow-up cleanup. This cannot be undone by IAS."]).

incident_history(Incident) ->
    Acknowledged = audit_line("Acknowledged", maps:get(acknowledged_by, Incident, undefined),
                              maps:get(acknowledged_note, Incident, undefined),
                              maps:get(acknowledged_at, Incident, undefined)),
    Resolved = audit_line("Resolved", maps:get(resolved_by, Incident, undefined),
                          maps:get(resolved_note, Incident, undefined),
                          maps:get(resolved_at, Incident, undefined)),
    #panel{style = <<"font-size:11px;color:#64748b;">>, body = [Acknowledged, Resolved]}.

audit_line(_Label, undefined, _Note, _At) -> [];
audit_line(Label, Actor, Note, At) ->
    #p{style = <<"margin:2px 0;">>,
       body = ias_html:join([Label, " by ", Actor, " at ", At,
                             case Note of undefined -> <<>>; <<>> -> <<>>; _ -> ias_html:join([" — ", Note]) end])}.

reconciliation_dom_id(Prefix, DeviceId) ->
    Suffix = reconciliation_id_suffix(DeviceId),
    <<Prefix/binary, Suffix/binary>>.

reconciliation_id_suffix(DeviceId) ->
    Digest = crypto:hash(sha256, ias_html:text(DeviceId)),
    Hex = iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Digest]),
    binary:part(Hex, 0, 16).

status_badge(Status) ->
    #span{style = status_style(Status), body = ias_html:text(Status)}.

status_style(synchronized) -> <<"display:inline-block;padding:3px 7px;border-radius:999px;background:#dcfce7;color:#166534;font-size:11px;font-weight:700;">>;
status_style(resolved) -> <<"display:inline-block;padding:3px 7px;border-radius:999px;background:#dcfce7;color:#166534;font-size:11px;font-weight:700;">>;
status_style(vpn_behind) -> <<"display:inline-block;padding:3px 7px;border-radius:999px;background:#fef3c7;color:#92400e;font-size:11px;font-weight:700;">>;
status_style(missing_in_vpn) -> <<"display:inline-block;padding:3px 7px;border-radius:999px;background:#fef3c7;color:#92400e;font-size:11px;font-weight:700;">>;
status_style(acknowledged) -> <<"display:inline-block;padding:3px 7px;border-radius:999px;background:#dbeafe;color:#1d4ed8;font-size:11px;font-weight:700;">>;
status_style(_Status) -> <<"display:inline-block;padding:3px 7px;border-radius:999px;background:#fee2e2;color:#991b1b;font-size:11px;font-weight:700;">>.

incident_token_text(Token) when is_binary(Token) ->
    Hex = iolist_to_binary([io_lib:format("~2.16.0B", [Byte]) || <<Byte>> <= Token]),
    case byte_size(Hex) > 20 of
        true -> <<(binary:part(Hex, 0, 20))/binary, "...">>;
        false -> Hex
    end;
incident_token_text(_Token) -> <<"-">>.

reconciliation_unavailable(Reason) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Reconciliation unavailable")},
        #p{body = ias_html:join(["IAS could not read the VPN reconciliation snapshot: ",
                                 term_text(Reason)])}
    ]}.

incident_unavailable(Reason) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Incident ledger unavailable")},
        #p{body = ias_html:join(["IAS could not read the durable incident ledger: ",
                                 term_text(Reason)])}
    ]}.

reconciliation_action_result({ok, refreshed}) ->
    action_message(ok, "Reconciliation refreshed. IAS and VPN were compared; no state was changed.");
reconciliation_action_result({ok, #{requested_action := replay} = Result}) ->
    action_message(ok, ias_html:join([
        "Safe replay completed: ", maps:get(replayed_records, Result, 0), " replayed, ",
        maps:get(no_action_records, Result, 0), " already synchronized, ",
        maps:get(blocked_records, Result, 0), " blocked, ",
        maps:get(failed_records, Result, 0), " failed."]));
reconciliation_action_result({ok, #{requested_action := scan_incidents} = Result}) ->
    action_message(ok, ias_html:join([
        "Incident scan completed: ", maps:get(active_records, Result, 0),
        " active divergence/orphan record(s); ",
        length(maps:get(incidents, Result, [])), " durable incident(s) stored."]));
reconciliation_action_result({ok, #{status := acknowledged} = Result}) ->
    action_message(ok, ias_html:join(["Incident acknowledged by ", maps:get(acknowledged_by, Result, <<"administrator">>), ". The problem remains active until it is repaired."]));
reconciliation_action_result({ok, #{status := resolved} = Result}) ->
    action_message(ok, ias_html:join(["Incident resolved after verification by ", maps:get(resolved_by, Result, <<"administrator">>), "."]));
reconciliation_action_result(
  {ok, #{requested_action := decommission_orphan} = Result}) ->
    action_message(ok,
                   ias_html:join(["VPN orphan decommission completed for ",
                                  maps:get(device_id, Result, <<"device">>),
                                  ". The durable incident was resolved after a fresh reconciliation check."]));
reconciliation_action_result({ok, Result}) when is_map(Result) ->
    Outcome = first_action_value(Result),
    action_message(ok, ias_html:join(["Action completed: ", Outcome]));
reconciliation_action_result(not_found) ->
    action_message(error, "The selected IAS VPN authority record was not found.");
reconciliation_action_result({error, Reason}) ->
    action_message(error, reconciliation_error_message(Reason));
reconciliation_action_result(Result) ->
    action_message(error, ias_html:join(["Unexpected action result: ", term_text(Result)])).

first_action_value(Result) ->
    maps:get(outcome, Result,
             maps:get(result, Result,
                      maps:get(status, Result,
                               maps:get(requested_action, Result, <<"completed">>)))).

reconciliation_error_message({vpn_incident_still_active, orphan, _Reason}) ->
    "This incident cannot be resolved because the orphan device is still present in VPN. Remove it from VPN or provision it through IAS, refresh reconciliation, and try again.";
reconciliation_error_message({vpn_incident_still_active, divergence, _Reason}) ->
    "This incident cannot be resolved because IAS and VPN still disagree. Repair the conflicting state, refresh reconciliation, and try again.";
reconciliation_error_message(stale_or_invalid_incident_token) ->
    "This incident changed after the page was rendered. Refresh reconciliation and try again.";
reconciliation_error_message(vpn_incident_snapshot_missing) ->
    "The incident is no longer present in the current reconciliation snapshot. Refresh reconciliation before retrying.";
reconciliation_error_message(vpn_incident_not_found) ->
    "The durable incident record was not found.";
reconciliation_error_message(orphan_snapshot_conflict) ->
    "VPN state changed after this incident snapshot was created. Refresh reconciliation and scan incidents again before retrying.";
reconciliation_error_message({vpn_orphan_decommission_failed,
                              orphan_snapshot_conflict}) ->
    "VPN state changed after this incident snapshot was created. Nothing was removed. Refresh reconciliation and scan incidents again.";
reconciliation_error_message({vpn_orphan_decommission_unavailable, Reason}) ->
    ias_html:join(["This orphan cannot be safely decommissioned: ",
                   term_text(Reason), "."]);
reconciliation_error_message({vpn_orphan_decommission_not_absent,
                              _Status,
                              _Reason}) ->
    "VPN accepted the decommission request, but a fresh reconciliation snapshot still contains the orphan. The durable operation can be retried safely.";
reconciliation_error_message({vpn_safe_replay_failed, Result}) when is_map(Result) ->
    ias_html:join(["Safe replay completed with failures: ", maps:get(replayed_records, Result, 0),
                   " replayed and ", maps:get(failed_records, Result, 0), " failed."]);
reconciliation_error_message(Reason) ->
    ias_html:join(["Action failed: ", term_text(Reason)]).

action_message(ok, Text) ->
    #panel{style = <<"margin:10px 0;padding:10px;border:1px solid #86efac;border-radius:6px;background:#f0fdf4;color:#166534;">>,
           body = ias_html:text(Text)};
action_message(error, Text) ->
    #panel{style = <<"margin:10px 0;padding:10px;border:1px solid #fca5a5;border-radius:6px;background:#fef2f2;color:#991b1b;">>,
           body = ias_html:text(Text)}.

term_text(Value) when is_atom(Value); is_binary(Value); is_integer(Value); is_boolean(Value) ->
    ias_html:text(Value);
term_text(Value) ->
    iolist_to_binary(io_lib:format("~p", [Value])).

create_service_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Create VPN Service")},
        #p{style = <<"font-size:12px;margin:0 0 10px;color:#64748b;">>,
           body = ias_html:text("Creates a demo VPN service endpoint used later by OVPN export provisioning.")},
        input_row("Name", vpn_service_name, <<"OpenVPN">>),
        input_row("Remote Host", vpn_remote_host, <<"vpn.example.com">>),
        input_row("Remote Port", vpn_remote_port, <<"1194">>),
        protocol_row(),
        security_policy_row(),
        ca_certificate_row(),
        #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
               body = [
                   #link{id = vpn_create_service_button,
                         class = [button, sgreen],
                         body = ias_html:text("Create VPN Service"),
                         source = [vpn_service_name, vpn_remote_host, vpn_remote_port, vpn_protocol,
                                   vpn_security_policy, vpn_ca_certificate],
                         postback = create_vpn_service},
                   #span{style = <<"font-size:12px;color:#64748b;">>,
                         body = ias_html:text("Demo runtime object only. No VPN server is started.")}
               ]},
        #panel{id = vpn_service_create_result}
    ]}.

input_row(Label, Id, Value) ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = Id,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text(Label)},
               #input{id = Id,
                      type = <<"text">>,
                      value = ias_html:text(Value),
                      style = <<"min-width:260px;max-width:420px;width:100%;">>}
           ]}.

protocol_row() ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = vpn_protocol,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text("Protocol")},
               #select{id = vpn_protocol,
                       body = [
                           #option{value = <<"udp">>, selected = true, body = ias_html:text("udp")},
                           #option{value = <<"tcp">>, body = ias_html:text("tcp")}
                       ]}
           ]}.

security_policy_row() ->
    select_row("Security Policy", vpn_security_policy,
               [#option{value = <<"">>, body = ias_html:text("not linked yet")}
                | [#option{value = maps:get(id, Policy),
                           body = ias_html:join([maps:get(name, Policy, maps:get(id, Policy)),
                                                 <<" (#">>, maps:get(id, Policy), <<")">>])}
                   || Policy <- ias_demo_store:security_policies()]]).

ca_certificate_row() ->
    select_row("CA Certificate", vpn_ca_certificate,
               [#option{value = <<"">>, body = ias_html:text("not linked yet")}
                | [#option{value = maps:get(id, Certificate),
                           body = ias_html:join([certificate_class_label(Certificate), <<" #">>,
                                                 maps:get(id, Certificate)])}
                   || Certificate <- ias_demo_store:certificates()]]).

select_row(Label, Id, Options) ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = Id,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text(Label)},
               #select{id = Id,
                       style = <<"min-width:260px;max-width:420px;width:100%;">>,
                       body = Options}
           ]}.

certificate_class_label(Certificate) ->
    ias_certificate_detail:certificate_class(Certificate).

create_vpn_service(Name, Host, Port, Protocol) ->
    create_vpn_service(Name, Host, Port, Protocol, not_linked, not_linked).

create_vpn_service(_Name, <<>>, _Port, _Protocol, _PolicyId, _CaCertificateId) ->
    {error, <<"remote host is required">>};
create_vpn_service(Name, Host, Port, Protocol, PolicyId, CaCertificateId) ->
    Id = vpn_service_id(),
    Remote = ias_html:join([Host, <<":">>, normalize_port(Port)]),
    Service0 = ias_demo_store:add_service(#{
        id => Id,
        source => manual_vpn_service,
        import_id => Id,
        service => openvpn,
        name => Name,
        remote => Remote,
        remote_host => Host,
        remote_port => normalize_port(Port),
        protocol => Protocol,
        ca_certificate_id => metadata_id(CaCertificateId),
        security_policy_id => metadata_id(PolicyId),
        cipher => not_configured,
        compression => false,
        routes => 0
    }),
    ok = maybe_link(uses_security_policy, Id, PolicyId),
    ok = maybe_link(uses_ca_certificate, Id, CaCertificateId),
    {ok, Service0}.

vpn_service_id() ->
    ias_html:join([<<"manual_vpn_service_">>, integer_to_binary(erlang:unique_integer([positive, monotonic]))]).

normalize_port(<<>>) ->
    <<"1194">>;
normalize_port(Port) ->
    ias_html:text(Port).

optional_value(undefined) ->
    not_linked;
optional_value(<<>>) ->
    not_linked;
optional_value(Value) ->
    ias_html:text(Value).

metadata_id(not_linked) ->
    not_linked;
metadata_id(Value) ->
    ias_html:text(Value).

maybe_link(_RelationType, _SourceId, not_linked) ->
    ok;
maybe_link(RelationType, SourceId, TargetId) ->
    case ias_relationship_link:create(RelationType, SourceId, TargetId) of
        {ok, _Relationship} -> ok;
        {error, _Reason} -> ok
    end.

protocol_value(undefined) ->
    udp;
protocol_value(Value) ->
    case ias_html:text(Value) of
        <<"tcp">> -> tcp;
        <<"udp">> -> udp;
        _ -> udp
    end.

field_value(undefined, Default) ->
    Default;
field_value(<<>>, Default) ->
    Default;
field_value(Value, _Default) ->
    ias_html:text(Value).

create_result({ok, Service}) ->
    Id = maps:get(id, Service, undefined),
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("VPN service created")},
               key_value_table([
                   {"Service", maps:get(name, Service, <<"OpenVPN">>)},
                   {"Remote", maps:get(remote, Service, undefined)},
                   {"Protocol", maps:get(protocol, Service, undefined)},
                   {"Security Policy", maps:get(security_policy_id, Service, not_linked)},
                   {"CA Certificate", maps:get(ca_certificate_id, Service, not_linked)},
                   {"Runtime", <<"demo state only">>}
               ]),
               #link{url = ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]),
                     style = <<"display:inline-block;margin-top:8px;padding:7px 10px;border:1px solid #93c5fd;border-radius:5px;background:#ffffff;color:#1d4ed8;text-decoration:none;font-size:12px;font-weight:600;">>,
                     body = ias_html:text("View Demo Object")}
           ]};
create_result({error, Reason}) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("VPN service was not created")},
               #p{body = ias_html:text(Reason)}
           ]}.

managed_services_panel() ->
    Records = ias_demo_store:services(),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Managed VPN Services")},
        managed_services(Records)
    ]}.

managed_services([]) ->
    #p{body = ias_html:text("No managed VPN services yet. Create one above or import an OVPN profile.")};
managed_services(Records) ->
    table([
        #table{class = <<"ias-table">>,
               header = header(["ID", "Service", "Remote", "Protocol", "Security Policy", "CA Certificate", "Source"]),
               body = #tbody{body = [managed_service_row(Record) || Record <- Records]}}
    ]).

managed_service_row(Record) ->
    row([demo_link(maps:get(id, Record, undefined)),
         maps:get(name, Record, maps:get(service, Record, undefined)),
         maps:get(remote, Record, undefined),
         maps:get(protocol, Record, undefined),
         linked_policy_label(Record),
         linked_ca_label(Record),
         maps:get(source, Record, undefined)]).

demo_link(undefined) ->
    undefined;
demo_link(Id) ->
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
          body = TextId}.

summary_shape({ok, Data}) when is_map(Data) ->
    Counts = ias_vpn_runtime:counts(Data),
    Peers = ias_vpn_runtime:peers(Data),
    {ok, #{counts => Counts, peers => length(Peers)}};
summary_shape({ok, Data}) ->
    {ok, Data};
summary_shape({error, Reason}) ->
    {error, Reason}.

render_summary({ok, Data}) when is_map(Data) ->
    Counts = ias_vpn_runtime:counts(Data),
    Peers = ias_vpn_runtime:peers(Data),
    [
        counters(Counts, Peers),
        peers_table(Peers)
    ];
render_summary({ok, _Data}) ->
    unavailable();
render_summary({error, _Reason}) ->
    unavailable().

unavailable() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("VPN service unavailable")},
        #p{body = ias_html:text("IAS is running normally. VPN runtime status will appear when the VPN admin API is reachable.")}
    ]}.

counters(Counts, Peers) ->
    #panel{class = <<"ias-summary">>, body = [
        summary("Configured Peers", maps:get(<<"configured">>, Counts, length(Peers))),
        summary("Running Peers", maps:get(<<"running">>, Counts, ias_vpn_runtime:running_count(Peers))),
        summary("Stopped Peers", maps:get(<<"stopped">>, Counts, ias_vpn_runtime:stopped_count(Peers))),
        summary("Certificates", maps:get(<<"certificates">>, Counts, 0))
    ]}.

summary(Label, undefined) ->
    #panel{class = <<"ias-summary-item">>, body = [Label, ": -"]};
summary(Label, Value) ->
    #panel{class = <<"ias-summary-item">>, body = ias_html:join([Label, ": ", Value])}.

peers_table([]) ->
    #panel{class = <<"ias-status-card">>, body = ias_html:text("No VPN peers reported.")};
peers_table(Peers) ->
    Devices = ias_demo_data:devices(),
    Profiles = ias_demo_data:profiles(),
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               header = header(["Peer", "State", "Profile", "Authorized", "Reason",
                                "Running", "Mode", "IP", "Remote Peer", "Trusted",
                                "Key Match", "Expires", "Crypto Failures", "Frames Rejected"]),
               body = #tbody{body = [peer_row(Peer, Devices, Profiles) || Peer <- Peers]}}
    ]}.

peer_row(Peer, Devices, Profiles) ->
    Policy = policy_decision(Peer, Devices, Profiles),
    row([ias_vpn_runtime:field(Peer, [peer, id, name]),
         ias_vpn_runtime:state(Peer),
         maps:get(profile_id, Policy, undefined),
         maps:get(authorized, Policy, false),
         maps:get(reason, Policy, undefined),
         ias_vpn_runtime:field(Peer, [<<"running">>, running, is_running, status]),
         ias_vpn_runtime:field(Peer, [mode]),
         ias_vpn_runtime:field(Peer, [ip, address]),
         ias_vpn_runtime:field(Peer, [remote_peer_id, remote_peer, remote]),
         ias_vpn_runtime:certificate_field(Peer, [trusted]),
         ias_vpn_runtime:certificate_field(Peer, [key_match]),
         ias_vpn_runtime:certificate_field(Peer, [not_after, expires, expires_at]),
         ias_vpn_runtime:field(Peer, [crypto_failures]),
         ias_vpn_runtime:field(Peer, [frames_rejected])]).

policy_decision(Peer, Devices, Profiles) ->
    case authorization_mode(Peer) of
        development_bypass ->
            #{profile_id => runtime_profile_id(Peer),
              authorized => runtime_authorized(Peer),
              reason => runtime_authorization_reason(Peer),
              authorization_mode => development_bypass};
        policy ->
            case runtime_profile_id(Peer) of
                undefined ->
                    legacy_policy_decision(Peer, Devices, Profiles);
                ProfileId ->
                    #{profile_id => ProfileId,
                      authorized => runtime_authorized(Peer),
                      reason => runtime_authorization_reason(Peer),
                      authorization_mode => policy}
            end
    end.

legacy_policy_decision(Peer, Devices, Profiles) ->
    PeerId = ias_vpn_runtime:field(Peer, [<<"id">>, id, peer, name]),
    ProfileId = profile_id(PeerId, Devices),
    Profile = profile(ProfileId, Profiles),
    (ias_policy:evaluate_vpn(Profile))#{profile_id => ProfileId,
                                        authorization_mode => policy}.

runtime_profile_id(Peer) ->
    case ias_vpn_runtime:field(Peer, [profile_id, profile]) of
        undefined -> undefined;
        null -> undefined;
        <<>> -> undefined;
        "" -> undefined;
        ProfileId -> ProfileId
    end.

authorization_mode(Peer) ->
    case ias_vpn_runtime:field(Peer, [authorization_mode]) of
        development_bypass -> development_bypass;
        <<"development_bypass">> -> development_bypass;
        "development_bypass" -> development_bypass;
        _ -> policy
    end.

runtime_authorized(Peer) ->
    case ias_vpn_runtime:field(Peer, [authorized]) of
        true -> true;
        <<"true">> -> true;
        "true" -> true;
        _ -> false
    end.

runtime_authorization_reason(Peer) ->
    case ias_vpn_runtime:field(Peer, [authorization_reason]) of
        undefined -> <<"development bypass">>;
        null -> <<"development bypass">>;
        development_bypass -> <<"development bypass">>;
        <<"development_bypass">> -> <<"development bypass">>;
        "development_bypass" -> <<"development bypass">>;
        profile_allows_vpn -> <<"profile allows vpn">>;
        <<"profile_allows_vpn">> -> <<"profile allows vpn">>;
        "profile_allows_vpn" -> <<"profile allows vpn">>;
        vpn_not_permitted_by_profile -> <<"vpn not permitted by profile">>;
        <<"vpn_not_permitted_by_profile">> -> <<"vpn not permitted by profile">>;
        "vpn_not_permitted_by_profile" -> <<"vpn not permitted by profile">>;
        Reason -> Reason
    end.

profile_id(undefined, _Devices) ->
    undefined;
profile_id(PeerId, Devices) ->
    case [Device || Device <- Devices,
                    maps:get(vpn_peer, Device, undefined) =:= PeerId] of
        [#{profile_id := ProfileId} | _] -> ProfileId;
        _ -> undefined
    end.

profile(undefined, _Profiles) ->
    #{};
profile(ProfileId, Profiles) ->
    case [Profile || Profile <- Profiles, maps:get(id, Profile) =:= ProfileId] of
        [Profile | _] -> Profile;
        [] -> #{}
    end.

header(Columns) ->
    [#tr{cells = [#th{body = ias_html:text(Column)} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = cell_body(Value)} || Value <- Values]}.

cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

key_value_table(Rows) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [key_value_row(Label, Value) || {Label, Value} <- Rows]}}
    ]}.

key_value_row(Label, Value) ->
    #tr{cells = [
        #th{body = ias_html:text(Label)},
        #td{body = cell_body(Value)}
    ]}.

table(Body) ->
    #panel{class = <<"ias-table-container">>, body = Body}.


linked_policy_label(Service) ->
    linked_target_label(Service, uses_security_policy, security_policy).

linked_ca_label(Service) ->
    linked_target_label(Service, uses_ca_certificate, certificate).

linked_target_label(Service, RelationType, TargetKind) ->
    ServiceId = maps:get(id, Service, undefined),
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_demo_store:relationships(),
             maps:get(relation_type, Relationship, undefined) =:= RelationType,
             maps:get(source_kind, Relationship, undefined) =:= vpn_service,
             maps:get(source_id, Relationship, undefined) =:= ServiceId,
             maps:get(target_kind, Relationship, undefined) =:= TargetKind] of
        [TargetId | _] -> TargetId;
        [] -> maps:get(linked_metadata_key(RelationType), Service, not_linked)
    end.

linked_metadata_key(uses_security_policy) -> security_policy_id;
linked_metadata_key(uses_ca_certificate) -> ca_certificate_id;
linked_metadata_key(_RelationType) -> undefined.
