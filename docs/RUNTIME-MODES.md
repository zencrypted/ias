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
- Future configuration import workflows such as OVPN import.

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
| OVPN upload/parse/import | no | future |

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

## Future Runtime Work

### OVPN Import Preview

OVPN import is a future **Live Runtime Mode** workflow. It must not be
implemented as static-only behavior.

Planned flow:

```text
.ovpn upload/paste
-> parse
-> extract CA/cert/key/remote/routes
-> config preview
-> map to IAS Device
-> map to IAS Certificate
-> map to VPN Service
```

The implementation should treat `.ovpn` input as untrusted runtime data. The
parser should extract only the data needed for preview and later import:

- remote endpoint and port;
- protocol intent;
- route intent;
- CA material presence;
- client certificate identity and metadata;
- private key presence, without persisting secret material during preview.

The preview should map extracted data to IAS concepts:

- **IAS Device**: client endpoint or peer identity represented by the config.
- **IAS Certificate**: certificate identity and metadata derived from the config.
- **VPN Service**: OpenVPN service, remote endpoint and route intent represented
  by the config.

OVPN files usually do not directly contain IAS policy claims. Claims should be
resolved later by IAS through Security Profiles, certificate metadata and policy
rules.

The import workflow should remain a preview until validation, authorization and
secret-handling semantics are defined. Static Preview Mode may later show a fixed
demonstration of the flow, but authoritative parsing and mapping belong to Live
Runtime Mode.

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
