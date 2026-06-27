-module(ias_kvs).
-export([metainfo/0,ias/0]).
-include("ias_vpn_authority.hrl").
-include("ias_vpn_reconciliation_incident.hrl").
-include("ias_vpn_orphan_resolution_operation.hrl").
-include("ias_vpn_orphan_recovery_operation.hrl").
-include("ias_domain_object.hrl").
-include("ias_provisioning_wizard_draft.hrl").
-include("ias_vpn_provisioning_delivery_audit.hrl").
-include("ias_csr_enrollment_record.hrl").
-include("ias_certificate_material_record.hrl").
-include_lib("kvs/include/metainfo.hrl").

metainfo() -> #schema { name = ias, tables = ias() }.

ias() ->
       [
        #table{name = ias_vpn_device_state,
               fields = record_info(fields, ias_vpn_device_state),
               instance = #ias_vpn_device_state{},
               type = set,
               copy_type = disc_copies},
        #table{name = ias_vpn_reconciliation_incident,
               fields = record_info(fields, ias_vpn_reconciliation_incident),
               instance = #ias_vpn_reconciliation_incident{},
               type = set,
               copy_type = disc_copies},
        #table{name = ias_vpn_orphan_resolution_operation,
               fields = record_info(fields, ias_vpn_orphan_resolution_operation),
               instance = #ias_vpn_orphan_resolution_operation{},
               type = set,
               copy_type = disc_copies},
        #table{name = ias_vpn_orphan_recovery_operation,
               fields = record_info(fields, ias_vpn_orphan_recovery_operation),
               instance = #ias_vpn_orphan_recovery_operation{},
               type = set,
               copy_type = disc_copies},
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
