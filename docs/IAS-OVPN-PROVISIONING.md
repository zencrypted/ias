OVPN Provisioning Material Contract
===================================

Purpose
-------

OVPN provisioning is the forward IAS workflow that assembles a device-bound
OpenVPN profile from IAS-managed objects when current authorization, graph,
certificate, lineage and material checks pass. Portable one-time delivery remains
future work. OVPN provisioning is separate from OVPN Import, which analyzes an
existing configuration and maps it into demo IAS metadata.

Current Flow
------------

Certificate or Device
-> Provisioning Authorization
-> Device key/CSR enrollment when required
-> Portable or Device-bound Transaction
-> Material and lineage checks
-> Assembly Readiness
-> Device-bound OVPN generation

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
`public_bundle_ready` for the current device-owned key reference. Missing public
material is recovered through links to the selected certificate detail pages. The
final Provisioning step remains the transaction creation boundary.

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
store and reports a device-bound private key as `available_on_device` only when
the selected Device has a validated `device_file` reference. An authorization
denial still blocks assembly and the final readiness decision, but it must not
relabel already stored public PEM as missing or unavailable.

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
private_key_ref = <<"keys/client.key">>
```

The reference is a safe relative path on the approved device. IAS does not
generate, read, store or export the private key body. The Provisioning Wizard
prepares a stable key-rotation plan only after an explicit operator action. The
plan contains a unique common name, CSR filename and relative key reference;
refreshing the page does not regenerate it, while an explicit regeneration
action replaces it. Sanitized pending filenames and references may survive Demo
State export/import, but no CSR or private-key body crosses that boundary.

The wizard now recommends the shared VPN-side `generate-device-csr.sh`
helper. IAS renders a short invocation containing the exact common name, CSR
filename and relative key reference from the stable enrollment plan. The helper
path is operator-editable for the current Device, but changing that path does not
change the plan or the future OVPN key reference.

The existing downloadable Device script remains available as an explicit
fallback when the shared helper is not installed. Both representations:

- create the relative `keys/` directory when needed;
- generate a fresh `secp384r1` private key for every enrollment;
- refuse to overwrite an existing key or CSR;
- set private-key permissions to `0600`;
- generate and verify the CSR;
- print only resulting file paths, never private-key contents.

Stage 25B adds device-bound OVPN bundle assembly. IAS assembles the public bundle
on demand from a provisioning transaction, the current VPN Service endpoint, the
selected Device tunnel settings, public CA/client PEM from
`ias_certificate_material` and the validated device-owned key reference. The
resulting profile embeds real public PEM blocks and uses an OpenVPN `key`
directive that points to the device-local key path. IAS never emits a `<key>`
block and never stores, exports or downloads a private-key body.

Stage 25C completes the production-aligned Device CSR enrollment path:

```text
Prepare key rotation plan
-> run script on Device
-> upload CSR only
-> reject duplicate CSR or reused public key
-> submit CSR to external CA through CMP
-> validate issued certificate against CSR and configured CA
-> record Device/CSR/certificate/key-reference lineage
-> update Device private-key reference
-> select the issued certificate in the wizard
-> clear the pending rotation
-> assemble the device-bound OVPN bundle
```

The certificate object records the Device id, CSR fingerprint, CSR public-key
fingerprint, certificate public-key fingerprint, relative private-key reference,
`issued_via = cmp` and `key_rotation = new_key_pair`. OVPN readiness requires
that this lineage matches the selected Device and current key reference. Failed
CMP issuance or certificate validation does not update the Device key reference.

A local end-to-end run confirmed that the SHA-256 fingerprint of the public key
derived from the generated Device private key equals the fingerprint of the
public key embedded in the CMP-issued certificate. This validates the full
key -> CSR -> certificate -> OVPN reference chain without exposing the private
key to IAS.

Material Contract
-----------------

Every Stage 23B transaction records the following sanitized metadata:

| Material | Requirement | Expected source | Current semantics |
| --- | --- | --- | --- |
| CA certificate PEM | required | volatile certificate-material store | `missing_body` or `available` |
| Client certificate PEM | required | volatile certificate-material store | `missing_body` or `available` |
| Private key, portable | required later | one-time provisioning operation | `pending_one_time_generation` |
| Private key, device-bound | validated reference and matching lineage | approved Device | `available_on_device` only with a safe `device_file` reference |
| TLS-auth | optional | VPN service | `not_configured` until supported |

Assembly Readiness
------------------

An authorized transaction remains blocked while public material, lineage or the
Device key reference is incomplete:

```text
status = awaiting_material
material_status = pending_real_material
assembly_status = blocked
artifact_status = skeleton_only
delivery_status = not_ready
```

After successful Device CSR enrollment, public CA/client PEM availability,
relationship preflight and lineage validation, the derived state becomes:

```text
status = ready_for_delivery
material_status = public_material_available
assembly_status = public_bundle_ready
artifact_status = public_bundle_ready
delivery_status = ready_for_device_import
```

Portable mode still remains blocked on future one-time private-key generation.
Device-bound mode can generate a real public `.ovpn` body on demand, but the
private key remains a separate Device-owned file referenced through `key`.

Security Boundary
-----------------

The current device-bound flow:

* never generates, reads, stores or renders the Device private-key body in IAS;
* generates the private key only when the operator runs the downloaded script on
  the Device;
* sends only the uploaded CSR to the external CA/CMP service;
* retains CSR and public-key fingerprints, not the CSR body, as lineage metadata;
* stores issued public certificate PEM only in the volatile public-material store,
  outside Demo State metadata;
* never emits an inline `<key>` block;
* generates assembled OVPN bodies on demand and does not store them in Demo State;
* marks a transaction deliverable only while current authorization, graph, public
  material, certificate chain, lineage and key-reference preflight still pass.

IAS can verify that the issued certificate matches the uploaded CSR. It cannot
cryptographically prove that a particular local filename still contains the
matching private key; that final check belongs to the Device and can be performed
by comparing public-key fingerprints.

The Demo State export/import boundary continues to contain sanitized metadata
only.

Future Direction
----------------

Stage 26 should add artifact delivery and audit semantics: artifact SHA-256,
generation/download timestamps and explicit `generated`, `downloaded`,
`delivered` and `imported` states without persisting the OVPN body. A real VPN
connection test additionally requires a non-placeholder VPN Service endpoint.
Portable one-time private-key generation remains a separate future flow.

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
loaded. Once both linked public certificate bodies are available and the selected
Device has a valid device-owned private-key reference:

- device-bound mode becomes `ready_for_delivery`;
- material becomes `public_material_available`;
- assembly and artifact become `public_bundle_ready`;
- delivery becomes `ready_for_device_import`;
- the private key remains on the device and the generated OVPN references it
  with `key <private_key_ref>`;
- portable mode becomes `awaiting_private_key_generation`; no private key is
  generated by Stage 23C/25B.

Demo State export/import does not include the material table or any PEM body.
Clearing or importing Demo State clears the volatile public material store so a
restored metadata snapshot cannot accidentally retain unrelated certificate
bodies.

### X.509 and Assembly Validation

Device-bound OVPN assembly validates certificate material at the delivery
boundary before any `.ovpn` body is generated.

The selected CA trust anchor must decode as X.509, contain
`basicConstraints CA=TRUE`, include `keyCertSign` when Key Usage is present, and
be currently valid in strict mode. The selected client certificate must decode as
X.509, must not be a CA certificate, must be currently valid in strict mode, and
must include `clientAuth` when Extended Key Usage is present.

Assembly also requires distinct CA/client fingerprints and, in strict mode, the
client certificate must verify against the selected CA. OVPN directive values are
validated at the same boundary: protocol is limited to `udp` or `tcp`, port must
be `1..65535`, endpoints and tunnel devices must not contain injection
characters, and the device-owned key reference must remain a safe relative path.

The server-side `certificate_validation_mode` application setting defaults to
`strict`. A development mode may relax validity and chain checks for demo
fixtures, but it is not switchable from request parameters or wizard UI and does
not bypass PEM parsing, role separation, identical fingerprint checks, secret
sanitization or OVPN directive injection protections. Transactions created in
development mode record the bypass metadata and render a visible warning.

## Canonical VPN Runtime Provisioning Command

IAS now prepares a revisioned, sanitized runtime command independently from OVPN artifact export:

```erlang
{ok, Command} = ias_vpn_provisioning_command:build(DeviceId).
```

The command contains only runtime identity and authorization metadata. It never contains private-key material, PEM bodies, or an OVPN document. Repeated preparation of an unchanged projection keeps the same revision; a material operation or desired-state change advances the per-device revision.

This stage intentionally does not deliver the command to VPN. Delivery is a separate adapter so previewing or rendering IAS pages cannot mutate VPN runtime state.
