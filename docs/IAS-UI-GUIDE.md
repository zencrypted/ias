# IAS operator UI guide

This guide explains how to operate the IAS web interface, how IAS reflects VPN
runtime changes, and how to interpret reconciliation and recovery states.

IAS is the authority for identities, policies and desired VPN provisioning
state. The VPN node owns runtime peer processes and its durable projection.
Live UI updates are wake-up driven: VPN publishes sanitized events, the IAS
bridge reads a fresh runtime snapshot, and subscribed pages redraw only their
VPN-dependent panels.

## Start the development topology

The required processes depend on the workflow:

| Topology | Supported workflows |
| --- | --- |
| IAS + VPN | UI browsing, runtime monitoring, live peer state, reconciliation, recovery and certificate inventory |
| IAS + VPN + CA/CMP | Complete certificate enrollment and device-bound provisioning, including certificate issuance |

For the full development topology, start the services in this order:

1. CA/CMP;
2. VPN;
3. IAS.

Start the OTP 28 CA/CMP development service from the IAS repository with the
provided helper script:

```bash
cd ~/ias
tools/ca/run-ca-otp28.sh
```

The helper owns the development CA startup details. Use it instead of manually
reconstructing the CA node arguments. Keep that process running while testing
enrollment or complete provisioning flows.

Then start VPN with the distributed node name and cookie expected by IAS:

```bash
cd ~/vpn
ERL_FLAGS="-name vpn@127.0.0.1 -setcookie node_runner" rebar3 shell
```

Finally start IAS:

```bash
cd ~/ias
ERL_FLAGS="-name ias@127.0.0.1 -setcookie node_runner" rebar3 shell
```

Open:

```text
http://localhost:8041/app/index.htm
```

The default development target is `vpn@127.0.0.1`. The two nodes must use the
same distributed Erlang cookie.

If IAS is started while VPN is unavailable, IAS remains usable, but
VPN-dependent panels show `unavailable` or an explicit metadata-unavailable
message.

If CA/CMP is not running, the monitoring and reconciliation pages continue to
work with IAS and VPN, but enrollment and complete certificate-issuing
provisioning flows cannot finish. A configured local CA trust anchor only lets
IAS validate the expected CA identity; it does not mean that the CA/CMP service
is currently running.

After restarting IAS, reload any already open browser tabs. The old Nitro page
process and its VPN event subscription belonged to the previous IAS node even
if the browser still displays the old HTML.

## Main pages

### Users

Lists IAS users and their assigned security profiles and relationships. This
page does not depend on live VPN runtime state.

### Devices

Lists static/demo devices and their configured VPN bindings. VPN-dependent
columns are updated live:

- VPN peer;
- peer IP;
- runtime state;
- remote peer.

A device without a VPN binding is not affected by VPN events. A configured peer
that is absent from the current VPN snapshot is shown as `unknown`.

### Device details

The detail route is:

```text
/app/demo.htm?id=<device-id>
```

For a Device object, the `VPN ACCESS` panel is updated live. Durable/manual
Devices may use a dynamic pair such as:

```text
client_dyn_<slot>_<allocator>_<generation>
gateway_dyn_<slot>_<allocator>_<generation>
```

Stopping the client runtime peer changes `Session` from `running` to `stopped`
without reloading the page. If the VPN node becomes unreachable, the session is
shown as `unavailable`.

The same `/app/demo.htm` route is also used by other IAS object kinds. Only
Device details subscribe to VPN runtime events.

### Services

The VPN service row updates live. The following fields come from the latest VPN
runtime snapshot:

- State;
- Configured Peers;
- Running Peers;
- Certificates.

Stopping one peer decreases the running count but does not make the service
unavailable. Stopping the VPN node changes the service state to `unavailable`.

### Certificates

The runtime certificate inventory is read from VPN peers and updated live. The
summary has the form:

```text
Certificates: 10 · Running peers: 9
```

The certificate count and running-peer count describe different things. A
stopped peer keeps its certificate, so its row remains in the table while
`Runtime State` changes from `running` to `stopped`.

Columns include:

- Peer;
- Runtime State;
- Subject CN and Issuer CN;
- Valid From and Valid To;
- Trusted;
- Key Match;
- Security Profile;
- Claims.

When the whole VPN node is unavailable, IAS cannot read runtime certificate
metadata and shows an unavailable message instead of stale rows.

### Security Profiles

Lists security profiles used to derive claims and authorization decisions. This
page is IAS-owned and does not require a live VPN subscription.

### Relationships

Shows graph relationships between users, devices, certificates, services and
profiles. This page does not directly read VPN runtime state.

### VPN

This is the main operational page for:

- runtime peer visibility;
- IAS/VPN reconciliation;
- orphan inspection;
- explicit replay;
- recovery and decommission workflows.

The page subscribes to VPN events and reads a fresh runtime snapshot after each
accepted event. A manual Start or Stop action in the VPN admin UI is represented
by a `peer_runtime_changed` event. Reconciler operations use
`runtime_reconciled` events.

### OVPN Import

Provides OVPN preview/import diagnostics and links into the device-bound
provisioning flow. It does not need a continuous VPN runtime subscription.

### Provisioning Wizard

Creates the IAS objects and revisioned VPN desired state for a device-bound
flow. It is a workflow page rather than a live runtime monitor.

## Runtime states

The UI uses these common runtime values:

- `running` — the peer process is present in the fresh VPN runtime snapshot;
- `stopped` — the peer remains configured but its runtime process is not
  running;
- `unknown` — IAS has a peer binding, but no matching peer is present in the
  current successful snapshot;
- `unavailable` — IAS could not obtain a VPN snapshot because the VPN node or
  read API is unavailable;
- `none` or `-` — the IAS object has no VPN binding for that field.

Do not interpret `stopped` as deletion. Configuration, provisioning head and
certificate metadata may still exist.

## Live update behavior

The following pages currently subscribe to `ias_vpn_event_bridge`:

| Page | Live VPN-dependent content |
| --- | --- |
| VPN | runtime peers, event status, reconciliation and recovery refresh |
| Services | service state and peer/certificate counts |
| Devices | VPN binding and runtime columns |
| Device details | `VPN ACCESS` and dynamic session state |
| Certificates | inventory, runtime state and counters |

Other pages are intentionally not subscribed because they do not render live
VPN runtime data.

A manual runtime event triggers an immediate snapshot and a short delayed
convergence snapshot. The delayed read covers the small interval in which a
Stop command has returned but the peer process is still terminating.

## Reconciliation statuses

Reconciliation compares IAS durable VPN authority with the VPN provisioning
head and public registry snapshot. It is not merely a check that a row exists in
the Devices UI.

### `synchronized / in_sync`

IAS revision, VPN revision, portable command digest, allocation identity and
expected runtime registry presence agree.

### `vpn_behind`

VPN has an older revision or an equal revision whose command is still pending.
This state may be eligible for explicit Replay.

### `missing_in_vpn`

The expected durable provisioning head or runtime registry entry is missing.
This state may be eligible for explicit Replay.

### `divergence`

IAS and VPN disagree in a way that cannot be repaired automatically. Common
reasons include:

- `command_digest_mismatch`;
- VPN revision ahead of IAS;
- identity or allocation mismatch;
- runtime presence contradicting the desired lifecycle;
- `ias_domain_device_missing` — authority and VPN state remain, but the IAS
  domain Device no longer exists.

Do not use Replay for a divergence merely to hide the mismatch. Diagnose the
reason first.

### `orphan`

An IAS-sourced VPN provisioning/runtime object exists without a matching IAS
authority record. Recovery or decommission may be offered after validation.

### `authority_only`

IAS has durable binding metadata but no canonical provisioning command to
compare or replay.

## Replay, recovery and decommission

### Replay

Replay is allowed only for safe IAS-ahead states such as `vpn_behind` and
`missing_in_vpn`. IAS resends the existing durable canonical command with the
same revision and verifies a fresh snapshot afterward.

Replay is not a general-purpose repair button for `divergence`, orphan data or
missing IAS domain objects.

### Recover into IAS

Recovery imports a validated orphan manifest into IAS through an explicit,
audited and durable operation. It is available only when the VPN head contains
sufficient safe recovery metadata.

### Decommission from VPN

Decommission removes a validated orphan from VPN through an explicit audited
compare-and-remove operation. It does not silently infer IAS ownership.

Recovery operations are designed to be durable and idempotent. Repeating a
completed operation must not create duplicate objects or provisioning work.

## Common UI verification scenarios

### Stop and start one peer

1. Keep IAS and VPN running.
2. Open a subscribed IAS page such as Devices, Device details, Services or
   Certificates.
3. In the VPN admin UI, stop the exact peer represented on that page.
4. Do not reload IAS.
5. Verify the relevant runtime state or count changes to `stopped` or decreases.
6. Start the peer and verify it returns to `running`.

For a dynamic Device detail page, stop the displayed `client_dyn_*` peer. The
static Devices list normally represents its own configured peers such as
`peer_a` or `peer_b`; stopping an unrelated dynamic peer need not change that
list.

### Stop the whole VPN node

With an IAS page open, stop the VPN shell. Expected behavior includes:

- Services: state becomes `unavailable`;
- Certificates: runtime metadata becomes unavailable;
- Device details: session becomes `unavailable`;
- VPN page: bridge connection status reports the failure.

Restart VPN. The bridge reconnects and subscribed pages receive a fresh
snapshot automatically.

### Provision or decommission a dynamic Device

Use the Provisioning Wizard or the explicit reconciliation recovery/decommission
controls. Verify that Device details, Certificates, VPN runtime rows and
reconciliation reflect the new state without relying on a stale browser reload.

## Troubleshooting live updates

Inspect the bridge from the IAS shell:

```erlang
ias_vpn_event_bridge:status().
```

Important fields:

- `connected` — whether the bridge is subscribed to the VPN event bus;
- `subscriber_count` — number of active IAS page processes listening for
  updates;
- `stream_id` — current VPN event stream identity;
- `sequence` — last accepted event sequence;
- `last_event_at` — time of the last accepted event;
- `last_snapshot_at` — time of the last successful snapshot;
- `snapshot_status` — freshness/error state of the snapshot;
- `sync_reason` — why the latest snapshot was broadcast;
- `last_error` and `last_snapshot_error` — current event or read failure.

Read the current VPN summary directly:

```erlang
ias_vpn_runtime:summary().
```

Check one peer:

```erlang
{ok, Summary} = ias_vpn_runtime:summary().
Peer = ias_vpn_runtime:peer(<<"peer_b">>, {ok, Summary}).
ias_vpn_runtime:state(Peer).
```

When an expected page is open, `subscriber_count` should be at least one. A
value of zero usually means:

- the page is not one of the subscribed VPN-dependent pages;
- the browser tab was opened before IAS restarted and must be reloaded;
- the page process has already terminated.

If `sequence` and `last_event_at` do not change after a manual peer action,
verify that the VPN admin action uses the external runtime command layer and
that both nodes are connected with the expected names and cookie.

If the bridge advances and the shell summary is fresh but the UI remains stale,
inspect the page-specific Nitro update target. If the summary itself remains
stale, diagnose the VPN runtime snapshot rather than the page renderer.

## Related documentation

- `IAS-VPN-PROVISIONING-DELIVERY.md` — ownership, RPC delivery and event bridge
  architecture;
- `IAS-DURABLE-STATE.md` — IAS durable object and recovery model;
- `IAS-VPN-AUTHORITY-DIGEST-MIGRATION.md` — authority digest migration;
- `OTP-28-MIGRATION.md` — paired IAS/VPN OTP 28 upgrade runbook;
- `NITRO-RENDERING.md` — safe Nitro rendering rules;
- `RUNTIME-MODES.md` — static preview and live runtime modes.
