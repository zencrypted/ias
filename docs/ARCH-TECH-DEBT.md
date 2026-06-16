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
