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
security profile, and authorization state. It does not write `.ovpn` files,
download profiles, embed certificate bodies, embed private keys, or mutate
runtime state.

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

OVPN Import and OVPN Export have different roles:

- OVPN Import is a migration, onboarding, and legacy profile analysis workflow.
- OVPN Export is the primary provisioning artifact for IAS-managed VPN access.

Device-owned keys remain outside the exported profile. IAS may display the
`<key>` section shape for operator review, but the private key body is not
exported by IAS.

In the standard VPN profile, the user receives an OVPN profile and chooses the
client device where it will be installed. Device binding is not mandatory in
that profile.

In the high-security VPN profile, device binding is mandatory. IAS may deny OVPN
provisioning until the certificate is bound to an approved device. This allows
standard VPN users to receive a portable OVPN profile while elevated security
profiles keep certificate use locked to a specific device.

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

Planned provisioning flow:

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
device side. IAS stores certificate metadata and lifecycle state, not private
key material.

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
