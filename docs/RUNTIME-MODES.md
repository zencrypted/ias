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
| Certificate issuance | no | yes, external CMP development/device CSR flows |
| LDAP identity/profile lookup | no | future |
| NS/discovery integration | no | future |
| OVPN paste/file parse and mapping preview | no | yes |
| OVPN sanitized demo ETS store | no | yes, demo only |
| OVPN provisioning transaction metadata | no | yes, demo only |
| User-deliverable OVPN profile | no | yes, device-bound public bundle |
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

OVPN Export is the live-runtime delivery workflow for IAS-managed VPN access.
The transaction boundary was introduced as metadata-only in Stage 23A and now
supports a real device-bound public bundle while portable key delivery remains
future work.

The current device-bound flow is:

```text
Device
-> Provisioning Wizard
-> authorization and relationship preflight
-> stable Device key/CSR plan
-> local Device key generation
-> CSR upload and external CMP enrollment
-> issued certificate/CSR/CA validation
-> certificate lineage and Device key-reference update
-> volatile provisioning transaction
-> on-demand device-bound OVPN assembly
```

Provisioning Wizard drafts are live-runtime orchestration metadata. Demo State
may preserve their scenario, current step, selected object identifiers, safe
pending filenames/key references and timestamps, but never certificate bodies,
private keys, CSR bodies, TLS secrets, temporary form values or process/session
identifiers. Import restores stale references deliberately so the wizard can
require a new selection.

A provisioning transaction records sanitized metadata:

- provisioning id;
- subject kind and id;
- certificate, device, VPN service and CA certificate references;
- portable or device-bound delivery mode;
- authorization result and reason;
- transaction expiry;
- derived material, artifact and delivery status;
- private-key ownership policy;
- `downloaded = false` until a future delivery-audit stage updates it.

Portable mode declares a future `one_time_in_memory` private-key policy and
remains blocked on one-time key generation and delivery. It is valid only when
the resolved security profile does not require device lock.

Device-bound mode uses the `device_owned` policy. The Device script generates a
fresh local key and CSR, creates the relative `keys/` directory, refuses to
overwrite existing files and uploads only the CSR. IAS validates the CSR, rejects
duplicate/reused public keys, submits it through CMP, validates the issued
certificate against the CSR and configured CA, and updates the Device key
reference only after success.

Stage 23B introduced the material assembly contract:

```text
material requirement
-> expected source
-> current component status
-> overall assembly readiness
```

The current required components are:

- CA certificate PEM from the volatile certificate-material store;
- client certificate PEM from the same public-material boundary;
- a validated Device-owned private-key reference;
- matching Device/CSR/certificate lineage;
- optional TLS-auth material from the VPN service configuration.

When any requirement is unresolved, the transaction remains blocked. When all
current authorization, graph, endpoint, public material, certificate-chain,
lineage and key-reference checks pass, the derived state becomes
`ready_for_delivery` / `public_bundle_ready` / `ready_for_device_import`. IAS
then assembles a real `.ovpn` body on demand with public `<ca>` and `<cert>` blocks
and a relative `key` directive. The private key is neither embedded nor stored.

Assembled OVPN bodies remain outside Demo State. The next lifecycle stage must
record generation/download/delivery/import audit metadata without persisting the
artifact body. Actual VPN activation remains outside IAS.

### Public Certificate Material Store

Stage 23C adds a Live Runtime-only store for public X.509 certificate PEM
material. Certificate bodies remain separate from IAS certificate metadata and
from Demo State snapshots. The store accepts only a single public certificate
PEM for an existing certificate object, rejects private-key material, records a
SHA-256 fingerprint, and updates OVPN assembly readiness without generating or
storing private keys.
