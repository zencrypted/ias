# IAS VPN Provisioning Delivery

IAS is the source of truth for VPN peer identity, authorization, and desired
projection. VPN is the runtime projection that applies IAS-issued revisioned
commands.

## Canonical flow

```text
IAS Device
-> ias_vpn_provisioning_command:build/2
-> ias_vpn_provisioning_state
-> ias_vpn_provisioning_delivery
-> rpc:call(VpnNode, vpn_provisioning, apply, [Command], Timeout)
-> VPN peer registry and manager runtime
```

`ias_vpn_provisioning_state` owns canonical revision assignment. Delivery must
not mutate the command or create a newer revision on retry.

## RPC direction and runtime boundary

The IAS/VPN integration is intentionally one-way:

```text
IAS
-> revisioned provisioning command
-> distributed Erlang RPC
-> VPN provisioning API
-> local VPN desired-state projection
-> peer reconciliation and runtime
```

IAS initiates provisioning operations such as `upsert`, `enable`, `disable`,
`revoke`, and `remove`. VPN does not call IAS during peer startup, certificate
handshake, session establishment, rekey, peer restart recovery, or dataplane
packet processing. There is no VPN-to-IAS authorization RPC in the current
architecture.

After a command has been accepted, VPN enforces the resulting state locally
through its peer registry and reconciled peer processes. Temporary IAS
unavailability therefore does not interrupt already provisioned and running VPN
peers.

This separation is a control-plane boundary. Distributed Erlang RPC delivers
IAS desired state to VPN; it is not part of the encrypted packet dataplane.

The current VPN projection is volatile. A VPN node restart does not yet durably
restore IAS-applied revisions, revocations, tombstones, or delivery history.
Durable projection or authoritative replay from IAS is a separate recovery
concern.

## Deployment topology and optional embedded VPN

The current development topology uses separate Erlang nodes:

```text
IAS node
   |
   | distributed Erlang RPC
   v
VPN node
```

This is a development and deployment choice, not a permanent architectural
requirement. VPN may later be added as an IAS dependency and included in the
same release:

```text
IAS release
|-- ias application
`-- vpn application
```

Embedding VPN into the IAS release would change physical placement, but it must
not change logical ownership or the one-way control flow:

```text
IAS
-> identity, authorization, certificate binding, and desired peer state
-> VPN provisioning contract
-> VPN local runtime projection and enforcement
```

IAS remains the source of truth for identity, certificate binding,
authorization, and desired peer state. VPN remains responsible for peer
reconciliation, session runtime, tunnel processing, and dataplane enforcement.
VPN must not acquire ownership of IAS policy data merely because both OTP
applications are packaged together.

The separate-node topology is currently preferred for development because it:

- allows IAS and VPN to be started, stopped, and restarted independently;
- exercises real distributed RPC failure, timeout, retry, and recovery paths;
- prevents ordinary IAS development and tests from requiring `/dev/net/tun`,
  network capabilities, or VPN UDP port configuration;
- keeps the control-plane and dataplane boundary visible;
- preserves the option for one IAS instance to provision multiple VPN nodes.

A future embedded mode may keep the existing RPC interface and target the local
node, or use a local adapter implementing the same provisioning contract. In
either case, public operation semantics and the IAS-to-VPN direction must remain
unchanged.

Conceptually, supported deployment modes may be:

```text
external
    IAS and VPN run on separate Erlang nodes.

embedded
    IAS and VPN run as separate OTP applications in one release/node.

disabled
    VPN integration is not started for static preview or isolated IAS tests.
```

The current external topology therefore does not prevent a later single-release
deployment.

## Transport configuration

IAS reads these application environment keys:

- `vpn_provisioning_transport`: `disabled | erlang_rpc`
- `vpn_provisioning_vpn_node`: distributed Erlang VPN node name
- `vpn_provisioning_rpc_timeout`: RPC timeout in milliseconds

Default configuration is:

```erlang
{vpn_provisioning_transport, disabled}
{vpn_provisioning_vpn_node, 'vpn@127.0.0.1'}
{vpn_provisioning_rpc_timeout, 5000}
```

`disabled` is the safe default. IAS does not contact VPN unless the transport is
explicitly enabled.

## Delivery statuses

IAS normalizes delivery outcomes into these statuses:

- `applied`
- `unchanged`
- `rejected`
- `timeout`
- `node_unavailable`
- `transport_error`
- `unexpected_result`
- `disabled`

VPN return values are preserved only in sanitized form. IAS keeps a minimal peer
summary for successful applies and minimal atoms/binaries for rejected or
transport-level failures.

## History and retry semantics

- every delivery attempt is recorded on the IAS side, including retries and
  rejected attempts;
- retrying the same canonical command reuses the same revision;
- delivery failure does not advance the IAS revision;
- a genuinely changed desired projection or operation receives a newer revision
  only through `ias_vpn_provisioning_command:build/2`;
- the current implementation is demo-runtime only and keeps history in volatile
  ETS;
- no private keys, PEM bodies, OVPN bodies, session keys, ECDH material, replay
  state, or raw VPN process state are stored in IAS delivery history.

## Security boundary

Distributed Erlang connectivity is a development integration mechanism. Both
nodes must use:

- compatible node naming (`-name` or `-sname`, but not mixed);
- the same Erlang cookie;
- reachable EPMD/node ports.

The cookie is a shared secret. Do not commit it. Keep IAS delivery history and
logs free of secrets and runtime key material.

## Development startup

Example long-name approach:

1. Start VPN with `-name vpn@127.0.0.1` and a shared cookie.
2. Start IAS with `-name ias@127.0.0.1` and the same cookie.
3. Set IAS transport:

```erlang
application:set_env(ias, vpn_provisioning_transport, erlang_rpc).
application:set_env(ias, vpn_provisioning_vpn_node, 'vpn@127.0.0.1').
application:set_env(ias, vpn_provisioning_rpc_timeout, 5000).
```

4. Verify connectivity:

```erlang
net_adm:ping('vpn@127.0.0.1').
```

5. Build and deliver:

```erlang
ias_vpn_provisioning_delivery:build_and_deliver(DeviceId, upsert).
```

Persistence, automatic background retries, and non-RPC transports remain out of
scope for this stage.
