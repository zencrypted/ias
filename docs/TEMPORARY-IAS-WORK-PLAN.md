# Temporary IAS Work Plan

> **Temporary coordination document.** Remove this file after the plan is
> completed and the resulting architecture is reflected in the canonical IAS
> documentation under `erpuno/erp.uno/ias`.

## Goal

Bring the IAS documentation and runtime to one consistent model before the
provisioning lifecycle is migrated to BPMN/BPE.

## Priority 1 — Documentation baseline

Minimally align `ias.tex` and `ias_pro.tex` with the current code before further
runtime changes.

Classify statements explicitly as:

- **Implemented** — confirmed by the current IAS/VPN code and tests;
- **Target** — intended architecture that is not implemented yet;
- **Compliance / presale** — requirements or product claims that require
  separate implementation and evidence.

The baseline must record the current integration boundaries:

- IAS persists its supported domain state through KVS/Mnesia;
- IAS provisions VPN desired state through Erlang RPC;
- IAS requests certificate issuance from the CA through HTTP;
- the current provisioning wizard uses a hand-written FSM;
- BPMN/BPE is a target architecture, not the current runtime.

Do not present generated BPE modules, EST/CMC, CRL/OCSP, EUDI, TSP, KCSZI G3,
at-rest encryption, or similar unverified capabilities as implemented.

## Priority 2 — Remove OpenSSL from IAS runtime

Remove the legacy server-side OpenSSL path after confirming that the existing CA
HTTP integration covers certificate issuance.

The canonical flow must be:

```text
Device -> CSR -> IAS -> HTTP -> CA -> issued certificate -> IAS
IAS -> Erlang RPC -> VPN desired state
```

IAS must not depend on:

- `openssl cmp` or `openssl x509` shell commands;
- absolute local OpenSSL paths;
- a local checkout or filesystem layout of the CA repository;
- server-side private-key generation for a Device.

CSR and X.509 parsing/validation should use Erlang/OTP `public_key` where
applicable. Device private keys remain Device-owned.

## Priority 3 — Stabilize the complete wizard lifecycle

Run and verify the current end-to-end provisioning sequence:

```text
Scheme
-> User
-> Device
-> Security Profile & Policy
-> VPN Service
-> CA Certificate
-> Client Certificate
-> Relationships
-> Material Readiness
-> Provisioning
-> VPN applied state
```

Cover at least:

- the happy path;
- CA unavailability and structured errors;
- VPN node unavailability;
- retries and idempotence;
- restart recovery;
- reconciliation and degraded states.

The existing behavior and tests form the version-1 compatibility baseline for
the BPMN/BPE migration.

## Priority 4 — Describe the AS IS process

Describe the real wizard lifecycle as an AS IS FSM/BPMN model before changing
its orchestration.

Distinguish:

- user tasks;
- service tasks;
- gateways and automatic transitions;
- remediation paths;
- retry/failure states;
- terminal `ready`, `degraded`, and `failed` outcomes.

The BPMN model must describe the current supported behavior rather than invent
new runtime modules.

## Priority 5 — Integrate BPMN/BPE incrementally

Use the complete Device provisioning lifecycle as the first real BPE process.

The target responsibility split is:

```text
BPE process        = lifecycle state and orchestration
Provisioning UI    = projection and operator commands
Existing services  = domain and integration service tasks
```

Do not rewrite all domain services inside BPE. Migrate orchestration in small
steps, preserve current behavior, and keep the existing test suite as the
acceptance baseline.

## Priority 6 — Final documentation synchronization

After the runtime changes:

- update `ias.tex`, `ias_pro.tex`, and `policy.tex`;
- replace temporary or generated claims with verified architecture;
- publish the final TeX/PDF sources from `erpuno/erp.uno/ias`;
- remove this temporary plan.

## Parallel non-blocking track

Build a separate port and service inventory in the security profiles, starting
with IAS and VPN and then covering all ERP/1 products and examples through
`net.ex`. This work must not block the OpenSSL cleanup or the BPMN/BPE migration.
