# IAS VPN Authority Digest Migration

IAS VPN authority records written with schema version 1 used Erlang external
term encoding for `command_digest`. That encoding is not a durable interchange
format across OTP major releases. A record written on an older OTP release can
therefore remain structurally valid while its digest can no longer be
reproduced after an OTP upgrade.

Schema version 2 uses `ias_vpn_command_digest`, whose canonical encoding has
explicit type tags, lengths and stable map ordering. New authority records are
written with schema version 2.

Migration is explicit and is never performed during IAS bootstrap.

## Preparation

Stop IAS and back up the Mnesia directory:

```bash
cd ~/ias
cp -a local/mnesia local/mnesia.before-authority-digest-v2
```

Start only Mnesia and KVS, using exactly the same Erlang node name and cookie as
normal IAS startup:

```bash
ERL_FLAGS="-name ias@127.0.0.1 -setcookie node_runner" \
rebar3 shell --apps mnesia,kvs
```

## Inspect

```erlang
ias_vpn_authority_migration:inspect().
```

The result separates records into:

- `current` — schema version 2;
- `legacy_verified` — schema version 1 whose old digest is still reproducible;
- `legacy_unverifiable` — structurally valid schema version 1 whose old digest
  is no longer reproducible on the current OTP release.

## Verified migration

When every legacy record is verified:

```erlang
ias_vpn_authority_migration:migrate_legacy_digests().
```

## Cross-OTP migration

After reviewing the inspection result and preserving the backup, explicitly
accept legacy records that cannot be reverified on the current OTP release:

```erlang
ias_vpn_authority_migration:migrate_legacy_digests(
    accept_unverifiable_legacy_digests).
```

This confirmation does not skip structural validation or secret-material
checks. It only permits replacement of an unverifiable legacy digest with the
portable schema-version-2 digest. Command payloads, revisions, bindings and
timestamps are preserved.

Run `inspect/0` again, exit the migration shell, and start IAS normally.
## Relationship to the VPN migrations

This document covers only IAS-owned authority records. The VPN durable
projection has an independent outer checksum, and each VPN provisioning head has
an independent command digest. Migrate and start VPN first, then migrate IAS and
verify reconciliation. See `OTP-28-MIGRATION.md` for the complete paired upgrade
order.
