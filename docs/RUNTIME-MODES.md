# IAS Runtime Modes

IAS has two intentional operating modes:

1. Static Preview Mode, served from `priv/static/*.htm`.
2. Live Runtime Mode, rendered by Erlang, N2O and Nitro.

These modes must stay separate. Static preview is a distributable demo surface.
Live runtime is the authoritative service surface for events, integrations and
future certificate authority work.

## Static Preview Mode

Static Preview Mode is the standalone HTML prototype under `priv/static/*.htm`.
It does not require an Erlang node, WebSocket session, N2O event loop or runtime
backend services.

Static preview should work as:

- A GitHub Pages demo.
- A visual and navigation prototype for the IAS flows.
- A static representation of demo users, devices, services, certificates,
  security profiles, relationships and VPN status.
- A static preview of certificate claim, certificate request, validation,
  signing preview, certificate preview and policy evaluation screens.
- A static preview of the reverse certificate-to-claims-to-authorization flow.

Static preview may contain demo data, fixed tables and non-authoritative status
text. It must remain safe to open directly as static HTML.

Static preview should not be treated as an authoritative runtime because it does
not own backend state, perform live validation, handle events, call the VPN
admin API, issue certificates, verify private keys, enforce policy decisions or
communicate with future CA and LDAP integrations.

## Live Runtime Mode

Live Runtime Mode is the Erlang + N2O/Nitro application runtime. In the current
source tree the live page implementations are Erlang modules under `src/pages`.
The architectural runtime surface is the live IAS application, including the
`/app/*.htm` routes when deployed through N2O.

Live runtime is responsible for:

- N2O eventing and WebSocket updates.
- Nitro rendering.
- Runtime navigation and page state.
- VPN integration through the VPN admin API.
- Live VPN status and peer metadata.
- Future CA integration.
- Future LDAP integration.
- Authoritative request validation and policy evaluation.
- Future certificate issuance workflows.

All live-rendered text must continue to follow `docs/NITRO-RENDERING.md`.
In particular, atoms and mixed text values must be converted before they are
placed into Nitro bodies, text iolists must be collapsed explicitly, JavaScript
HTML updates must be escaped correctly, and render paths such as `#replace{}`
must keep binary/string/iolist handling explicit.

## Why Both Modes Exist

IAS needs a static preview because the product flow should be reviewable without
starting an Erlang node or connecting runtime services. This makes the prototype
easy to publish, inspect and share through GitHub Pages.

IAS also needs a live runtime because the real product depends on behavior that
static HTML cannot provide: event handling, runtime service calls, validation,
authorization, VPN integration and future CA/LDAP workflows.

The static mode is therefore a preview and demo artifact. The live mode is the
service runtime.

## Current IAS Flow

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

Both flows may be represented in static preview, but runtime validation,
eventing, integration and authorization semantics belong to live runtime.

## Static vs Live Responsibilities

Static Preview Mode should support:

- Opening `priv/static/*.htm` without an Erlang server.
- Demo navigation across IAS pages.
- Static demo data for users, devices, services, certificates and profiles.
- Static relationship views.
- Static certificate issue and verification previews.
- Static GitHub Pages publication.

Live Runtime Mode should support:

- Event-driven interactions.
- Runtime data loading.
- Runtime VPN status.
- Mapping demo IAS records to live VPN peers.
- Future CA signing and certificate issuance.
- Future LDAP-backed identity/profile lookup.
- Authoritative policy and authorization checks.

Features that depend on backend state or external systems must be implemented in
Live Runtime Mode first. Static Preview Mode may mirror the shape of those
features only as non-authoritative demo HTML.

## GitHub Pages Demo

The GitHub Pages demo should publish Static Preview Mode from `priv/static`.
This is intentional and is not a runtime bug. The demo is useful for presenting
the IAS information architecture and user journey without requiring deployment
of Erlang, N2O, Nitro, VPN, CA or LDAP services.

Any GitHub Pages content must avoid implying that static preview is performing
live validation, issuing certificates, reading VPN state or enforcing policy.

## Future Runtime Work

### OVPN Import Preview

OVPN import is a future Live Runtime workflow. It must not be implemented as
part of this document-only planning step.

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

The future implementation should treat `.ovpn` input as untrusted runtime data.
The parser should extract the OpenVPN configuration fields needed for an IAS
preview, including CA material, client certificate material, private key
presence, remote endpoints and routes.

The preview should then map extracted data to IAS concepts:

- IAS Device: the client endpoint or peer identity represented by the config.
- IAS Certificate: the certificate claims and certificate metadata extracted
  from the config.
- VPN Service: the OpenVPN service, remote endpoint and route intent represented
  by the config.

The import preview should remain a preview until live runtime validation,
authorization rules and certificate/key handling semantics are defined. Static
preview may later show a fixed demonstration of the flow, but authoritative
parsing and mapping belong to Live Runtime Mode.
