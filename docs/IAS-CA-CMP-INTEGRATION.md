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

The current implementation is a development-mode enrollment workflow. IAS
prepares a CMP `p10cr` request, calls the external CA through OpenSSL 3, extracts
issued certificate metadata, and can import that metadata as an IAS demo
certificate object.

## Runtime Model

IAS and CA stay separate:

```text
IAS (OTP 25)
-> External CA (OTP 28)
```

IAS does not embed the CA, start the CA, or depend on the CA OTP release. The CA
runs as a separate OTP 28 service. IAS remains on OTP 25 and acts only as a CMP
client.

The development enrollment client uses local OpenSSL 3 to perform the CMP
request. The CA endpoint is currently `127.0.0.1:8829`, and the CMP command is
`p10cr`.

## Enrollment Flow

1. User enters Common Name.
2. IAS generates a unique Enrollment CN.
3. IAS generates a temporary key.
4. IAS generates a temporary CSR.
5. IAS performs CMP `p10cr` enrollment.
6. CA issues an X.509 certificate.
7. IAS extracts certificate metadata.
8. IAS stores the enrollment result in ETS.
9. User imports certificate metadata as a demo object.

The imported certificate demo object stores metadata only: subject, issuer,
validity dates, requested CN, enrollment CN, profile, CMP server, and flags
showing that no key or certificate body is stored.

## Security Notes

- PEM is not stored.
- CSR is not stored.
- Private key is not stored.
- Shared secret is not stored.
- Demo objects contain metadata only.
- Enrollment result is loaded from ETS, not browser fields.
- Hidden form fields are not trusted.

The browser receives only an `enrollment_id` for the import action. On import,
IAS loads the enrollment metadata from server-side ETS state and builds the
certificate demo object from that server-side result.

## Limitations

- Development mode only.
- No renewal.
- No revocation.
- No LDAP integration.
- No VPN integration.
- No production key management.
- No CA startup management from IAS.
- No persistent certificate or key store.
