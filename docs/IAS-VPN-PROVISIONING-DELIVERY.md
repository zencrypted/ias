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
