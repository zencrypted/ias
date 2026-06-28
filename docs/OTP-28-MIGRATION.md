# IAS OTP 28 migration runbook

This runbook covers an IAS installation whose durable authority records were
written on an older Erlang/OTP release and which provisions a separately running
VPN node.

The complete upgrade spans both repositories. IAS owns durable authority
records, while VPN owns its durable projection, allocator state and provisioning
heads. Each repository must migrate its own integrity metadata.

## Before upgrading

Stop IAS and VPN and back up both Mnesia directories:

```bash
cp -a ~/ias/local/mnesia ~/ias/local/mnesia.before-otp-28
cp -a ~/vpn/local/mnesia ~/vpn/local/mnesia.before-otp-28
```

Keep both backups until reconciliation reports synchronized state. Do not use
VPN Replay merely to hide an OTP-dependent digest mismatch.

## 1. Prepare VPN first

Apply the OTP 28-compatible VPN update and follow the VPN
`docs/OTP-28-MIGRATION.md` runbook:

1. explicitly migrate the outer VPN projection checksum;
2. start VPN normally so legacy provisioning heads migrate automatically to
   portable digest version 2;
3. verify `vpn_provisioning:recovery_heads/0` reports digest version 2.

Starting VPN first ensures IAS reconciliation observes migrated provisioning
heads rather than legacy OTP-dependent digests.

## 2. Migrate IAS authority digests

Start only Mnesia and KVS with the same node name and cookie used by normal IAS
startup:

```bash
cd ~/ias
ERL_FLAGS="-name ias@127.0.0.1 -setcookie node_runner" \
rebar3 shell --apps mnesia,kvs
```

Inspect authority records:

```erlang
ias_vpn_authority_migration:inspect().
```

When every legacy digest can still be verified:

```erlang
ias_vpn_authority_migration:migrate_legacy_digests().
```

For a reviewed cross-OTP database whose legacy digest cannot be reproduced on
OTP 28:

```erlang
ias_vpn_authority_migration:migrate_legacy_digests(
    accept_unverifiable_legacy_digests).
```

This preserves commands, revisions, bindings and timestamps. It replaces only
the legacy authority digest and schema metadata after structural and
secret-material validation. Detailed constraints are documented in
`IAS-VPN-AUTHORITY-DIGEST-MIGRATION.md`.

Run `inspect/0` again, exit the migration shell and start IAS normally.

## 3. Verify cross-service reconciliation

With VPN and IAS running under their normal distributed Erlang node names:

```erlang
{ok, Report} = ias_vpn_reconciliation:report().
maps:get(counts, Report).
```

Previously matching records should be `synchronized`. A remaining
`command_digest_mismatch` must be diagnosed before Replay is used. Check:

- IAS and VPN revisions;
- VPN head `digest_version`;
- peer ID;
- safe desired state;
- whether the only difference is a projection default such as
  `revoked => false`.

The VPN startup migration normalizes that projection-only default before
reconstructing the portable digest and does not reprovision runtime state.

## 4. OTP JSON dependency cleanup

IAS targets OTP 28 and uses the standard `json` module from `stdlib`; the
external `jiffy` NIF dependency is no longer required. After applying the source
update, clean stale artifacts and run the complete test set:

```bash
cd ~/ias
rebar3 unlock jiffy
rm -rf _build
rebar3 eunit
VPN_REPO=/home/cryoflamer/vpn rebar3 ct
```

`json:decode/1` returns JSON objects as maps with binary keys, matching the IAS
VPN client contract previously requested through Jiffy's `return_maps` option.

## Recommended paired upgrade order

1. Stop both nodes and back up both Mnesia directories.
2. Apply and build the OTP 28-compatible VPN and IAS code.
3. Migrate the VPN outer projection checksum explicitly.
4. Start VPN and verify provisioning-head digest version 2.
5. Migrate IAS authority digests explicitly.
6. Start IAS normally.
7. Verify reconciliation and retain backups until all records are synchronized.
