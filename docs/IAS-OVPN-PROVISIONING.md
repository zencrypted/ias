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
future forward device-bound VPN provisioning flow. The wizard stores its active
draft in a separate ETS store and does not create relationships, provisioning
transactions or export artifacts merely by navigating between steps.

Once the wizard started carrying selected Device, Security Profile and VPN
Service references, sanitized drafts became part of the Demo State boundary.
Demo State export/import preserves only the wizard id, scenario, current step,
selected object ids, the relationship-apply marker, the latest provisioning
transaction id, completion metadata and timestamps. PEM, CSR, private-key, TLS
secret, form and session data are never included. Older
snapshots without `wizard_drafts` remain valid, and stale object references are
restored so the wizard can surface its
existing blocked-selection guidance rather than silently discarding operator
progress.

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

Stage 24G introduced a single graph commit boundary for the six required
links. Stage 24J keeps that boundary but makes the normal path automatic: `Next`
from Client Certificate runs the full preflight, applies all missing links
atomically when safe and continues directly to Material Readiness. The
Relationships step remains available for conflicts, retries and explicit review.

The committed links are:

```text
Device -> Security Profile
Device -> derived Security Policy
Device -> VPN Service
Device -> Client Certificate
Client Certificate -> derived Security Policy
VPN Service -> CA Certificate
```

Each link is reported as `will_create`, `already_linked`, `conflict`, `invalid`
or `stale_reference`. Missing links are created only through the existing
relationship service after every item passes preflight. Exact existing links are
idempotent. A different active operational target, an incompatible certificate
role, a stale object reference or a different Device Security Profile blocks the
whole apply action. If runtime creation fails after preflight, relationships
created by that apply attempt are rolled back before the error is returned.
Navigation to Material Readiness remains blocked until all six required links
are present. A selected Security Profile also displays its derived Security
Policy and makes clear that the policy will be applied to both the Device and the
Client Certificate during the automatic commit.

Stage 24H turns Material Readiness into a live preflight rather than a placeholder.
The wizard reuses the existing device-bound OVPN provisioning preview and checks
that the graph still matches the selected Device, VPN Service, CA certificate and
client certificate. It renders current authorization, endpoint, certificate trust,
public PEM, device-owned private-key and optional TLS-auth status without creating
a provisioning transaction.

Navigation to Provisioning is allowed only when the operational relationships are
still consistent, OVPN authorization allows the device-bound flow, the VPN endpoint
is available, both public certificate PEM bodies are present and assembly reports
`ready_for_device_assembly`. Missing public material is recovered through links to
the selected certificate detail pages. The final Provisioning step remains the
transaction creation boundary.

Stage 24I implements that final boundary. The wizard repeats the readiness
preflight immediately before calling the existing device-bound provisioning
service. The created transaction id is stored in the wizard draft together with
a completion marker and timestamp. Reopening or resubmitting a completed wizard
reuses the recorded transaction and does not create a duplicate. Creating a new
transaction requires the explicit `Create Another Transaction` action. Completed
wizard metadata is included in the sanitized Demo State draft section; the
provisioning transaction itself remains a normal sanitized runtime object.

Material observation is independent from authorization. The wizard reads CA and
client certificate availability directly from the public certificate material
store and reports a device-bound private key as `available_on_device` when the
selected Device exists. An authorization denial still blocks assembly and the
final readiness decision, but it must not relabel already stored public PEM as
missing or unavailable.

Stage 24K makes Material Readiness an active remediation surface. Entering or
refreshing the step re-runs relationship preflight, applies missing compatible
links through the existing relationship service and attempts the first client
certificate verification when no verification record exists. Failed
verification records are not retried automatically.

The page shows contextual actions only while their checks are unresolved:
`Open Device` for Device or policy problems, `Open VPN Service` for endpoint
problems, certificate links for missing or invalid public material, and
verification or relationship repair actions when those checks remain blocked.
Those actions disappear after the corresponding runtime state becomes ready.
The progress indicator derives the Relationships and Material Readiness states
from the current graph and readiness preview; a previously visited step is shown
as `blocked` if its runtime prerequisites later become stale or conflicting.

Stage 25A replaces the old implicit key assumption with an explicit
device-owned private-key reference. A device-bound private key is considered
available only when the Device has validated metadata:

```erlang
private_key_provider = <<"device_file">>
private_key_ref = <<"client.key">>
```

The reference is a safe relative path on the approved device. IAS does not
generate, read, store or export the private key body. Material Readiness blocks
device-bound provisioning when the reference is missing, invalid or uses an
unsupported provider, and the wizard links the operator back to the Device detail
page to configure it.

Material Contract
-----------------

Every Stage 23B transaction records the following sanitized metadata:

| Material | Requirement | Expected source | Current Stage 23B status |
| --- | --- | --- | --- |
| CA certificate PEM | required | CA certificate store | `missing_body` when referenced |
| Client certificate PEM | required | certificate store | `missing_body` when referenced |
| Private key, portable | required later | provisioning transaction | `pending_one_time_generation` |
| Private key, device-bound | validated reference | approved device | `available_on_device` only with `device_file` reference |
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
