-module(ias_kvs_schema_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kvs/include/metainfo.hrl").

schema_contains_only_ias_tables_test() ->
    ?assertEqual(
       [ias_vpn_device_state,
        ias_vpn_reconciliation_incident,
        ias_vpn_orphan_resolution_operation,
        ias_vpn_orphan_recovery_operation,
        ias_domain_object,
        ias_provisioning_wizard_draft,
        ias_vpn_provisioning_delivery_audit,
        ias_csr_enrollment_record,
        ias_certificate_material_record],
       [Table#table.name || Table <- ias_kvs:ias()]).

legacy_fin_tables_are_not_registered_test() ->
    Names = [Table#table.name || Table <- ias_kvs:ias()],
    Legacy = [phone, field, close_account2, account, client, card, transaction],
    ?assertEqual([], [Name || Name <- Legacy, lists:member(Name, Names)]).
