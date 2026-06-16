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

## TD-006: Device Readiness Action Hints Are Not Directly Actionable

**Status:** Open

**Area:** Device Operational Readiness / IAS UI

### Problem

Device Operational Readiness correctly reports when a device is incomplete and now identifies missing requirements such as:

- VPN Service;
- Security Policy;
- Current Certificate;
- Certificate Verification;
- Certificate Security Policy.

However, some suggested actions are not obvious from the device page.

For example, the device page may show:

```text
Suggested Actions:
- Link Certificate Security Policy
```

The required action is not actually a direct device relationship. It must be performed on the current certificate:

```text
Current Certificate -> uses_security_policy -> Security Policy
```

This is correct architecturally, but the UI makes the operator infer that they need to open the current certificate and link its policy there.

### Current Impact

Medium.

The readiness calculation is correct, but the operator can mistake a missing certificate policy for a missing device policy. This is especially confusing because the same device page can already show:

```text
Device -> Security Policy: linked
```

while readiness still remains incomplete until:

```text
Current Certificate -> Security Policy
```

is linked.

### Desired Direction

Make suggested readiness actions explain where the action must be performed.

Possible improvements:

- render `Link Certificate Security Policy` as:

```text
Open current certificate and link its security policy
```

- add a direct link to the current certificate next to the hint;
- optionally show a small inline explanation:

```text
Device policy is linked, but current certificate policy is missing.
```

- eventually add a safe convenience action from the device page that links the current certificate to the selected policy, but only after the semantics are stable.

The first iteration should be explanatory only. Do not add automatic actions yet.

### Priority

Medium
