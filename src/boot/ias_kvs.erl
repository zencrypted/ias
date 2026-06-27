-module(ias_kvs).
-export([metainfo/0,ias/0]).
-include("bank/phone.hrl").
-include("bank/account.hrl").
-include("ent.hrl").
-include("ias_vpn_authority.hrl").
-include("ias_vpn_reconciliation_incident.hrl").
-include("ias_domain_object.hrl").
-include("ias_provisioning_wizard_draft.hrl").
-include("ias_vpn_provisioning_delivery_audit.hrl").
-include("ias_csr_enrollment_record.hrl").
-include("ias_certificate_material_record.hrl").
-include_lib("kvs/include/metainfo.hrl").
-include_lib("form/include/meta.hrl").

metainfo() -> #schema { name = ias, tables = ias() }.

ias() ->
       [
        #table{name = phone,         fields=record_info(fields, phone), instance = #phone{} },
        #table{name = field,         fields=record_info(fields, field), instance = #field{} },
        #table{name = close_account2,fields=record_info(fields, close_account2), instance = #close_account2{} },
        #table{name = 'account',     fields=record_info(fields, account), instance = #account{} },
        #table{name = 'client',      fields=record_info(fields, client), instance = #client{}},
        #table{name = 'card',        fields=record_info(fields, card), instance = #card{}},
        #table{name = 'transaction', fields=record_info(fields, transaction), instance = #transaction{}},
        #table{name = ias_vpn_device_state,
               fields = record_info(fields, ias_vpn_device_state),
               instance = #ias_vpn_device_state{}},
        #table{name = ias_vpn_reconciliation_incident,
               fields = record_info(fields, ias_vpn_reconciliation_incident),
               instance = #ias_vpn_reconciliation_incident{}},
        #table{name = ias_domain_object,
               fields = record_info(fields, ias_domain_object),
               instance = #ias_domain_object{}},
        #table{name = ias_provisioning_wizard_draft,
               fields = record_info(fields, ias_provisioning_wizard_draft),
               instance = #ias_provisioning_wizard_draft{},
               type = set,
               copy_type = disc_copies},
        #table{name = ias_vpn_provisioning_delivery_audit,
               fields = record_info(fields, ias_vpn_provisioning_delivery_audit),
               instance = #ias_vpn_provisioning_delivery_audit{},
               type = set,
               copy_type = disc_copies},
        #table{name = ias_csr_enrollment_record,
               fields = record_info(fields, ias_csr_enrollment_record),
               instance = #ias_csr_enrollment_record{},
               type = set,
               copy_type = disc_copies},
        #table{name = ias_certificate_material_record,
               fields = record_info(fields, ias_certificate_material_record),
               instance = #ias_certificate_material_record{},
               type = set,
               copy_type = disc_copies}
    ].
