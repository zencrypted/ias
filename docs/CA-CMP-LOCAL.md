Local CA/CMP Test Harness
=========================

Purpose
-------

This document records the local CA/CMP setup used before integrating IAS with
certificate issuance.

The CA service is a separate runtime. IAS should not start the CA inside the
IAS VM. IAS will later call the CA through CMP.

Confirmed Local Stack
---------------------

The local CA/CMP flow was verified with:

* Erlang/OTP 28.0.2
* Elixir 1.18.4 compiled for OTP 28
* OpenSSL 3.5.0 for the `openssl cmp` client
* `synrc/ca` running `CA.CMP` on TCP port `8829`

OTP 25 is not sufficient for this CA/CMP path. With OTP 25, CMP protection was
validated, but certificate issuance crashed during CSR validation:

```text
X509.CSR.valid?/1
public_key.der_encode/2
uTF8String: "simple"
```

The same CMP request succeeds under OTP 28.

CA Runtime
----------

Start the CA in a separate terminal:

```sh
./tools/ca/run-ca-otp28.sh
```

The script expects:

* OTP 28 installed by kerl at `$HOME/28.0.2` by default.
* `asdf` available at `$HOME/.asdf/asdf.sh` when Elixir is managed by asdf.
* Elixir `1.18.4-otp-28` installed by asdf. The script selects it through `ASDF_ELIXIR_VERSION` and does not modify `.tool-versions`.
* the CA repository checked out at `$HOME/ca` by default.

The script accepts overrides:

```sh
OTP28_HOME=/path/to/otp28 \
CA_HOME=/path/to/ca \
ELIXIR_VERSION=1.18.4-otp-28 \
./tools/ca/run-ca-otp28.sh
```

Expected CA startup includes:

```text
Running CA.CMP ... at 0.0.0.0:8829 (tcp)
Running CA.CMC ... at 0.0.0.0:5318 (tcp)
Running CA.EST ... at 0.0.0.0:8047 (http)
```

CMP P10CR Test
--------------

In another terminal, issue a new test certificate:

```sh
./tools/ca/cmp-p10cr-test.sh
```

or with an explicit common name:

```sh
./tools/ca/cmp-p10cr-test.sh vpn-client-001
```

The script expects:

* local OpenSSL 3 at `$HOME/opt/openssl-3/bin/openssl` by default;
* CA OpenSSL fixtures under `$HOME/ca/openssl` by default;
* the CA server already running on `127.0.0.1:8829`.

It accepts overrides:

```sh
OPENSSL3=/path/to/openssl3 \
CA_OPENSSL_DIR=/path/to/ca/openssl \
./tools/ca/cmp-p10cr-test.sh vpn-client-001
```

The script generates a fresh key and CSR for each run, then performs CMP `p10cr`:

```text
key + CSR
-> CMP p10cr
-> issued certificate
```

A successful run prints:

```text
CMP info: received CP
CMP info: sending CERTCONF
CMP info: received PKICONF
received 1 newly enrolled certificate(s)
```

and shows certificate metadata, for example:

```text
subject=CN=simple-20260614-010642
issuer=C=UA, L=Київ, O=SYNRC, CN=CA
```

Important Notes
---------------

A new key and CSR should be generated for each enrollment test.

Reusing the same CSR can result in OpenSSL CMP reporting:

```text
CMP error: certresponse not found:expected certReqId = -1
```

The test script avoids this by generating a timestamped common name by default.

OpenSSL 1.1.1 is not enough for this test because it does not provide the
`openssl cmp` command. Keep OpenSSL 3 separate from the system OpenSSL and use
`OPENSSL3` or the test script instead of replacing `/usr/bin/openssl`.

Future IAS Integration
----------------------

The next IAS integration stage should treat CA as an external service:

```text
IAS Certificate Request
-> CSR
-> CMP p10cr
-> Issued Certificate Preview
```

The current scripts are development harnesses only. They are not production
provisioning tools and do not define the final IAS/CA integration API.


IAS Runtime Compatibility
-------------------------

IAS does not require OTP 28.

The OTP 28 requirement was observed specifically in the CA/CMP issuance path:

CA -> X509.CSR.valid?/1 -> public_key.der_encode/2

Recommended deployment:

IAS (OTP 25) -> CMP -> CA (OTP 28)
