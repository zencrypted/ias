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

### VPN Service -> CA Certificate

```text
VPN Service
 └─ uses_ca_certificate
      └─ Certificate
```

The CA certificate relationship records the trust anchor used by OVPN export
provisioning. It is editable demo metadata and does not imply private key or
certificate body export.

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

## Certificate Classes

IAS distinguishes three certificate classes in the runtime object graph. The
class is derived from the certificate source and is displayed on certificate
object pages so operators can tell which lifecycle rules apply.

### Imported OVPN Certificate

```text
OVPN Profile
      ↓
OVPN Import
      ↓
Imported OVPN Certificate
```

An imported OVPN certificate is a migration, onboarding, or endpoint discovery
artifact. It helps IAS understand an existing OpenVPN profile, but it is not the
primary IAS-managed identity certificate.

### Enrollment Certificate

```text
CA/CMP Enrollment
      ↓
Enrollment Certificate
```

An enrollment certificate is the artifact returned by the CA/CMP enrollment
flow. It proves that CA signing succeeded, but it does not yet carry IAS user,
role, service, or security-profile context. Role authorization and operation
enforcement are not applicable until the certificate is issued to a user or
security profile.

### Issued Identity Certificate

```text
Enrollment Certificate
      ↓
Issue To User / Security Profile
      ↓
Issued Identity Certificate
```

An issued identity certificate is the IAM-facing certificate used by IAS for
role authorization, operation enforcement, certificate replacement, revocation,
OVPN provisioning, and service access decisions. It may be linked to a device,
VPN service, security policy, verification records, and lifecycle records.

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

### Effective Trust Flow

```text
Certificate
      ↓
Effective Trust Status
      ↓
Trusted / Degraded / Blocked / Unknown
```

```text
Device
      ↓
Effective Authorization Status
      ↓
Ready / Degraded / Blocked / Incomplete
```

---

## Target Architecture

The following relationships are expected to appear as the PKI lifecycle evolves.

### Authorization Decision Engine

```text
Security Profile
      ↓
Certificate Claims
      ↓
Certificate
      ↓
Verification
      ↓
Effective Trust
      ↓
Authorization Decision
```

Status: preview implemented

The authorization decision engine is the final IAS trust layer. It answers
whether a subject is allowed to perform an action on a resource after identity,
certificate, verification, revocation, replacement, operational readiness, and
policy state have already been resolved.

Stage 18A implements this as a read-only Status-Based Authorization preview.
IAS computes authorization decisions from Effective Trust Status and Device
Operational Readiness, but does not create authorization decision records,
mutate runtime state, call CA/CMP, call LDAP, or enforce VPN access.

Stage 18B adds Profile-Based Authorization preview. IAS resolves the certificate
Security Profile and applies a minimal role/action matrix:

- `administrator` may use IAS, issue certificates, and revoke certificates.
- `default_user` may access VPN and use IAS, but may not issue or revoke
  certificates.
- certificates without a resolved profile are denied.

This is intentionally not an ABAC engine, policy language, or rule editor. It is
the first read-only role layer on top of the existing status-based decision
preview.

Stage 19A adds Authorization Enforcement Preview. IAS maps authorization
decisions to the operations that would be allowed or denied:

- Device `access_vpn` maps to VPN Connection.
- Certificate `use_ias` maps to IAS Access.
- Certificate `issue_certificate` maps to Certificate Issuance.
- Certificate `revoke_certificate` maps to Certificate Revocation.

This remains preview-only. IAS does not execute VPN connections, issue
certificates, revoke certificates, block UI actions, write runtime objects, or
persist enforcement decisions.

Subjects:

- User
- Device
- Certificate

Actions:

- access_vpn
- use_ias
- issue_certificate
- revoke_certificate
- enroll_certificate

Resources:

- VPN Service
- IAS
- Certificate Authority
- Certificate

Expected decision values:

- allow
- deny

Reason examples:

- certificate revoked
- effective trust blocked
- device not ready
- policy mismatch
- missing required claim
- insufficient role

The authorization decision may be modeled as an explicit runtime decision record
once IAS moves from graph inspection to policy enforcement. In the current
preview implementation, Effective Trust Status and Device Operational Readiness
provide the inputs for this final decision layer.

### Guided Lifecycle Workflows

```text
Graph State
      ↓
Graph Analysis
      ↓
Suggested Actions
      ↓
Guided Workflow Step
      ↓
Operational Readiness / Effective Trust / Authorization Decision
```

Status: planned

Guided Lifecycle Workflows are the future operator-facing UI layer on top of
the IAS object graph. The existing Relationship Explorer remains the expert
mode for inspecting objects, relationships, lifecycle records, and graph
diagnostics. Wizard-style workflows should not replace the graph model; they
should consume graph analysis and suggested actions to guide users through the
correct sequence of steps.

The intended UI split is:

- Graph Mode: inspect and debug the complete object graph;
- Wizard Mode: perform guided lifecycle operations for common operator tasks.

Initial guided workflows should include:

#### Setup VPN Client

```text
Import OVPN
      ↓
Select / Create Device
      ↓
Issue or Select Certificate
      ↓
Assign Security Policy
      ↓
Assign VPN Service
      ↓
Verify Certificate
      ↓
Operational Readiness Check
      ↓
Ready / Incomplete
```

#### Replace Certificate

```text
Current Certificate
      ↓
Candidate Certificate
      ↓
Verify Candidate
      ↓
Replace Certificate
      ↓
Operational Readiness Check
```

#### Revoke Certificate

```text
Select Certificate
      ↓
Show Affected Devices
      ↓
Confirm Revocation
      ↓
Create Revocation Record
      ↓
Impact / Readiness Analysis
```

Wizard steps should be derived from existing runtime analysis rather than from
a separate hard-coded business process. The main inputs are:

- Graph Analysis;
- Suggested Actions;
- Device Operational Readiness;
- Effective Trust Status;
- Effective Authorization Status;
- future Authorization Decision records.

This keeps guided workflows as a UX layer over the same source-of-truth graph
used by Relationship Explorer.

### Scoped Graph Views and Role-Based Filtering

```text
Complete Object Graph
      ↓
Scope Selection
      ↓
Filtered Relationship Graph
      ↓
Role-Specific Actions
```

Status: planned

The current Relationship Explorer is intentionally a global expert/debug view.
It is useful while the IAS object model is being designed, but it should not be
the only operational view once real users, devices, certificates, services,
verification records, replacements, revocations, and authorization decisions
accumulate in the runtime graph.

IAS should introduce scoped graph views that show only the relevant subgraph for
the current task or actor. Operators should not have to inspect every user, every
certificate, and every lifecycle record to manage a single device or VPN service.

Initial graph scopes should include:

- all graph;
- by user;
- by device;
- by certificate;
- by VPN service;
- by security profile;
- by security policy;
- by effective status: ready, incomplete, degraded, blocked;
- by certificate lifecycle state: verified, replaced, revoked, expired.

The same scope model should also be reused by guided workflows. A wizard step
should operate on a focused subgraph instead of forcing the operator to navigate
the full Relationship Explorer tree.

Role-based filtering should later restrict both visibility and actions. The
expected roles are:

- Security Officer: full graph and policy lifecycle access;
- PKI Administrator: certificate issuance, replacement, revocation, and CA
  lifecycle access;
- VPN Administrator: VPN services, devices, and VPN-related certificates;
- Auditor: read-only graph, lifecycle records, and effective decisions;
- End User: only own devices, own certificates, and own access status.

This separation keeps IAS Admin Console usable for security operators while
allowing a future User Portal to expose a much smaller personal view.

Scoped graph views must not create a second source of truth. They are filters and
projections over the same relationship graph used by Graph Mode, Wizard Mode,
Operational Readiness, Effective Trust, and future Authorization Decision
records.

### Certificate Replacement

```text
Certificate
        ↓
      replaces
        ↓
Certificate
```

Status: implemented through `certificate_replacement` runtime objects.

---

## Validation Rule

Every relationship shown in:

- Device pages
- Certificate pages
- Security Profile pages
- Relationship Explorer

must be explainable through this graph.

This document serves as the architectural source of truth for IAS relationship modeling.

### VPN Certificate Provisioning

```text
Certificate Lifecycle
      ↓
Effective Trust
      ↓
Authorization Decision
      ↓
VPN Peer Provisioning
      ↓
VPN Runtime Configuration
```

Status: planned

VPN certificate provisioning is the bridge between the IAS administration
console and the VPN runtime service. IAS remains the issuer, inventory,
policy, trust, and authorization layer. The VPN service consumes only the
runtime decision and the peer configuration needed to run the tunnel.

The VPN service should not understand the full IAS object graph. It should ask
IAS whether a peer is allowed and request the effective runtime configuration
for that peer.

Expected IAS outputs for VPN runtime:

- peer id
- remote peer id
- certificate reference or certificate metadata
- CA certificate reference
- key reference or key path when available locally
- VPN service endpoint and transport configuration
- authorization decision
- denial reason when access is blocked

### OVPN Provisioning Artifact

OVPN is not only an import format. In the VPN provisioning model, OVPN is also
the user-facing export artifact produced after IAS has resolved the security
profile, certificate lifecycle, trust status, and authorization decision.

```text
User
      ↓
Security Profile
      ↓
Certificate
      ↓
Authorization Decision
      ↓
OVPN Export
      ↓
User
```

For the standard VPN profile, IAS may issue an OVPN profile to a user and let
the user choose the device where it will be installed. For elevated security
profiles, IAS may require device lock: the certificate is bound to a specific
device before the OVPN profile is issued. Optional 2FA belongs to the same
profile-controlled VPN access layer.

OVPN provisioning authorization is separate from VPN connection enforcement.
Connection enforcement answers whether an already configured device may connect
to VPN. OVPN provisioning answers whether IAS may issue an OVPN profile for a
certificate or user. Standard profiles may allow OVPN provisioning without a
current device binding; high-security profiles may require device binding before
provisioning.

This separates two workflows:

- OVPN Import: legacy profile analysis, migration, onboarding, or demo.
- OVPN Export: primary VPN provisioning workflow for IAS-managed users.

Private key ownership rule:

```text
Device / Peer
      ↓
Generate private key locally
      ↓
Generate CSR
      ↓
IAS / CA signs CSR
      ↓
IAS stores certificate metadata
      ↓
VPN runtime receives authorized peer config
```

IAS should not become the production private-key store. In the preferred model,
private keys are generated and kept on the device or peer side. IAS/CA signs a
CSR and stores certificate metadata, lifecycle state, trust state, and policy
state. Development-mode demos may use local files under `priv/certs`, but that
is not the production provisioning model.

The VPN runtime boundary is therefore:

```text
IAS owns:
- enrollment
- issuance metadata
- verification
- replacement
- revocation
- effective trust
- authorization decision
- peer provisioning plan

VPN owns:
- tunnel startup
- packet transport
- runtime peer process
- runtime counters
- dataplane enforcement using the provisioned identity
```

This keeps the dataplane small and prevents the VPN service from duplicating
IAS policy logic.
