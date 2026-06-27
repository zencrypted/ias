-module(ias_bootstrap).

-export([prepare/0]).

prepare() ->
    Steps = [
        {kvs_join, fun ensure_kvs_joined/0},
        {domain_store, fun ias_domain_store:ensure/0},
        {wizard_draft_store, fun ias_provisioning_wizard_draft_store:ensure/0},
        {vpn_delivery_audit_store,
         fun ias_vpn_provisioning_delivery_store:ensure/0},
        {vpn_authority, fun ias_vpn_authority:ensure/0},
        {vpn_incidents, fun ias_vpn_reconciliation_incidents:ensure/0},
        {wizard_draft_rehydration, fun ias_provisioning_wizard_store:rehydrate/0},
        {vpn_delivery_audit_rehydration,
         fun ias_vpn_provisioning_delivery:rehydrate/0},
        {rehydration, fun ias_demo_store:rehydrate/0}
    ],
    run_steps(Steps, undefined).

run_steps([], Health) when is_map(Health) ->
    {ok, Health};
run_steps([], _Health) ->
    {error, {ias_bootstrap_failed, rehydration, missing_projection_health}};
run_steps([{Step, Fun} | Rest], Health0) ->
    case execute_step(Fun) of
        {ok, Value} ->
            Health = case is_map(Value) of
                         true -> Value;
                         false -> Health0
                     end,
            run_steps(Rest, Health);
        {error, Reason} ->
            {error, {ias_bootstrap_failed, Step, Reason}}
    end.

execute_step(Fun) ->
    try Fun() of
        ok ->
            {ok, undefined};
        {ok, Value} ->
            {ok, Value};
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_bootstrap_result, Other}}
    catch
        Class:Reason:Stacktrace ->
            {error, {bootstrap_step_exception,
                     {Class, Reason, Stacktrace}}}
    end.

ensure_kvs_joined() ->
    case kvs:join() of
        {error, Reason} -> {error, Reason};
        _ -> ok
    end.
