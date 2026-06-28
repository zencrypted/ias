-ifndef(IAS_VPN_AUTHORITY_HRL).
-define(IAS_VPN_AUTHORITY_HRL, true).

-record(ias_vpn_device_state, {
    device_id,
    schema_version = 2,
    revision = 0,
    command_digest = undefined,
    canonical_command = #{},
    binding = #{},
    lifecycle_state = unbound,
    last_decommission = undefined,
    decommission_history = [],
    decommissioned_at = undefined,
    updated_at = 0
}).

-endif.
