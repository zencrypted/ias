-ifndef(IAS_VPN_PROVISIONING_DELIVERY_AUDIT_HRL).
-define(IAS_VPN_PROVISIONING_DELIVERY_AUDIT_HRL, true).

-record(ias_vpn_provisioning_delivery_audit, {
    delivery_id,
    schema_version = 1,
    device_id,
    provisioning_transaction_id = undefined,
    attempt = 1,
    delivery_status,
    operation,
    revision = undefined,
    delivered_at,
    payload = #{}
}).

-endif.
