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

### Device -> VPN Service

```text
Device
 └─ uses_vpn_service
      └─ VPN Service
```

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
```

### Certificate Issuance Flow

```text
User
      ↓
Security Profile
      ↓
Issued Certificate
```

---

## Target Architecture

The following relationships are expected to appear as the PKI lifecycle evolves.

### Enrollment -> Issued Certificate

```text
Certificate Enrollment
        ↓
        issues
        ↓
Issued Certificate
```

Status: planned

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
