# Legacy FIN schema cleanup

IAS no longer registers or uses the banking tables inherited from `erpuno/fin`:

- `phone`
- `field`
- `close_account2`
- `account`
- `client`
- `card`
- `transaction`

The corresponding record headers and the `form` dependency have also been removed.

## Existing Mnesia directories

Removing tables from `ias_kvs:ias/0` prevents fresh IAS installations from
creating them. It deliberately does **not** delete tables from an existing
Mnesia directory during application bootstrap. Automatic destructive migration
would be unsafe because an operator may still need to inspect or export old
state.

After upgrading and completing the full IAS regression suite, an operator may
inspect the local schema from an Erlang shell:

```erlang
mnesia:system_info(tables).
```

Only after confirming that the seven names above contain no required data may
they be removed explicitly:

```erlang
Legacy = [phone, field, close_account2, account, client, card, transaction].
[{Table, mnesia:delete_table(Table)} || Table <- Legacy,
                                         lists:member(Table,
                                                      mnesia:system_info(tables))].
```

This cleanup is optional. Leaving unused legacy tables in an old Mnesia
directory does not make them part of the IAS KVS schema and does not affect
startup or runtime behavior.
