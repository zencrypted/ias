# IAS CA/CMP Integration

## Overview

IAS integrates with the CA through CMP as a client-only runtime flow:

```text
IAS
-> CMP
-> CA
-> Issued Certificate
-> IAS Certificate Object
```

The CA remains a separate service. IAS does not embed or start it. The live
runtime currently supports both a legacy development helper and a
production-aligned Device-owned CSR path.

## Runtime Model

```text
IAS (OTP 25-compatible)
-> OpenSSL 3 CMP client
-> external CA/CMP service
```

The default local CMP endpoint is `127.0.0.1:8829`, and the enrollment command is
CMP `p10cr`. Endpoint and OpenSSL paths are runtime configuration, not browser
parameters.

## Legacy Development Enrollment

The standalone Certificate Enrollment page can generate a temporary key and CSR
inside the IAS development environment so the CMP path can be exercised locally:

1. user enters a Common Name;
2. IAS generates a unique enrollment CN;
3. IAS generates a temporary key and CSR;
4. IAS performs CMP `p10cr`;
5. CA issues an X.509 certificate;
6. IAS extracts metadata and stages public certificate PEM;
7. the operator imports the result as a demo certificate object.

This is a development harness only. It does not define production private-key
ownership.

## Device-owned CSR Enrollment

The Provisioning Wizard implements the production-aligned path:

```text
Prepare stable key/CSR plan
-> download and run script on Device
-> generate keys/<unique>.key and <unique>.csr
-> upload CSR only
-> validate CSR signature and fingerprints
-> reject duplicate CSR or reused public key
-> submit CSR through CMP
-> validate issued certificate role, public key and configured CA chain
-> import public certificate material
-> persist certificate lineage metadata
-> update Device private-key reference
-> select certificate in wizard
```

The generated script creates `keys/` when needed, generates a fresh `secp384r1`
key for every enrollment, refuses to overwrite existing files, applies mode
`0600` and verifies the CSR. The private key never leaves the Device.

Successful enrollment records:

- Device id;
- CSR fingerprint;
- CSR public-key fingerprint;
- certificate public-key fingerprint;
- safe relative private-key reference;
- `issued_via = cmp`;
- `key_rotation = new_key_pair`.

The Device key reference is updated only after certificate validation succeeds.
The pending wizard rotation is then cleared and the issued certificate is
automatically selected.

## Verified Key Lineage

IAS verifies that the issued certificate public key matches the uploaded CSR
public key and that the certificate chains to the configured CA trust anchor. A
local end-to-end run additionally confirmed equality between:

```text
SHA-256(public key derived from Device private key)
==
SHA-256(public key extracted from CMP-issued certificate)
```

This validates key -> CSR -> certificate lineage while preserving the Device
private-key boundary. IAS still cannot prove that a local filename continues to
contain that key after enrollment; the Device owns that operational guarantee.

## Storage and Security Boundary

- Device private-key bodies are never uploaded, stored or rendered by IAS.
- Uploaded CSR bodies are used transiently for validation/enrollment and are not
  included in Demo State or certificate objects.
- CSR and public-key fingerprints may be retained as non-secret lineage metadata.
- Issued public certificate PEM is held in the volatile
  `ias_certificate_material` store and is excluded from Demo State metadata.
- Shared secrets, TLS-auth and TLS-crypt bodies are not stored by this flow.
- Browser import actions use server-side enrollment state rather than trusting
  hidden fields.
- External CMP/OpenSSL errors are normalized, while full operational diagnostics
  remain server-side.

## Device-bound OVPN Integration

After successful enrollment, the selected certificate lineage and Device key
reference are required by device-bound OVPN readiness. The generated profile
contains public `<ca>` and `<cert>` blocks and a relative directive such as:

```text
key keys/device-20260622-010203-1.key
```

It never contains an inline `<key>` block. The `.ovpn` file must be delivered
with the referenced `keys/` directory on the Device.

## Current Limitations

- No certificate renewal orchestration.
- No revocation workflow integration with the external CA.
- No persistent production certificate/material store.
- No LDAP identity/profile lookup.
- No actual VPN tunnel activation or connection enforcement from IAS.
- Enrollment completion is not yet fully transactional across certificate import,
  Device update, wizard selection and pending-state cleanup.
- Delivery/download/import audit semantics are not yet implemented.
