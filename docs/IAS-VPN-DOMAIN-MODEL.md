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

## Future Import Flow

OVPN
-> Extracted Config
-> IAS Device Preview
-> IAS Certificate Preview
-> VPN Service Preview
-> Import Plan Preview

Future controlled import may create Device, Certificate and VPN Service objects from the approved import plan.

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
