-ifndef(IAS_VPN_RECONCILIATION_INCIDENT_HRL).
-define(IAS_VPN_RECONCILIATION_INCIDENT_HRL, true).

-record(ias_vpn_reconciliation_incident, {
    device_id,
    schema_version = 1,
    kind,
    reason,
    token,
    status = open,
    snapshot = #{},
    first_seen = 0,
    last_seen = 0,
    occurrences = 1,
    acknowledged_by = undefined,
    acknowledged_note = undefined,
    acknowledged_at = undefined,
    resolved_by = undefined,
    resolved_note = undefined,
    resolved_at = undefined,
    updated_at = 0
}).

-endif.
