# Architecture Technical Debt

This document tracks known architectural debt items discovered during IAS development.

---

## TD-001: Repeated Graph Lookup During Analysis

**Status:** Open

**Area:** Relationship Explorer

### Problem

Graph Analysis currently performs repeated object lookups while rendering warnings and diagnostics.

Typical pattern:

```erlang
object_link(Type, Id) ->
    case ias_demo_store:get(Id) of
        ...
    end.
```

Multiple warning sections independently resolve the same objects:

- Policy Mismatch
- Certificates Without Security Policy
- Devices With Replacement Available
- Enrollment Certificates Without Issued Certificate

### Current Impact

Low.

Current demo datasets contain only a small number of:

- devices
- certificates
- policies
- relationships

Performance impact is negligible.

### Desired Direction

Introduce a graph snapshot or lookup cache during Relationship Explorer rendering:

Graph Snapshot
    -> Graph Analysis
    -> Warning Sections


Object resolution should occur once per page render.

### Priority

Low

---

## TD-002: Graph Analysis Warning Reason Details

**Status:** Open

**Area:** Relationship Explorer / Graph Analysis

### Problem

Graph Analysis now renders concrete object links for warning details, but some warnings still do not explain why the object is considered problematic.

For example, `Certificates Without Security Policy` lists certificate IDs, but does not tell the operator whether the problem is:

- no `uses_security_policy` relationship exists;
- the relationship points to a missing security policy object;
- the certificate is an enrollment/import artifact where policy assignment is expected later.

This makes the warning actionable only after manually opening each certificate detail page.

### Current Impact

Low to medium.

The warning counts are correct, but the operator still needs extra navigation to understand the cause.

### Desired Direction

Extend Graph Analysis detail rows with explicit reasons.

Example:

```text
Certificate #cmp_enrollment_...
Reason: no uses_security_policy relationship
```

or:

```text
Certificate #...
Reason: referenced security policy object is missing
```

The same pattern should be reused for other warnings where a missing relationship or missing object is the underlying cause.

### Priority

Low

---

## TD-003: Relationship Explorer Scalability And Readability

**Status:** Open

**Area:** Relationship Explorer

### Problem

Relationship Explorer currently renders the full runtime graph as a single preformatted tree.

This is readable for small demo states, but it will become difficult to inspect when the runtime contains many:

- devices;
- certificates;
- enrollments;
- verification records;
- relationship edges.

The graph already becomes visually dense after several OVPN imports, certificate enrollments, and issued certificates.

### Current Impact

Low.

The current demo graph is still small enough to inspect manually.

### Desired Direction

Add grouping and navigation controls once the graph grows.

Possible improvements:

- group by source object kind;
- group by relationship type;
- collapse/expand source nodes;
- filter by object id;
- filter by warning type;
- separate lifecycle edges from policy/device/service edges.

Do not add these controls until the graph is large enough to justify the UI complexity.

### Priority

Low

---

## TD-004: Bulk Verification Result Rendering

**Status:** Open

**Area:** Certificate Verification / Graph Analysis

### Problem

Bulk verification now creates verification audit records for all runtime certificates and shows a per-certificate result list after the action completes.

This is correct for debugging, but the result panel can become large very quickly because verification records are append-only audit events.

Repeated bulk verification runs may produce many records for the same certificates:

```text
Unique Verified Certificates: 9
Total Verification Records: 15
```

The distinction is correct, but the UI may become noisy when every verification event is rendered inline.

### Current Impact

Low.

The current runtime graph is still small, and the detailed result list is useful while the lifecycle is being tested.

### Desired Direction

Keep verification history append-only, but improve result rendering once the data grows.

Possible improvements:

- show a compact bulk verification summary by default;
- collapse per-certificate details;
- group verification events by certificate;
- show latest verification first;
- add an explicit "show verification history" action;
- distinguish unique verified certificates from total verification records consistently across UI pages.

### Priority

Low

---

## TD-005: Object Link Tooltip Hints

**Status:** Open

**Area:** IAS UI / Relationship Explorer

### Problem

IAS pages now contain many clickable object references:

- `User #...`
- `Device #...`
- `Certificate #...`
- `Security Profile #...`
- `Security Policy #...`
- `VPN Service #...`
- `Verification #...`

These references are rendered as blue links, but the UI does not explain what will happen when the operator clicks them.

This is increasingly confusing because the same page may contain links to different object kinds, lifecycle records, policies, certificates, and graph diagnostics.

### Current Impact

Medium.

The graph is already useful, but new users must infer link behavior from naming conventions alone. This makes Relationship Explorer and Graph Analysis harder to understand than necessary.

### Desired Direction

Add lightweight tooltip hints to object links.

The first iteration should be simple and consistent:

```text
Certificate #issued_certificate_alice_...
Tooltip: Certificate — open certificate details

Security Policy #high_security
Tooltip: Security Policy — open policy details

Verification #verification_...
Tooltip: Verification — open verification record
```

The tooltip should explain two things:

1. the object kind;
2. the navigation action.

Do not turn tooltips into large data cards yet. Keep them short and stable.

### Priority

Medium

---

## TD-006: Device Readiness Suggested Action Labels

**Status:** Open

**Area:** Device Operational Readiness / IAS UI

### Problem

Device Operational Readiness now renders suggested actions as navigational helpers.

For example, after a current certificate is revoked, the device page may show:

```text
Suggested Actions
- Link VPN Service        [Open Device]
- Link Security Policy    [Open Device]
- Replace Certificate     [Open Device]
- Link New Certificate    [Open Device]
```

This is functionally correct because the buttons navigate to the object where the operator can take the next step. However, the repeated `Open Device` label is too generic and does not reflect the action being suggested.

The operator has to read the left-side text and mentally connect it to a generic navigation button. This is especially awkward for actions like `Replace Certificate` or `Link New Certificate`, where the next target may be the device page, current certificate page, or candidate certificate context.

### Current Impact

Low to medium.

The readiness workflow is usable and the navigation buttons work, but the suggested action area still feels like a debug/helper view rather than a polished operator workflow.

### Desired Direction

Make readiness suggested actions more explicit and action-oriented while keeping them navigational only.

Possible labels:

```text
Link VPN Service          [Fix]
Link Security Policy      [Fix]
Replace Certificate       [Replace]
Link New Certificate      [Open Candidate]
Link Certificate Policy   [Open Certificate]
```

The button text should describe the next operator action more clearly than `Open Device`.

Do not automatically create relationships in this step. This remains a navigation and UX improvement only.

### Priority

Low

---

## TD-007: OVPN Export Readiness Reason Visibility

**Status:** Open

**Area:** Device Detail / OVPN Export Preview

### Problem

The OVPN provisioning UI can currently show a mixed readiness state such as:

```text
CA Certificate: degraded
Export Artifact: available
```

The state is internally consistent: the operator may inspect or download a configuration skeleton even though real CA certificate material is not yet available. However, the readiness table does not explain why the CA certificate is degraded.

Without that explanation, the operator can reasonably interpret `Export Artifact: available` as meaning that a user-deliverable OVPN profile is ready.

### Current Impact

Medium.

The UI does correctly label the configuration as a skeleton elsewhere, but the compact readiness table can still create ambiguity about whether real PEM material has been assembled.

### Desired Direction

Render a concise reason beside degraded material states.

Example:

```text
CA Certificate: degraded — metadata only, PEM body absent
Export Artifact: skeleton available
```

The same pattern should eventually be applied to other provisioning material states, including:

- client certificate body absent;
- device-owned private key not available to IAS;
- TLS authentication material absent;
- provisioning transaction expired.

Keep the wording compact enough for readiness tables and preserve a separate detailed explanation in the provisioning transaction view.

### Priority

Medium

---

## TD-008: OVPN Skeleton And Provisioning Action Separation

**Status:** Open

**Area:** Device Detail / OVPN Provisioning

### Problem

The device detail page currently presents both of these actions in the same provisioning section:

- `Download OVPN Skeleton`;
- `Create Device-bound Provisioning`.

The first action downloads an operator-facing configuration preview with no real secret material. The second creates a short-lived provisioning transaction that represents an operator workflow toward a real device-bound profile.

Although both labels are technically correct, their visual proximity makes the skeleton download look like an alternative delivery path for the same final artifact.

### Current Impact

Low to medium.

Experienced operators can distinguish the actions from the explanatory text, but new users may expect both buttons to produce usable user-facing VPN profiles.

### Desired Direction

Separate technical preview actions from provisioning actions visually and semantically.

Suggested structure:

```text
Configuration Preview
- View OVPN Skeleton
- Download OVPN Skeleton

Provisioning
- Create Device-bound Provisioning
- View Active Provisioning Transaction
```

The production UI should reserve terms such as `Generate`, `Deliver`, and `Download Profile` for artifacts that contain all required real material and are ready for their intended delivery mode.

### Priority

Medium

---

## TD-009: Demo CA Role Is Operator-Asserted

**Status:** Resolved by X.509 certificate validation

**Area:** Certificate Registration / X.509 Validation

### Problem

Manual Demo CA Certificate registration used to validate that submitted material
contained exactly one public X.509 certificate PEM block, but did not verify that
the decoded certificate was actually permitted to act as a certification
authority.

The runtime metadata currently trusts the operator-selected role:

```text
certificate_role: ca_certificate
material_type: ca_certificate
```

A syntactically valid leaf certificate could therefore be registered as a demo
CA certificate even when its X.509 extensions did not contain an affirmative CA
constraint.

### Resolution

IAS now validates certificate material by semantic role through
`ias_x509_validation`.

Manual CA trust anchor registration requires a decodable X.509 certificate with
`basicConstraints CA=TRUE` and, when Key Usage is present, `keyCertSign`.

Device-bound OVPN assembly validates the selected CA and client certificate
roles again, rejects identical CA/client fingerprints, verifies the client
certificate against the selected CA in strict mode, and rejects unsafe OVPN
directive values before producing any bundle.

The lower-level public material store still preserves its role as a volatile PEM
body store. Semantic role validation is enforced at the CA registration and OVPN
assembly boundaries where IAS has enough context to make trust decisions.

### Priority

Closed

---

## TD-010: Provisioning Status Is Not Derived From Current Readiness

**Status:** Resolved by Stage 25B

**Area:** OVPN Provisioning Transaction

### Problem

OVPN provisioning transactions refresh their material and assembly readiness when rendered, but the top-level transaction `status` remains the value captured when the transaction was created.

For example, a transaction may display:

```text
Status: awaiting_material
Material: public_material_available
Assembly: ready_for_device_assembly
```

The detailed readiness fields are correct, but the aggregate status is stale and contradicts them.

### Current Impact

Medium.

The current UI and provisioning logic use the detailed material and assembly states, so the workflow is not blocked. However, operators and future API consumers can misinterpret the transaction state when relying on the top-level `status` field.

The stale value is also exported as transaction metadata in Demo State, which preserves historical creation state rather than current derived readiness.

### Desired Direction

Define a single state-transition function that derives the aggregate provisioning status from current authorization, expiration, material readiness, assembly readiness, delivery state, and download state.

Example progression:

```text
awaiting_material
-> ready_for_device_assembly
-> ready_for_delivery
-> delivered
```

Stage 25B implemented the first derived transaction lifecycle for device-bound
OVPN provisioning. When authorization still passes, public CA/client PEM is
available and the selected Device has a valid device-owned private-key
reference, refresh derives:

```text
Status: ready_for_delivery
Material: public_material_available
Assembly: public_bundle_ready
Artifact: public_bundle_ready
Delivery: ready_for_device_import
```

The implementation:

- avoids maintaining contradictory status fields independently;
- clearly separates immutable transaction history from current derived state;
- uses the same derived semantics in detail pages, lists, exports, tests and future APIs;
- preserves backward compatibility for previously exported Demo State where practical.

Future production lifecycle work still needs explicit expiration and delivery
audit semantics, but the stale `awaiting_material` display for ready public
bundles is closed.

### Priority

Medium

---

## TD-011: Nitro Template-Literal Safety Is Page-Local

**Status:** Open

**Area:** Nitro Rendering / Dynamic Script And Configuration Text

### Problem

Nitro DOM insertion serializes rendered HTML inside a JavaScript template
literal. HTML escaping does not neutralize raw `${...}`, backticks or shell line
continuation backslashes. A generated Device CSR script previously caused the
client-side Nitro command to fail parsing while every server callback returned
normally, leaving the static loading placeholder visible.

The immediate CSR page fix uses a local `nitro_html_escape/1` helper, but the same
class of bug can recur on any page that renders generated scripts or configs.

### Desired Direction

Move this policy into a shared, explicitly named helper with tests for HTML and
Nitro template-literal contexts. Audit existing websocket-rendered multiline
text and prohibit ad-hoc raw insertion. Keep browser-side regression coverage for
`${...}`, backticks and backslashes.

### Priority

High

---

## TD-012: OVPN Artifact Delivery Audit Is Missing

**Status:** Open

**Area:** OVPN Provisioning Artifact Lifecycle

### Problem

IAS can derive `public_bundle_ready` and generate a device-bound `.ovpn` on
demand, but the transaction still does not distinguish artifact generation,
download, delivery to the Device and successful import. The existing
`downloaded` field remains historical scaffolding rather than an authoritative
audit event.

### Desired Direction

Record non-secret lifecycle metadata such as artifact SHA-256, generation time,
download time and explicit `generated`, `downloaded`, `delivered` and `imported`
states. Do not persist the OVPN body or any private-key material.

### Priority

High

---

## TD-013: Placeholder VPN Endpoints Are Exportable

**Status:** Open

**Area:** VPN Service / Device-bound OVPN Assembly

### Problem

A syntactically safe endpoint such as `vpn.example.com:1194` can pass assembly
validation and produce a structurally correct artifact even though it cannot be
used for a real deployment.

### Desired Direction

Mark known demo placeholders explicitly. In strict/production mode, block final
delivery until the VPN Service has a non-placeholder endpoint. Development mode
may keep preview/export behavior with a visible warning.

### Priority

Medium

---

## TD-014: Device Enrollment Completion Is Not Atomic

**Status:** Open

**Area:** CMP Enrollment / Wizard Orchestration

### Problem

Successful enrollment currently spans several writes: import certificate and
public material, update the Device key reference, select the certificate in the
wizard and clear pending rotation metadata. A later failure can leave a partially
completed state.

### Desired Direction

Introduce an atomic orchestration boundary or compensating rollback/recovery for
all enrollment-completion writes. Make retries idempotent and preserve enough
lineage state to resume safely after process or node failure.

### Progress

Stage 5B now atomically commits the final OVPN provisioning domain object and the
durable wizard transition to `completed`, with optimistic conflict detection and
post-commit ETS projection. The broader CMP enrollment path still spans public
certificate material, Device key-reference updates and draft metadata, so this
item remains open until that separate material workflow gains an equivalent
recovery boundary.

### Priority

High

---

## TD-015: Generic Wizard Errors Lose Context

**Status:** Open

**Area:** Provisioning Wizard Error Handling

### Problem

The generic `redirect_after({error, _Reason}) -> start_url()` path discards the
current wizard context and hides actionable failure reasons. CSR plan actions now
have contextual handling, but other wizard actions can still redirect to the
start page without a visible explanation.

### Desired Direction

Adopt one wizard error boundary that preserves the draft id, renders a safe
operator-facing error panel and logs the full server-side reason and stack. Avoid
silent fallback redirects for domain or validation failures.

### Priority

Medium

---

## TD-016: Device CSR Plan Has Duplicate Command Representations

**Status:** Partially Addressed

**Area:** Device CSR Script Generation

### Problem

A key/CSR plan still carries a legacy compact `command` value. The wizard now
renders the shared VPN helper invocation from the structured plan and keeps
`ias_device_csr_command:script/1` only as an explicit standalone fallback.
The unused legacy `command` field still risks behavior drift.

### Desired Direction

Remove the unused legacy `command` field. Keep the structured plan as the single
source of truth, with separate renderers only for the shared helper invocation
and the documented standalone fallback.

### Priority

Low

---

## TD-017: Client Certificate EKU Is Broader Than Required

**Status:** Open

**Area:** CA Certificate Profile

### Problem

The current local CA profile may issue a VPN client certificate containing both
`clientAuth` and `serverAuth`. Device-bound OVPN validation correctly requires
`clientAuth`, but the issued identity has more purpose than the client flow needs.

### Desired Direction

Introduce a dedicated VPN client issuance profile with only the required key
usage and Extended Key Usage values. Keep CA-side profile selection explicit and
record the selected profile in enrollment lineage.

### Priority

Medium

### VPN runtime development authorization display

The VPN status page now preserves an explicit `development_bypass` decision
reported by the VPN runtime instead of re-evaluating it as an IAS policy denial.
All peers in `policy` mode continue to be evaluated against IAS Device and
Security Profile relationships. The bypass remains a development-only runtime
contract and must never be inferred from a missing profile.


---

## Completed — TD-018 Single-RPC Dynamic Pair Bootstrap

**Status:** Completed

**Area:** IAS to VPN Dynamic Provisioning

The first allocator-backed dynamic upsert now uses one serialized VPN boundary:

```erlang
vpn_provisioning:apply_dynamic(DeviceId, Command).
```

IAS builds the positive-revision canonical command before any pair is started.
VPN validates the Device/allocation/client-peer binding, materializes the
development identity, writes both registry entries with the final IAS revision,
waits for both intended runtime generations and certificate-control handshakes,
and commits the provisioning head only after success. Resolution, registry,
startup, or handshake failure rolls the pair back and leaves the same revision
safe to retry.

The runtime-generated client certificate fingerprint is not guessed or copied
from the IAS enrollment certificate into the first command. VPN returns it in
the safe pair projection; IAS validates the complete allocation/revision binding
and stores the fingerprint only as Device operational metadata. This keeps the
canonical command stable across retries while VPN remains the owner of dynamic
identity material.

If an applied reply is lost, retry returns `unchanged`; IAS recovers a missing
local Device binding with one validated `vpn_dynamic_pair:status/1` read. This
keeps the accepted revision idempotent without requiring the normal bootstrap to
return to a two-step mutating flow.

The former `vpn_dynamic_pair:ensure/2` followed by
`vpn_provisioning:apply/1` path remains compatibility-only for older IAS
releases and is no longer used by current IAS dynamic upsert delivery.

---

## TD-019: Durable IAS/VPN Projection Reconciliation

**Status:** Partially resolved

**Area:** IAS/VPN Dynamic Allocation Recovery

### Completed

VPN persists allocation ownership, generations, revision heads, restrictive
barriers, and the recoverable registry projection in KVS/Mnesia. IAS persists its
canonical VPN command ledger and public Device binding/decommission metadata in
its own KVS/Mnesia table. Both sides now survive independent node restarts without
silently resetting their local revision or allocation identity.

### Remaining Direction

IAS and VPN must compare their durable projections after reconnect. IAS-ahead
state should be replayed idempotently, while VPN-ahead state or an unknown VPN
allocation must be reported as divergence and handled fail-closed. This is Stage
8B.2 and remains open.

### Priority

High before production deployment

---

## TD-020: VPN Runtime Auto-refresh Disrupted Browser Position

**Status:** Resolved and superseded

**Area:** IAS VPN Runtime UI

### Problem

The VPN runtime page originally refreshed its runtime panels by programmatically
clicking a hidden Nitro link on a browser timer. Besides moving the viewport,
periodic replacement could race with reconciliation controls and discard operator
input.

### Resolution

Browser polling has been removed. A supervised `ias_vpn_event_bridge` subscribes
to the VPN `vpn_event_bus`, reads a fresh runtime summary after each completed VPN
reconciliation event, and pushes a Nitro direct message to active VPN page
websocket processes. `Refresh now` remains as a manual fallback when the event
stream is unavailable.

Runtime events replace only the independent read-only targets
`vpn_runtime_refresh_status`, `vpn_runtime_event_status`, and
`vpn_runtime_summary`. Ordinary runtime changes leave reconciliation forms intact
and set a separate stale notice. A successful initial subscription or reconnect
also refreshes the independent read-only reconciliation comparison and controls,
while the incident editor target remains untouched. This removes stale
`nodedown` comparison errors without discarding actor/note input or rewiring
incident actions. Controls that depend on a fresh report are disabled when the
comparison is unavailable.

The bridge monitors the remote event-bus process and reconnects after VPN node or
event-bus restart. A distributed Erlang `nodeup` notification triggers an
immediate reconnect, while a quiet retry timer remains as a discovery and recovery
safety net for both full node outages and event-bus restarts. Retry attempts update
bridge diagnostics but do not repeatedly notify page processes unless the visible
connection or snapshot state changes. Disconnect is represented explicitly in the UI: the previous
runtime table is retained as a last-known snapshot, marked stale, and accompanied
by a visible reconnecting notice. Event-stream subscription and runtime snapshot
freshness are separate states; reconnect is reported as successful only when the
summary read also succeeds. If subscription succeeds but the summary read fails,
the page preserves the last-known rows and asks the operator to retry with
`Refresh now`.

---

## TD-021: Orphan VPN Projection Disposition Policy

**Status:** Open

**Area:** IAS/VPN Reconciliation / Recovery Policy

### Problem

Reconciliation can identify a VPN projection marked as IAS-owned while IAS has
no matching durable VPN authority record. The projection is reported as
`orphan`, but the product does not yet define a complete operator workflow for
its disposition.

Copying the VPN record into `ias_demo_store` is not a valid recovery mechanism:
ETS is volatile, VPN does not contain the complete IAS object graph, and
automatic adoption would reverse the intended `IAS -> VPN` authority direction.
Likewise, automatically deleting the VPN projection could remove legitimate
access created before the durable authority ledger was introduced or during a
partially completed provisioning transaction.

### Constraints

- automatic orphan adoption is prohibited;
- automatic destructive cleanup is prohibited;
- an orphan must remain fail-closed and visible as an incident;
- any disposition must validate the current reconciliation snapshot token;
- actor, note, timestamp, source metadata and result must be audited;
- recovery into IAS requires durable domain-state persistence, not an ETS-only
  object.

### Desired Direction

Define two explicit administrative procedures:

```text
Decommission from VPN
Recover into IAS
```

`Decommission from VPN` should validate that the projection is still orphaned,
apply the appropriate restrictive/decommission command, and close the incident
only after reconciliation confirms removal.

`Recover into IAS` should guide an operator through validation and creation of a
complete durable IAS graph: Device ownership, Certificate metadata, VPN Service,
Security Profile and required relationships. VPN metadata is evidence for the
recovery plan, not an authority source by itself.

The detailed durable-state prerequisite is documented in
`docs/IAS-DURABLE-STATE.md`.

### Priority

Medium during development; High before production deployment

---

## TD-022: Durable IAS Domain State And Rehydration

**Status:** Resolved for the supported domain graph

**Area:** IAS Object Graph / Runtime Persistence

### Problem

Most live IAS domain objects and relationships are stored only in
`ias_demo_store` ETS, while Provisioning Wizard drafts are stored in a separate
ETS table. They disappear when the IAS VM restarts. The narrow
`ias_vpn_authority` Mnesia ledger survives restart, so the UI can lose the
Device, Certificate, VPN Service and relationship graph even when IAS and VPN
remain synchronized at the control-plane level.

Manual Demo State export/import is sanitized development tooling. It is not an
automatic source of truth, a transactional store or startup rehydration.

### Completed

Stage 1 introduced the standalone `ias_domain_store` skeleton and the
`ias_domain_object` table registered in `ias_kvs`. The store validates a
kind-specific public projection, rejects secret-bearing data, maintains
monotonic revisions, and enforces relationship references and guarded deletion.

Stage 2A connected the single-object `ias_demo_store` write, delete,
relationship, enrollment-result and reset paths to the durable KVS boundary.
ETS is updated only after a successful durable commit.

Stage 2B added `ias_demo_store:commit_graph/2`. Domain objects and their
relationship edges are staged in one `ias_domain_store:transaction/1` unit of
work and become visible through ETS only after the complete KVS graph commit.
OVPN import and provisioning-wizard relationship application use this boundary.

Stage 3A added `ias_demo_store:rehydrate/0` and
`ias_demo_store:projection_health/0`. The engine rebuilds the complete ETS
projection from validated KVS records, overlays durable VPN authority, preserves
the previous projection when recovery fails, and reports synchronized, mismatch
or unavailable state with object/relationship counts.

Stage 3B added fail-closed startup integration through
`ias_bootstrap:prepare/0`. KVS, the durable domain store, VPN authority and the
incident ledger are validated and ETS is rehydrated before Cowboy starts. Demo
State exposes durable/ETS counts, projection status and rehydration metadata.

Stage 4 added deterministic SHA-256 tokens for the durable and ETS projections
and `ias_persistence_SUITE`. The Common Test restarts a separate IAS VM against
the same Mnesia directory, verifies the complete supported wizard graph and VPN
authority overlay, proves reconciliation does not create a false orphan, checks
idempotent repeated restart, and confirms that an incompatible schema leaves the
HTTP port closed.

Stage 5A added durable active/completed/abandoned wizard drafts, secret-material
rejection and fail-closed startup rehydration. Stage 5B added a single
`mnesia:sync_transaction/1` boundary for the prepared OVPN provisioning domain
object and the wizard transition to `completed`; stale or invalid draft writes
roll back the domain record, and both ETS projections are applied only after
commit. The restart suite now verifies that the paired completion survives a
full IAS VM restart.

### Remaining Direction

The supported public domain graph now uses the IAS-owned KVS store, backed by
Mnesia `disc_copies`, as its source of truth and rebuilds ETS before HTTP startup.
Writes are durable-first, graph commits are atomic within the KVS domain boundary,
and incompatible schemas fail closed.

CMP enrollment completion still crosses the certificate-material store and
Device key-reference updates, so its wider recovery boundary remains coordinated
with `TD-014`. Durable wizard drafts and final OVPN completion are now covered;
public certificate material, audit retention and secret storage remain separate
future stages. Private keys, TLS secrets, OVPN bodies, certificate bodies and
browser/session state are outside this resolved domain-graph milestone.

Implementation stages, persistence classification, schema proposal, failure
semantics, restart tests and acceptance criteria are defined in
`docs/IAS-DURABLE-STATE.md`.

### Priority

High
