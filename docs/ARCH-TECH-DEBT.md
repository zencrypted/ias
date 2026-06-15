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
