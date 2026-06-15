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

