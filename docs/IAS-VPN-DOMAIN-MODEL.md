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
