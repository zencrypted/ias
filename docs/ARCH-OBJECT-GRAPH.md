# IAS Object Graph

## Purpose

This document defines the intended relationship graph between IAS domain objects.

The goal is to make UI validation and relationship validation deterministic.

If a relationship appears in the UI but is not present in this graph, it should be treated as a bug or an unfinished feature.

---

## Current Core Objects

- User
- Device
- Certificate
- Security Profile
- Security Policy
- VPN Service
- Certificate Enrollment
- Certificate Verification

---

## Implemented Relationships

### User -> Security Profile

```text
User
 └─ uses_security_profile
      └─ Security Profile
```

### User -> Certificate

```text
User
 └─ issued_certificate
      └─ Certificate
```

### Security Profile -> Certificate

```text
Security Profile
 └─ issued_certificate
      └─ Certificate
```

### Device -> Certificate

```text
Device
 └─ uses_certificate
      └─ Certificate
```

### Certificate -> Security Policy

```text
Certificate
 └─ uses_security_policy
      └─ Security Policy
```

### Certificate -> Verification

```text
Certificate
 └─ verified_by
      └─ Certificate Verification
```

Certificate verification records are runtime-only demo objects. They capture
verification metadata and authorization result metadata, but do not store
certificate bodies, private keys, or production audit state.

### Verification -> Security Policy

```text
Certificate Verification
 └─ uses_security_policy
      └─ Security Policy
```

### Device -> VPN Service

```text
Device
 └─ uses_vpn_service
      └─ VPN Service
```

### Certificate Enrollment -> Enrollment Certificate

```text
Certificate Enrollment
 └─ issues
      └─ Enrollment Certificate
```

### Enrollment Certificate -> Issued Certificate

```text
Enrollment Certificate
 └─ issues
      └─ Issued Certificate
```

The graph uses `issues` in the source-to-target lifecycle direction. This keeps
relationship direction consistent with the rest of IAS: the object that causes
or owns the relationship is the source, and the resulting object is the target.
The inverse name `issued_from` is a useful display label, but storing it as the
relationship type would make graph traversal inconsistent with existing
source-to-target edges.

The explicit linkage key for the second edge is `source_certificate_id` on the
issued certificate. IAS creates the edge only when issuance was requested from
a concrete enrollment certificate object.

---

## Runtime Flows

### OVPN Import Flow

```text
OVPN Import
      ↓
Device
      ↓
Imported Certificate
      ↓
VPN Service
```

### Certificate Enrollment Flow

```text
Certificate Enrollment
      ↓
Enrollment Certificate
      ↓
Issued Certificate
```

### Certificate Issuance Flow

```text
User
      ↓
Security Profile
      ↓
Issued Certificate
```

### Certificate Verification Flow

```text
Certificate
      ↓
Certificate Verification
      ↓
Authorization Decision Metadata
```

---

## Target Architecture

The following relationships are expected to appear as the PKI lifecycle evolves.

### Certificate Replacement

```text
Certificate
        ↓
      replaces
        ↓
Certificate
```

Status: planned

---

## Validation Rule

Every relationship shown in:

- Device pages
- Certificate pages
- Security Profile pages
- Relationship Explorer

must be explainable through this graph.

This document serves as the architectural source of truth for IAS relationship modeling.
