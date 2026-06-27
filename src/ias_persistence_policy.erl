-module(ias_persistence_policy).

-export([stores/0,
         diagnostics/0]).

stores() ->
    [#{store => ias_domain_store,
       label => <<"Domain Object Graph">>,
       mode => durable,
       backend => kvs,
       runtime_projection => ets,
       policy => <<"source of truth">>},
     #{store => ias_provisioning_wizard_draft_store,
       label => <<"Provisioning Wizard Drafts">>,
       mode => durable,
       backend => kvs,
       runtime_projection => ets,
       policy => <<"resumable lifecycle">>},
     #{store => ias_vpn_provisioning_delivery_store,
       label => <<"VPN Provisioning Delivery Audit">>,
       mode => durable_append_only,
       backend => kvs,
       runtime_projection => ets,
       policy => <<"sanitized audit metadata">>},
     #{store => ias_certificate_material,
       label => <<"Certificate Materials">>,
       mode => volatile,
       backend => ets,
       runtime_projection => none,
       policy => <<"secure material boundary">>},
     #{store => ias_csr_enrollment_state,
       label => <<"CSR Enrollment States">>,
       mode => volatile,
       backend => ets,
       runtime_projection => none,
       policy => <<"workflow policy pending">>},
     #{store => ias_vpn_event_bridge,
       label => <<"VPN Event Bridge State">>,
       mode => volatile,
       backend => process_memory,
       runtime_projection => none,
       policy => <<"runtime wake-up state">>},
     #{store => nitro_websocket_state,
       label => <<"Nitro/WebSocket State">>,
       mode => volatile,
       backend => process_memory,
       runtime_projection => none,
       policy => <<"browser session state">>}].

diagnostics() ->
    #{durable_wizard_drafts => durable_wizard_draft_count(),
      durable_delivery_audit_entries => durable_delivery_audit_count(),
      ets_delivery_audit_entries =>
          safe_count(fun ias_vpn_provisioning_delivery:projection_count/0),
      volatile_certificate_materials =>
          safe_count(fun ias_certificate_material:count/0),
      volatile_csr_enrollment_states =>
          safe_count(fun() -> length(ias_csr_enrollment_state:all()) end),
      persistence_stores => stores()}.

durable_wizard_draft_count() ->
    case safe_call(fun ias_provisioning_wizard_draft_store:all/0) of
        {ok, Drafts} when is_list(Drafts) -> length(Drafts);
        _ -> unavailable
    end.

durable_delivery_audit_count() ->
    case safe_call(fun ias_vpn_provisioning_delivery_store:count/0) of
        {ok, Count} when is_integer(Count) -> Count;
        _ -> unavailable
    end.

safe_count(Fun) ->
    case safe_call(Fun) of
        Value when is_integer(Value) -> Value;
        _ -> unavailable
    end.

safe_call(Fun) ->
    try Fun() of
        Value -> Value
    catch
        _:_ -> unavailable
    end.
