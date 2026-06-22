# IAS VPN Domain Model

## Purpose

Define the minimal IAS domain objects that may be created from a future OVPN import workflow.

The current OVPN Import Preview is read-only and does not persist data.

## Device

Represents a VPN client endpoint known to IAS.

Fields:

- id
- type (vpn-client)
- endpoint
- transport
- tunnel_device
- certificate_ref
- service_ref

## Certificate

Represents certificate material associated with a VPN device.

Fields:

- id
- subject
- ca_present
- client_certificate_present
- private_key_present
- tls_auth_present
- source (ovpn)

## VPN Service

Represents an OpenVPN service definition.

Fields:

- id
- type (openvpn)
- remote
- protocol
- cipher
- compression
- routes

## Relationships

Device -> Certificate

Device -> VPN Service

User/Profile -> Device

## OVPN Roles

OVPN profiles have two distinct roles in the IAS/VPN model.

### Import Path

Existing OpenVPN profiles may be imported for analysis, migration, onboarding,
or demo purposes.

```text
OVPN
-> Extracted Config
-> IAS Device Preview
-> IAS Certificate Preview
-> VPN Service Preview
-> Import Plan Preview
```

Future controlled import may create Device, Certificate and VPN Service
objects from the approved import plan.

### Export Path

The expected primary provisioning workflow is the reverse direction: IAS
issues or coordinates the certificate lifecycle, evaluates authorization, and
then produces an OVPN profile as the user-facing VPN provisioning artifact.

```text
User
-> Security Profile
-> Certificate
-> Authorization Decision
-> OVPN Export
-> User
```

Stage 20A implements OVPN Export as a read-only preview. The preview shows the
profile skeleton IAS would provision from the resolved certificate, VPN service,
security profile, and authorization state. The skeleton does not embed real CA,
client certificate or private-key bodies and is not a user-deliverable VPN
profile.

Stage 20B separates OVPN provisioning authorization from VPN connection
enforcement. These are related but different decisions:

```text
Can this device connect to VPN?
```

is not the same as:

```text
Can IAS provision an OVPN profile for this certificate or user?
```

The export path therefore evaluates an OVPN provisioning decision instead of
reusing the device VPN connection enforcement result directly.


### Stage 23A Provisioning Transaction

Stage 23A adds a volatile provisioning transaction between authorization and
future material assembly:

```text
OVPN Provisioning Decision
-> Provisioning Transaction
-> Awaiting Real Material
-> Future One-time User Delivery
```

Two transaction modes are represented:

- `portable`: future one-time in-memory key/profile assembly for delivery to a
  user-selected device. It is valid only for profiles where device lock is not
  required;
- `device_bound`: device-owned key material and delivery to an approved bound
  device. It is mandatory when the security profile enables device lock.

The delivery mode is part of authorization, not merely an operator preference.
A device-bound certificate may be authorized for VPN provisioning while still
being denied specifically for `portable` provisioning. In that case the
operator must create the transaction from the approved Device object.

The transaction stores references and lifecycle metadata only. While required
material or lineage is unresolved, an authorized transaction remains
`awaiting_material` with a blocked artifact. For a valid device-bound flow, IAS
derives `ready_for_delivery`, `public_bundle_ready` and
`ready_for_device_import` and assembles the public OVPN body on demand. The
future `downloaded` flag still lacks authoritative delivery-audit semantics.

The transaction never stores private-key, client certificate or CA bodies.
Public certificate PEM lives in the separate volatile material store. The device
detail **Download OVPN Skeleton** action remains a non-secret technical preview,
while the completed Provisioning Wizard transaction can generate the real
device-bound public bundle with a relative `key` reference. Portable one-time
secret delivery is still future work.

### Manual VPN Service Provisioning Metadata

Stage 21A allows an administrator to create a managed VPN Service directly,
without importing an existing `.ovpn` file. Stage 21B adds the first
provisioning metadata links for that service:

```text
VPN Service
-> Security Policy
-> CA Certificate
```

The CA Certificate relationship represents the trust anchor used for the `<ca>`
section of an exported OVPN profile. The relationship itself remains metadata,
while the public PEM body is resolved from the separate volatile material store
at assembly time. IAS does not export private keys; device-bound bundles embed
only public CA/client certificate material and reference the Device-owned key.

OVPN Import and OVPN Export have different roles:

- OVPN Import is a migration, onboarding, and legacy profile analysis workflow.
- OVPN Export is the primary provisioning artifact for IAS-managed VPN access.

Device-owned keys remain outside the exported profile. A device-bound bundle
uses `key <safe-relative-reference>` and never emits an inline `<key>` block or
private-key body.

In the standard VPN profile, the user receives an OVPN profile and chooses the
client device where it will be installed. Device binding is not mandatory in
that profile.

In the high-security VPN profile, device binding is mandatory and portable
provisioning is denied. The operator creates a `device_bound` transaction from
the approved Device object, keeping private-key ownership on that device. This
allows standard VPN users to receive a portable OVPN profile while elevated
security profiles keep certificate use locked to a specific device.

```text
User
-> Certificate
-> OVPN Profile
-> User-selected Device
```

For elevated security profiles, IAS may issue or approve a certificate only
for a specific device. In that case the OVPN profile is still the delivery
artifact, but the certificate is constrained by device binding.

```text
User
-> Certificate
-> Device Binding
-> OVPN Profile
-> Bound Device
```

Two-factor authentication is also part of the VPN domain model. It may be
optional in early deployments and required by elevated profiles later.

## Planned VPN Certificate Provisioning Model

The future VPN integration should treat IAS as the administration, issuer,
trust, and authorization service for VPN peers.

IAS should provide a provisioning result for a peer instead of exposing the
full object graph to the VPN runtime.

Implemented device-bound provisioning flow:

```text
Device / VPN Peer
-> Generate private key locally
-> Generate CSR
-> IAS submits CSR to CA / CMP
-> CA issues certificate
-> IAS imports certificate metadata
-> IAS evaluates effective trust and authorization
-> VPN service receives allowed peer configuration
```

The preferred production model is CSR-based. Private keys stay on the peer or
device side. The Provisioning Wizard now prepares a fresh key/CSR plan, accepts
only the Device-generated CSR, validates the CMP-issued certificate against the
CSR and configured CA, records lineage and updates the Device's safe relative
key reference. IAS stores certificate metadata, public certificate material in a
separate volatile store and lifecycle state, not private-key material.

Development-only flows may use local certificate and key files such as
`priv/certs/peer_a.crt` and `priv/certs/peer_a.key`, but those paths represent
local test fixtures, not the target production key-management model.

The VPN service should consume:

- peer id
- remote peer id
- VPN endpoint settings
- CA certificate reference
- peer certificate reference or metadata
- local key reference when available to the runtime host
- effective authorization decision

The VPN service should not reimplement IAS graph analysis. It should rely on
IAS for:

- certificate issuance state
- verification state
- replacement state
- revocation state
- security policy assignment
- effective trust status
- authorization decision
