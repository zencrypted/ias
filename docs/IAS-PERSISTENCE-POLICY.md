# IAS Persistence Policy

IAS classifies every runtime store explicitly. A store is not made durable merely
because it uses ETS today; persistence is added only when its lifecycle,
confidentiality boundary, and recovery semantics are defined.

## Durable KVS stores

| Store | Mode | Runtime view | Policy |
|---|---|---|---|
| `ias_domain_store` | durable | ETS projection through `ias_demo_store` | source of truth for supported domain objects and relationships |
| `ias_provisioning_wizard_draft_store` | durable | ETS wizard projection | resumable active/completed/abandoned lifecycle |
| `ias_vpn_provisioning_delivery_store` | durable append-only | ETS delivery-history projection | sanitized delivery audit metadata |

Durable application code accesses records through KVS. Cross-record atomicity is
provided through `ias_kvs_transaction` and its configured backend provider.

## Volatile stores

| Store | Mode | Reason |
|---|---|---|
| `ias_certificate_material` | volatile ETS | secure public-material storage policy is a separate stage; private keys are forbidden |
| `ias_csr_enrollment_state` | volatile ETS | resumability, expiry, and retry lifecycle are not yet finalized |
| `ias_vpn_event_bridge` | process memory | wake-up/subscription state is reconstructed at runtime |
| Nitro/WebSocket state | process memory | browser-session state is never a durable domain authority |

## VPN provisioning delivery audit

Each delivery attempt is stored as an independent
`ias_vpn_provisioning_delivery_audit` record. The record contains:

- a unique delivery ID;
- the Device ID;
- an optional OVPN provisioning transaction ID;
- a per-Device attempt number;
- operation, revision, status, and timestamp;
- a sanitized delivery-result summary.

The table is a KVS `set` with `disc_copies` under the current Mnesia backend.
There is no update or delete API for individual audit entries. `reset/0` is an
explicit development/test destructive reset used by Clear Demo State.

The following values are rejected recursively before persistence:

- private-key fields;
- certificate, CA, CSR, or key PEM/body fields;
- OVPN/artifact bodies;
- TLS-auth/TLS-crypt/shared-secret material;
- passwords, passphrases, and generic secret fields.

Writes are KVS-first. After commit, the entry is projected into ETS. At IAS
startup, the complete durable delivery history is validated and rehydrated before
Cowboy starts. If validation or rehydration fails, startup fails closed.

## Demo State diagnostics

The Demo State page reports both classification and current counts:

- durable domain objects and relationships;
- durable wizard drafts;
- durable delivery audit entries;
- ETS delivery audit projection entries;
- volatile certificate materials;
- volatile CSR enrollment states.

A durable count and its ETS projection count are shown separately so a failed or
incomplete rehydration is visible rather than silently masked.
