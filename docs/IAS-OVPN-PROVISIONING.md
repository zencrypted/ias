OVPN Provisioning Material Contract
===================================

Purpose
-------

OVPN provisioning is the forward IAS workflow that will eventually assemble a
user- or device-deliverable OpenVPN profile from IAS-managed objects. It is
separate from OVPN Import, which analyzes an existing configuration and maps it
into demo IAS metadata.

Current Flow
------------

Certificate or Device
-> Provisioning Authorization
-> Portable or Device-bound Transaction
-> Material Requirements
-> Material Sources
-> Component Status
-> Assembly Readiness

Material Contract
-----------------

Every Stage 23B transaction records the following sanitized metadata:

| Material | Requirement | Expected source | Current Stage 23B status |
| --- | --- | --- | --- |
| CA certificate PEM | required | CA certificate store | `missing_body` when referenced |
| Client certificate PEM | required | certificate store | `missing_body` when referenced |
| Private key, portable | required later | provisioning transaction | `pending_one_time_generation` |
| Private key, device-bound | device-owned | approved device | `available_on_device` |
| TLS-auth | optional | VPN service | `not_configured` |

Assembly Readiness
------------------

An authorized transaction remains:

```text
status = awaiting_material
material_status = pending_real_material
assembly_status = blocked
artifact_status = skeleton_only
delivery_status = not_ready
```

The assembly reason lists the missing public certificate material and, for
portable mode, the pending one-time private-key generation step. The next step
points the operator toward a future CA/CMP response or certificate material
store.

Security Boundary
-----------------

Stage 23B does not:

* generate a private key;
* call CA/CMP;
* store CA or client certificate PEM bodies;
* store CSR, TLS-auth, TLS-crypt or shared-secret material;
* assemble a complete OVPN profile;
* mark a transaction as deliverable.

The Demo State export/import boundary continues to contain sanitized metadata
only.

Future Direction
----------------

The next implementation stages should provide public certificate material first,
then implement device-bound assembly, and only afterwards introduce portable
one-time private-key generation and one-time delivery.
