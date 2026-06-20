# IAS Runtime Modes

IAS deliberately has two operating modes:

1. **Static Preview Mode** served from `priv/static/*.htm`.
2. **Live Runtime Mode** served by the Erlang/N2O/Nitro application.

These modes must stay separate. Static Preview Mode is a distributable demo and
review surface. Live Runtime Mode is the authoritative service surface for
server-side eventing, integrations, validation, policy decisions and future CA,
LDAP and NS workflows.

## Why This Exists

Static HTML previews are useful for IAS because the product flow can be reviewed
without starting an Erlang node, a WebSocket session, VPN, CA or LDAP. This makes
IAS easy to publish through GitHub Pages, inspect during code review and show as
a serverless prototype.

Live Runtime Mode is still required because the real product depends on behavior
that static HTML cannot provide: server-side events, runtime service calls,
validation, authorization, VPN integration and future CA/LDAP/NS workflows.

The static mode is therefore a **preview artifact**. The live mode is the
**runtime system**.

## Static Preview Mode

Static Preview Mode is the standalone HTML prototype under `priv/static/*.htm`.
It must be safe to open directly as HTML and to publish through GitHub Pages.

Static Preview Mode should support:

- GitHub Pages publication.
- Navigation between IAS prototype pages without an Erlang server.
- Visual review of Users, Devices, Services, Certificates, Security Profiles,
  Relationships, VPN, Issue Certificate and Verify Certificate screens.
- Fixed demo data for IAS flows.
- Non-authoritative static previews of:
  - certificate claims;
  - certificate request validation;
  - CA signing preview;
  - certificate preview;
  - policy evaluation;
  - certificate verification.

Static Preview Mode must not be treated as authoritative runtime behavior. It
does not own backend state, perform live validation, read the VPN admin API,
issue certificates, verify keys, enforce policies or communicate with future CA,
LDAP or NS services.

## Live Runtime Mode

Live Runtime Mode is the Erlang + N2O/Nitro application runtime. The current live
page implementations are Erlang modules under `src/pages`, exposed through the
IAS application routes such as `/app/*.htm` when served by N2O.

Live Runtime Mode is responsible for:

- N2O server-side eventing and WebSocket updates.
- Nitro rendering.
- Runtime navigation and page state.
- Runtime VPN integration through the VPN admin API.
- Live VPN status and peer metadata.
- Authoritative request validation and policy evaluation.
- Future CA integration.
- Future LDAP-backed identity/profile lookup.
- Future NS/discovery integration.
- Future certificate issuance workflows.
- Live OVPN paste/file parsing and IAS mapping preview.
- Explicit storage of sanitized OVPN demo metadata in volatile ETS state.
- Explicit creation of sanitized OVPN provisioning transaction metadata in volatile ETS state.
- Future controlled production OVPN import and VPN activation.

All live-rendered text must follow `docs/NITRO-RENDERING.md`. In particular:

- atoms must be converted before rendering;
- mixed text values must be collapsed to binaries before being passed to Nitro
  element bodies;
- lists in Nitro bodies must only be used intentionally for child elements;
- multiline HTML sent through JavaScript updates must be escaped with
  `nitro:js_escape/1`;
- `#replace{}` and other render paths must keep binary/string/iolist handling
  explicit.

## Current IAS Architecture Slice

The forward IAS flow is:

```text
User
-> Security Profile
-> Certificate Claims
-> Certificate Request
-> Request Validation
-> CA Signing Preview
-> Certificate Preview
-> Policy Evaluation
```

The reverse IAS flow is:

```text
Certificate
-> Claims
-> Authorization
```

Both flows may be represented in Static Preview Mode, but runtime validation,
eventing, integration and authorization semantics belong to Live Runtime Mode.

## Static vs Live Responsibilities

| Responsibility | Static Preview | Live Runtime |
| --- | --- | --- |
| Open without Erlang server | yes | no |
| GitHub Pages demo | yes | no |
| Fixed demo navigation | yes | yes |
| Runtime N2O events | no | yes |
| VPN admin API calls | no | yes |
| Live VPN peer status | no | yes |
| Request validation semantics | preview only | authoritative |
| Policy evaluation semantics | preview only | authoritative |
| Certificate issuance | no | future |
| LDAP identity/profile lookup | no | future |
| NS/discovery integration | no | future |
| OVPN paste/file parse and mapping preview | no | yes |
| OVPN sanitized demo ETS store | no | yes, demo only |
| OVPN provisioning transaction metadata | no | yes, demo only |
| User-deliverable OVPN profile | no | future |
| Production OVPN import and VPN activation | no | future |

Features that depend on backend state, external services or untrusted input must
be implemented in Live Runtime Mode first. Static Preview Mode may mirror their
shape only as fixed, non-authoritative demo HTML.

## GitHub Pages Demo

The GitHub Pages demo should publish Static Preview Mode from `priv/static`.
This is intentional. It is not a runtime bug if static `.htm` files can be opened
and navigated without the Erlang VM.

GitHub Pages content must not imply that the static preview is performing live
validation, issuing certificates, reading VPN state, importing configurations or
enforcing policy.

## Runtime Workflows and Future Work

### OVPN Preview and Demo Store

OVPN handling is a **Live Runtime Mode** workflow. It must not be implemented
as authoritative static-only behavior.

The current read-only flow is:

```text
.ovpn upload/paste
-> parse
-> extract CA/cert/key presence, remote, protocol and routes
-> config preview
-> map to IAS Device preview
-> map to IAS Certificate preview
-> map to VPN Service preview
-> import plan preview
```

The current explicit demo flow is:

```text
import plan preview
-> sanitize extracted metadata
-> store demo Device, Certificate metadata and VPN Service objects
-> volatile ETS runtime state
```

The `.ovpn` input is untrusted runtime data. The parser extracts only the data
needed for preview and demo mapping:

- remote endpoint and port;
- protocol intent;
- route intent;
- CA material presence;
- client certificate presence;
- private key presence, without retaining secret material;
- TLS-auth presence;
- selected compatibility properties such as cipher and compression.

The mapping is:

- **IAS Device**: the VPN client endpoint or peer represented by the config.
- **IAS Certificate**: sanitized certificate and key-presence metadata.
- **VPN Service**: OpenVPN service, remote endpoint and route intent represented
  by the config.

Preview and import-plan actions do not change state. The explicit
`Store Demo Objects` action writes sanitized metadata to node-local, volatile ETS
demo state only. It does not persist the original `.ovpn` document, CA body,
certificate body, private-key body or TLS-auth body; `private_key_stored` remains
`false`. It also does not install a configuration, start a tunnel or call CA, LDAP
or external VPN services.

OVPN files usually do not directly contain IAS policy claims. Claims should be
resolved by IAS through Security Profiles, certificate metadata and policy rules.

A future production import requires explicit validation, authorization, audit,
rollback, persistent storage and secret-handling semantics. Static Preview Mode
may mirror only a fixed, non-authoritative representation of this workflow.

### JSON Compatibility

IAS currently uses `jiffy` because OTP 25 is still supported. If JSON handling
needs to change for newer OTP versions, add a small compatibility layer such as
`ias_json` and route JSON encode/decode calls through it. Do not scatter direct
JSON library calls across page modules.

### Runtime Composition

IAS should communicate with VPN through runtime APIs/events rather than requiring
VPN as a hard Erlang dependency. A future development launcher or deployment
profile may start IAS, VPN, CA, LDAP and NS together, but service coupling should
remain explicit.


### OVPN Export and Provisioning Transactions

OVPN Export is the primary future user-delivery workflow for IAS-managed VPN
access. Stage 23A introduces an explicit provisioning transaction boundary in
Live Runtime Mode without pretending that the current skeleton is a usable VPN
profile.

The current transaction flow is:

```text
Certificate or Device
-> OVPN provisioning authorization
-> choose portable or device-bound mode
-> create volatile provisioning transaction
-> await real CA/client certificate/private-key material
```

A Stage 23A transaction records only sanitized metadata:

- provisioning id;
- subject kind and id;
- certificate, device, VPN service and CA certificate references;
- portable or device-bound delivery mode;
- authorization result and reason;
- transaction expiry;
- material, artifact and delivery status;
- private-key ownership policy;
- `downloaded = false` for the future one-time delivery lifecycle.

The transaction status is `awaiting_material` after authorization. Its artifact
status remains `skeleton_only` and delivery status remains `not_ready`. No CA
body, client certificate body or private key is generated or stored by this
stage. Transactions are node-local volatile ETS demo objects and may be included
in Demo State export/import as sanitized metadata.

Portable mode declares a future `one_time_in_memory` private-key policy. This
means a later stage may generate a complete profile within a short-lived
provisioning operation and discard the key after one-time delivery. It does not
mean that Stage 23A currently generates a key. Portable mode is valid only when
the resolved security profile does not require device lock.

Device-bound mode keeps the `device_owned` policy and continues to require local
key generation on the approved device. When device lock is enabled, portable
provisioning is denied even if the certificate already has a valid Device
relationship; the operator must create device-bound provisioning from that
approved Device object.

The existing downloadable file is deliberately labelled **OVPN Skeleton**. It
is an operator preview only and must not be delivered to a user as a working VPN
configuration. A future stage must supply real CA and client certificate material
and implement the chosen private-key delivery boundary before changing the
transaction to a user-deliverable state.
