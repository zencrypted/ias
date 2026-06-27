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
| `ias_csr_enrollment_store` | durable | ETS CSR enrollment projection | resumable enrollment metadata and duplicate/reuse protection |
| `ias_certificate_material_store` | durable | ETS public-material projection | validated CA/client X.509 PEM; private keys forbidden |

Durable application code accesses records through KVS. Cross-record atomicity is
provided through `ias_kvs_transaction` and its configured backend provider.

## Volatile stores

| Store | Mode | Reason |
|---|---|---|
| `ias_vpn_event_bridge` | process memory | wake-up/subscription state is reconstructed at runtime |
| Nitro/WebSocket state | process memory | browser-session state is never a durable domain authority |

## CSR enrollment metadata

CSR enrollment state is stored as `ias_csr_enrollment_record` records in KVS.
The durable payload contains only workflow metadata such as CSR and public-key
fingerprints, device and wizard identifiers, lifecycle status, retryability,
failure labels, certificate identifiers, timestamps, and safe private-key
references. Raw CSR/CMP bodies, certificate PEM, private keys, passwords, and
shared secrets are rejected recursively before persistence.

At startup IAS validates every durable CSR enrollment record and rehydrates the
ETS read projection before Cowboy starts. This preserves duplicate-CSR and
public-key reuse protection across a full IAS restart. Unsupported schema
versions fail startup closed.


## Public certificate material

CA and client certificate PEM is stored as `ias_certificate_material_record`
records in KVS. The record key distinguishes attached certificate material from
staged CMP material. Writes are durable-first and the existing
`ias_certificate_material` module remains the compatibility façade and ETS read
projection. Startup validates every record and rehydrates the projection before
Cowboy starts. Unsupported schema versions, damaged protection envelopes,
fingerprint mismatches, invalid PEM, or an unavailable configured protection
provider fail startup closed.

Private keys, encrypted private keys, CSRs, shared secrets, and complete OVPN
artifacts are never accepted by this store. Full PEM reads require an explicit
internal purpose such as `ovpn_assembly`, `certificate_chain_validation`, or
`operator_inspection`; status and Demo State surfaces never include PEM bodies.

Attached certificate material is retained until explicit certificate-material
deletion or Clear Demo State. Staged CMP material uses
`certificate_material_staged_ttl_seconds` (24 hours by default), is pruned at
startup, and is moved atomically from the staged key to the attached certificate
key.

The protection provider is configured independently from KVS.
`ias_certificate_material_protection_public` is the default because X.509
certificates are public data; it stores normalized PEM with a SHA-256 integrity
envelope. Deployments that require ciphertext at rest can configure
`ias_certificate_material_protection_aes_gcm` and provide an external 32-byte
`certificate_material_encryption_key`. IAS fails closed if that key is missing or
incorrect. The encryption key itself is never stored in KVS.

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
- durable CSR enrollment states and their ETS projection;
- durable public certificate materials, their ETS projection, and the active protection provider.

A durable count and its ETS projection count are shown separately so a failed or
incomplete rehydration is visible rather than silently masked.
