# IAS Durable Domain State

## Status

Stages 1 and 2A implemented; Stages 2B–7 remain planned.

This document defines how IAS should make its domain object graph survive an IAS
node restart without changing the authority boundary between IAS and VPN.

## Problem

The live IAS UI currently exposes two different classes of state:

- `ias_demo_store` and `ias_provisioning_wizard_store` keep domain objects,
  relationships and wizard drafts in node-local ETS;
- `ias_vpn_authority` and `ias_vpn_reconciliation_incidents` keep a narrow VPN
  control-plane projection in Mnesia `disc_copies`.

As a result, a Device created through the wizard can disappear from Demo State
after an IAS restart while its durable VPN authority and the corresponding VPN
projection remain present. Reconciliation may still report that VPN projection
as synchronized because it compares the durable IAS VPN ledger with VPN, not the
volatile IAS object graph.

The manual Demo State export/import flow is useful for development, but it is a
sanitized operator snapshot. It is not automatic persistence, an authoritative
transaction log or a replacement for startup recovery.

## Authority Model

The target ownership model is:

```text
KVS domain store = source-of-truth API for IAS domain objects
Mnesia backend   = current durable KVS implementation (`disc_copies`)
ETS              = runtime read projection/cache
VPN              = projection of IAS-authorized VPN intent
UI               = consumer of IAS APIs and ETS projection
```

The reverse direction is not allowed:

```text
VPN object -> automatic IAS object creation
```

A VPN record must never become authoritative merely because it exists in VPN.
An orphan VPN projection requires an explicit, audited disposition decision; it
must not be copied into ETS as an implicit recovery mechanism.

## Goals

The first durable-state release should:

1. preserve supported IAS domain objects and relationships across IAS restart;
2. keep existing `ias_demo_store` callers and UI flows stable;
3. commit durable state before exposing it through ETS;
4. rebuild ETS from validated durable records before the HTTP service starts;
5. reject unsupported schema or unsafe payloads fail-closed;
6. preserve the current one-way `IAS -> VPN` authority model;
7. provide restart tests for a complete wizard-created object graph.

## Non-goals

The first release does not:

- persist private keys, shared secrets, OVPN bodies or TLS key material;
- make VPN a recovery source for IAS objects;
- replace CA, LDAP or external audit storage;
- make browser, Nitro or websocket session state durable;
- define the final multi-node KVS/Mnesia topology;
- automatically adopt or delete orphan VPN projections.

## Current State Inventory

### Volatile ETS state

The following stores are currently recreated empty with the Erlang VM:

- `ias_demo_store`;
- `ias_provisioning_wizard_store`;
- `ias_certificate_material`;
- other workflow-local or session-local state.

`ias_demo_store` contains runtime maps for objects such as:

- Device;
- Certificate metadata;
- Certificate Verification;
- Certificate Replacement;
- Certificate Revocation;
- VPN Service;
- runtime-created Security Policy;
- CMP Enrollment Result;
- OVPN Provisioning metadata;
- Relationship edges.

Built-in Users, Security Profiles and static policies are seeded from code and
therefore do not require persistence in the first stage. If those catalog types
become operator-editable later, they must move behind the same durable contract.

### Existing durable state

IAS already persists two narrow stores on the KVS/Mnesia stack:

- `ias_vpn_device_state`, owned by `ias_vpn_authority`;
- `ias_vpn_reconciliation_incident`, owned by
  `ias_vpn_reconciliation_incidents`.

These tables remain separate. The VPN authority table is not a complete Device,
Certificate, Service or Relationship store and must not be treated as one.

## Persistence Classification

| State | First durable release | Later stage | Never in this store |
|---|---:|---:|---:|
| Domain object metadata | yes | | |
| Relationship edges | yes | | |
| Wizard drafts | | yes | |
| Provisioning delivery audit | | yes | |
| Certificate public metadata/fingerprints | yes | | |
| Certificate/CA PEM bodies | | secure material design | |
| CSR body | | resumable workflow design | |
| Private key or private-key body | | | yes |
| TLS auth/crypt body or shared secret | | | yes |
| OVPN profile/artifact body | | | yes |
| VPN event bridge state | | | yes |
| Nitro/websocket/session state | | | yes |

The classification is based on content, not only on field names. A map that
contains an unknown or nested secret-bearing value must be rejected rather than
persisted optimistically.

## Proposed Store

Introduce a dedicated module:

```text
ias_domain_store
```

and one initial KVS table backed by Mnesia `disc_copies`:

```text
ias_domain_object
```

A practical first schema is:

```erlang
-record(ias_domain_object, {
    key,                  %% {Kind, ObjectId}
    schema_version = 1,
    kind,
    object_id,
    payload = #{},        %% explicit sanitized persistent projection
    revision = 1,
    created_at = 0,
    updated_at = 0
}).
```

Table properties:

```text
type         = set
storage      = disc_copies
primary key  = {Kind, ObjectId}
```

Relationships may initially use the same table with `kind = relationship`. This
matches the current universal map façade and keeps the first migration small.
A dedicated indexed relationship table may be introduced later if graph size or
query patterns justify it.

## Persistent Projection Contract

Persistence must not write arbitrary runtime maps directly.

Each supported kind needs an explicit persistent projection and validator:

```text
runtime object
  -> normalize id and kind
  -> build kind-specific public metadata projection
  -> reject forbidden or unknown secret-bearing fields
  -> validate references and schema
  -> commit durable record
```

A global deny-list such as the one used by Demo State export is useful as a final
defence, but it is not sufficient as the primary contract. The durable store
should use kind-specific allow-lists or constructors so newly introduced fields
do not become persistent automatically.

At minimum, persistence must reject nested occurrences of:

- private key material;
- certificate or CA bodies until secure material storage is designed;
- CSR bodies;
- TLS auth/crypt material;
- shared secrets and PSKs;
- OVPN profile or artifact bodies;
- session keys, process identifiers and browser state.

References, fingerprints, public filenames and non-secret lifecycle metadata may
be stored after validation. A field name such as `private_key` may also appear as
a fixed label inside explicitly modeled metadata maps such as
`material_requirements`, `material_sources` or `material_components`; only an
allow-listed non-secret status/source value is accepted there. The same key in
arbitrary metadata, or any private-key body/value, remains forbidden.

## API Boundary

The initial API should be small and independent of page modules:

```erlang
ias_domain_store:ensure/0.
ias_domain_store:put/1.
ias_domain_store:get/2.
ias_domain_store:delete/2.
ias_domain_store:all/0.
ias_domain_store:transaction/1.
ias_domain_store:validate_all/0.
ias_domain_store:reset/0.      %% test/development only
```

`ias_demo_store` remains the compatibility façade used by current domain and UI
code. It becomes a write-through projection layer rather than the authority.
Single-object callers use `put_runtime_object/1`; graph-producing callers use
`commit_graph/2` so objects and edges share one durable unit of work.

`ias_domain_store` must use the public KVS abstraction for schema discovery and
CRUD. Direct `mnesia:*` calls are not allowed in this domain store. The current
installation uses `kvs_mnesia` with `disc_copies`, but backend selection remains
an application configuration concern rather than a domain-store dependency.

KVS does not expose a generic multi-operation transaction API. Stage 1 therefore
uses an IAS-side unit of work: reads are loaded through KVS, mutations are staged
in memory, validation runs against the staged graph, and the resulting write set
is committed through KVS only after the callback succeeds. Stage 2 must preserve
this abstraction when it adds the ETS write-through boundary.

## Write Semantics

### Single object

The required order is:

```text
validate persistent projection
  -> commit through the KVS domain-store unit of work
  -> update ETS projection
  -> return stored object
```

The KVS-backed durable write must be committed before the object becomes visible through ETS. If IAS
fails after the durable commit but before ETS update, startup rehydration or an
explicit projection repair restores ETS from Mnesia.

The opposite order is unsafe because it can expose an object that never became
durable.

### Multi-object graph

Wizard completion can create or update several objects and relationships. These
writes must eventually share one transaction boundary:

```text
Device
Certificate
VPN Service
Relationship edges
Wizard completion metadata
```

The KVS domain-store unit of work commits the complete graph first. ETS changes are applied
only after a successful commit. A failed transaction must leave neither a
partial durable graph nor a partially updated ETS projection.

This work should be coordinated with `TD-014: Device Enrollment Completion Is
Not Atomic` rather than creating a second incompatible transaction mechanism.

### Idempotency and revisions

`put/1` should be idempotent for an unchanged persistent projection. Each changed
record increments a durable revision. Callers may later use expected revision
for optimistic concurrency, but the first stage only needs stable monotonic
revision metadata and deterministic equality.

## Delete Semantics

Deletion must be fail-closed.

The first implementation should reject deletion of an object while relationship
edges still reference it. A later explicit cascade operation may delete the
object and all selected edges in one durable KVS unit of work, but silent cascade from
the generic `delete/2` API is not allowed.

Deleting a Device domain object and deleting its VPN authority are separate
domain operations. The orchestration layer must decide whether VPN access should
be disabled, revoked or decommissioned before domain deletion is committed.

## Startup Rehydration

IAS startup should complete durable recovery before Cowboy accepts requests:

```text
start/join KVS with its configured Mnesia backend
  -> ensure and validate domain table
  -> read and validate all durable records
  -> build a clean ETS projection
  -> overlay static seed catalogs
  -> verify projection counts/digests
  -> start HTTP and supervised runtime services
```

If table schema, record schema or persistent payload validation fails, IAS must
fail startup rather than silently dropping records and presenting an incomplete
object graph.

The first implementation may clear and repopulate the named ETS table because
HTTP is not yet accepting requests. If live projection rebuild is needed later,
a staging table and atomic table switch should be introduced.

Static catalog objects keep their current overlay rule: a durable object with the
same normalized identity wins; otherwise the built-in seed is shown.

## Projection Health

Demo State should evolve from a purely volatile counter page into a persistence
diagnostic surface. Useful read-only values are:

```text
Durable Domain Objects
Durable Relationships
ETS Projection Objects
ETS Projection Relationships
Wizard Drafts (volatile/durable)
Last Rehydration Time
Projection Status: synchronized | mismatch | unavailable
```

A count or digest mismatch must be visible and must not be repaired by copying
VPN state into IAS.

## Existing Demo State Import

The existing `.eterm` export/import remains a development tool.

After the durable store exists, import may be offered as an explicit one-time
migration path:

```text
parse sanitized snapshot
  -> validate every object and relationship
  -> show migration plan
  -> explicit operator confirmation
  -> one durable transaction
  -> rebuild ETS projection
```

Import must not silently run at startup and must not overwrite newer durable
records without an explicit conflict policy.

## Failure Semantics

| Failure | Required behavior |
|---|---|
| KVS backend unavailable at startup | IAS startup fails closed |
| Unsupported table/record schema | IAS startup fails closed with diagnostic |
| Invalid or secret-bearing payload | write rejected; ETS unchanged |
| Durable commit aborted | ETS unchanged |
| ETS update fails after commit | report projection degraded; rehydrate from Mnesia |
| Relationship references missing object | transaction rejected unless explicitly allowed by workflow |
| VPN unavailable | domain state remains available; VPN reconciliation reports unavailable/stale |

## Orphan VPN Projections

Durable IAS state is a prerequisite for safe orphan recovery, but it does not
automatically resolve orphans.

Two future explicit operations are expected:

```text
Decommission from VPN
Recover into IAS
```

`Recover into IAS` must create a validated durable IAS graph, not a temporary ETS
record. It requires operator selection or creation of the owning User, Device,
Certificate, VPN Service, Security Profile and relationship edges as applicable.
The action must be audited and must validate the current orphan snapshot token
before committing.

Until that workflow is designed, automatic orphan adoption remains prohibited.

## Implementation Stages

### Stage 1 — Durable store skeleton

**Status:** Implemented.

- `ias_domain_store` and the `ias_domain_object` record are present;
- `ias_domain_object` is registered in `ias_kvs` and created through the KVS schema as a `disc_copies` / `set` table;
- all domain CRUD paths use `kvs:get/2`, `kvs:put/1`, `kvs:delete/2` and `kvs:all/1`;
- kind-specific allow-listed projections reject secret-bearing material;
- revisions, idempotent writes, relationship references and guarded deletion are
  covered by EUnit tests.

### Stage 2A — Single-object write-through façade

**Status:** Implemented.

The existing `ias_demo_store` API now commits through `ias_domain_store` before
updating its ETS projection:

- `put_runtime_object/1` stores the allow-listed KVS payload first and exposes
  only that validated projection through ETS;
- `delete_runtime_object/2` performs guarded durable deletion before removing
  the ETS entry;
- relationship and CMP enrollment helpers use the same write-through boundary;
- `clear/0` resets the KVS domain table as well as the volatile projection;
- rejected or secret-bearing objects never become visible in ETS;
- deliberately broken or secret-bearing graph fixtures are inserted only by a
  test helper and do not weaken the production persistence API.

KVS keys use canonical text identities while payload IDs preserve the existing
runtime atom/binary representation. This keeps the compatibility façade stable
until the wider object model adopts one canonical public ID type.

### Stage 2B — Transactional graph writes

**Status:** Implemented.

`ias_demo_store:commit_graph/2` now accepts domain objects and relationship
specifications, stages all objects before their edges in one
`ias_domain_store:transaction/1` unit of work, and bulk-updates ETS only after the
complete durable graph commit succeeds.

The transaction callback may return `{error, Reason}` to abort without writing
its staged KVS changes. Graph commits reject duplicate identities, invalid
objects, secret-bearing payloads and missing relationship references before any
ETS projection is changed.

The OVPN import path uses one graph commit for its Device, Certificate and VPN
Service records. Provisioning-wizard relationship application prepares all new
edges first and commits the complete relationship set in one graph operation;
the previous create-and-compensate loop has been removed.

The wizard draft itself remains volatile and is updated after the durable graph
commit. Enrollment completion that also spans certificate material, Device key
references and wizard draft state remains tracked by `TD-014`; those external
stores cannot be made atomic merely by extending the KVS domain graph boundary.

### Stage 3 — Startup rehydration

- ensure the domain store before HTTP startup;
- populate ETS from durable records;
- expose projection health diagnostics;
- keep manual Demo State export/import as an explicit development tool.

### Stage 4 — Restart Common Test

Add a test that:

1. creates a complete wizard object graph;
2. records object and relationship identities;
3. restarts IAS with the same Mnesia directory;
4. verifies all domain objects and edges are rehydrated;
5. verifies VPN authority remains bound to the same Device;
6. verifies reconciliation does not create a false orphan.

### Stage 5 — Durable wizard drafts

Add a separate durable draft table or a clearly separated draft record class.
Support resume, completion and abandonment after restart without persisting form
secrets or browser/session identifiers.

### Stage 6 — Audit and material stores

Design separately:

- append-only provisioning delivery audit;
- certificate/CA public material storage;
- resumable CSR/enrollment state;
- retention, encryption and access-control policy.

### Stage 7 — Orphan disposition workflow

Only after durable domain state is operating, implement audited
`Decommission from VPN` and `Recover into IAS` procedures.

## Test Plan

### Unit tests

- table creation and schema validation;
- unchanged writes are idempotent;
- changed writes increment revision;
- secret-bearing payloads are rejected;
- unsupported kinds and schema versions are rejected;
- failed transactions do not update ETS;
- multi-object graph writes commit all objects and edges or none;
- relationship integrity is enforced;
- rehydration reproduces the durable object set and relationships.

### Common Test

- full wizard graph survives a real IAS restart;
- static seed catalogs remain available;
- deleted objects do not reappear;
- VPN authority and domain Device identity remain consistent;
- VPN disconnect during IAS restart does not corrupt domain recovery;
- reconciliation after restart reports the expected synchronized/divergent state,
  not a false orphan caused by empty ETS.

## Acceptance Criteria

The first durable-state milestone is complete when:

- a Device, Certificate, VPN Service and their relationships created through the
  live wizard survive an IAS restart without manual import;
- the restored objects appear through existing `ias_demo_store` APIs and UI;
- no forbidden material is stored in the domain table;
- startup fails on incompatible durable data instead of silently dropping it;
- a restart CT verifies the complete path with the same Mnesia directory;
- orphan VPN projections are still fail-closed and are not automatically adopted.
