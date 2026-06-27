-ifndef(IAS_VPN_ORPHAN_RESOLUTION_OPERATION_HRL).
-define(IAS_VPN_ORPHAN_RESOLUTION_OPERATION_HRL, true).

-record(ias_vpn_orphan_resolution_operation, {
    device_id,
    schema_version = 1,
    operation_id,
    incident_token,
    status = pending,
    request = #{},
    actor = <<"ias-ui-admin">>,
    note = <<>>,
    vpn_result = undefined,
    clearance = undefined,
    resolved_incident = undefined,
    attempts = 0,
    last_error = undefined,
    created_at = 0,
    updated_at = 0,
    completed_at = undefined
}).

-endif.
