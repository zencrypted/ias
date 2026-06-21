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

**Status:** Open

**Area:** Certificate Registration / X.509 Validation

### Problem

Manual Demo CA Certificate registration validates that the submitted material contains exactly one public X.509 certificate PEM block, but it does not yet verify that the decoded certificate is actually permitted to act as a certification authority.

The runtime metadata currently trusts the operator-selected role:

```text
certificate_role: ca_certificate
material_type: ca_certificate
```

A syntactically valid leaf certificate can therefore be registered as a demo CA certificate even when its X.509 extensions do not contain an affirmative CA constraint.

### Current Impact

Medium.

Relationship constraints prevent explicitly classified client certificates from being linked as VPN service CA certificates. However, manual CA registration can still introduce incorrectly classified trust material because the role is asserted by the operator rather than derived from the certificate.

This is acceptable for the current demo workflow, but it must not be treated as production-grade trust-anchor validation.

### Desired Direction

Decode the certificate and validate its X.509 extensions before accepting the CA role.

At minimum:

- require `basicConstraints` with `CA = TRUE`;
- reject certificates with `CA = FALSE` or without an acceptable CA constraint under the selected policy;
- validate `keyUsage` when present, including `keyCertSign`;
- preserve a clear distinction between PEM syntax validation and CA-role validation;
- return an actionable UI error without creating an orphan metadata object or material entry.

If policy-specific exceptions are ever supported, they must be explicit and auditable rather than inferred from names or subjects.

### Priority

High before production use

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
