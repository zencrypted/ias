OVPN Provisioning Material Contract
===================================

Purpose
-------

OVPN provisioning is the forward IAS workflow that will eventually assemble a
user- or device-deliverable OpenVPN profile from IAS-managed objects. It is
separate from OVPN Import, which analyzes an existing configuration and maps it
into demo IAS metadata.

Current Flow
------------

Certificate or Device
-> Provisioning Authorization
-> Portable or Device-bound Transaction
-> Material Requirements
-> Material Sources
-> Component Status
-> Assembly Readiness

Manual Demo Device Creation
---------------------------

OVPN Import is not the only way to bootstrap a runtime Device in IAS. It remains
the migration, onboarding and legacy-profile analysis workflow for existing
OpenVPN configurations.

Stage 23D adds live-runtime demo Device creation so an operator can start the
forward IAS flow without importing an `.ovpn` file:

```text
Create Demo Device
-> create/link Certificate
-> link Security Profile
-> link VPN Service
-> load public certificate material
-> create device-bound OVPN provisioning
```

The created object is node-local demo runtime metadata with
`source = manual_device`. It is suitable for relationship linking, device
readiness analysis and device-bound OVPN provisioning previews.

This is not production device enrollment. It does not generate private keys,
create CSRs, call CA/CMP, create certificates automatically, persist device
records, start VPN connections or create relationships automatically.

Operational Relationship Constraints
------------------------------------

Stage 23E makes the operational graph explicit and non-ambiguous for OVPN
provisioning. New runtime relationship creation enforces:

- one active `Device -> uses_certificate -> Certificate`;
- one active `Device -> uses_service -> VPN Service`;
- one active `VPN Service -> uses_ca_certificate -> Certificate`.

Existing exact duplicate relationship creation remains idempotent, but a second
active target is rejected with the already-linked object id. Certificate role
metadata is checked before linking:

- `uses_certificate` accepts client certificates and rejects explicit CA
  certificates;
- `uses_ca_certificate` accepts CA certificates and rejects explicit client
  certificates;
- unclassified certificates may still be linked, but the UI surfaces a warning
  so the operator can review the material role.

Legacy snapshots may still contain ambiguous operational relationships. IAS does
not delete those relationships automatically. Instead Graph Analysis and Device
Operational Readiness surface the conflict, and OVPN provisioning remains
blocked until the operator manually unlinks the extra operational relationship.

Device-bound Provisioning Wizard Skeleton
-----------------------------------------

Stage 24A introduces a live-runtime-only Provisioning Wizard entry point for the
future forward device-bound VPN provisioning flow. The wizard stores only a
volatile ETS draft outside Demo State and does not create IAS objects,
relationships, provisioning transactions or export artifacts.

The current skeleton defines the orchestration path:

```text
Scheme
-> Device
-> Security Profile
-> VPN Service
-> CA Certificate
-> Client Certificate
-> Relationships
-> Material Readiness
-> Provisioning
```

Only the Device-bound VPN Profile scheme is active in this stage. Import Existing
OVPN remains a link to the existing OVPN onboarding flow, and Portable VPN
Profile remains disabled until one-time private-key generation and delivery are
implemented.

Material Contract
-----------------

Every Stage 23B transaction records the following sanitized metadata:

| Material | Requirement | Expected source | Current Stage 23B status |
| --- | --- | --- | --- |
| CA certificate PEM | required | CA certificate store | `missing_body` when referenced |
| Client certificate PEM | required | certificate store | `missing_body` when referenced |
| Private key, portable | required later | provisioning transaction | `pending_one_time_generation` |
| Private key, device-bound | device-owned | approved device | `available_on_device` |
| TLS-auth | optional | VPN service | `not_configured` |

Assembly Readiness
------------------

An authorized transaction remains:

```text
status = awaiting_material
material_status = pending_real_material
assembly_status = blocked
artifact_status = skeleton_only
delivery_status = not_ready
```

The assembly reason lists the missing public certificate material and, for
portable mode, the pending one-time private-key generation step. The next step
points the operator toward a future CA/CMP response or certificate material
store.

Security Boundary
-----------------

Stage 23B does not:

* generate a private key;
* call CA/CMP;
* store CA or client certificate PEM bodies;
* store CSR, TLS-auth, TLS-crypt or shared-secret material;
* assemble a complete OVPN profile;
* mark a transaction as deliverable.

The Demo State export/import boundary continues to contain sanitized metadata
only.

Future Direction
----------------

The next implementation stages should provide public certificate material first,
then implement device-bound assembly, and only afterwards introduce portable
one-time private-key generation and one-time delivery.

## Stage 23C — Public Certificate Material Store

IAS keeps certificate metadata and certificate bodies in separate runtime stores.
Public X.509 PEM material is held in the node-local `ias_certificate_material`
ETS table and is never added to certificate demo objects.

The store accepts exactly one public certificate PEM block for an existing IAS
certificate object. It rejects empty input, multiple PEM objects, unsupported
material types and every recognized private-key PEM marker. Stored status
metadata includes the material role, source, timestamp and SHA-256 fingerprint;
the body is returned only through the material-store API.

An operator may load public PEM from a certificate detail page. The material is
classified as either a CA certificate or a client certificate from the IAS
certificate role. Successful CA/CMP enrollment responses stage the returned
public certificate PEM in the same volatile boundary. When the enrollment is
imported as an IAS certificate object, the staged PEM is attached with
`source = cmp_response`.

Provisioning transactions refresh their material readiness when rendered or
loaded. Once both linked public certificate bodies are available:

- device-bound mode becomes `ready_for_device_assembly`; the private key remains
  on the device;
- portable mode becomes `awaiting_private_key_generation`; no private key is
  generated by Stage 23C.

Demo State export/import does not include the material table or any PEM body.
Clearing or importing Demo State clears the volatile public material store so a
restored metadata snapshot cannot accidentally retain unrelated certificate
bodies.
