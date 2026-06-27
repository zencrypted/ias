-ifndef(IAS_VPN_ORPHAN_RECOVERY_OPERATION_HRL).
-define(IAS_VPN_ORPHAN_RECOVERY_OPERATION_HRL, true).

-record(ias_vpn_orphan_recovery_operation, {
    device_id,
    schema_version = 1,
    operation_id,
    incident_token,
    status = planned,
    plan = #{},
    actor = <<"ias-ui-admin">>,
    note = <<>>,
    commit_summary = undefined,
    clearance = undefined,
    resolved_incident = undefined,
    attempts = 0,
    last_error = undefined,
    created_at = 0,
    updated_at = 0,
    completed_at = undefined
}).

-endif.
