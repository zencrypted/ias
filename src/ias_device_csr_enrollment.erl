-module(ias_device_csr_enrollment).
-export([enroll_for_wizard/2, complete_for_wizard/3, import_issued_certificate/3]).

enroll_for_wizard(WizardId, CsrPem) ->
    case ias_provisioning_wizard_store:get(WizardId) of
        {ok, Draft} ->
            case ias_provisioning_wizard_store:selected_device(Draft) of
                {ok, Device} ->
                    enroll_for_device(WizardId, Device, CsrPem);
                _ ->
                    {error, device_required}
            end;
        not_found ->
            {error, wizard_not_found}
    end.

enroll_for_device(WizardId, Device, CsrPem) ->
    case ias_csr_validation:validate(CsrPem) of
        {ok, CsrMetadata} ->
            Request = #{csr_pem => maps:get(pem, CsrMetadata),
                        common_name => maps:get(subject_cn, CsrMetadata, <<"vpn-client">>),
                        profile => <<"secp384r1">>,
                        server => <<"127.0.0.1:8829">>},
            case ias_cmp_enrollment:enroll_external_csr(Request) of
                {ok, CmpResult} ->
                    complete_for_wizard(WizardId, Device, CsrMetadata, CmpResult);
                {error, Reason} ->
                    {error, {cmp_failed, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

complete_for_wizard(WizardId, CsrPem, CmpResult) ->
    case ias_provisioning_wizard_store:get(WizardId) of
        {ok, Draft} ->
            case ias_provisioning_wizard_store:selected_device(Draft) of
                {ok, Device} ->
                    case ias_csr_validation:validate(CsrPem) of
                        {ok, CsrMetadata} ->
                            complete_for_wizard(WizardId, Device, CsrMetadata, CmpResult);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                _ ->
                    {error, device_required}
            end;
        not_found ->
            {error, wizard_not_found}
    end.

complete_for_wizard(WizardId, Device, CsrMetadata, CmpResult) ->
    case import_issued_certificate(maps:get(id, Device), CsrMetadata, CmpResult) of
        {ok, Certificate} ->
            case ias_provisioning_wizard_store:select_existing_client_certificate(
                   WizardId, maps:get(id, Certificate)) of
                {ok, Updated} -> {ok, Updated, Certificate};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

import_issued_certificate(DeviceId, CsrMetadata, CmpResult) ->
    CertPem = maps:get(certificate_pem, CmpResult, <<>>),
    case validate_issued_certificate(CsrMetadata, CertPem) of
        {ok, CertMetadata} ->
            store_issued_certificate(DeviceId, CsrMetadata, CmpResult, CertMetadata);
        {error, Reason} ->
            {error, Reason}
    end.

validate_issued_certificate(CsrMetadata, CertPem) ->
    case ias_x509_validation:validate_certificate(client_certificate, CertPem) of
        {ok, CertMetadata} ->
            case matching_public_key(CsrMetadata, CertMetadata) of
                ok -> validate_chain(CertPem, CertMetadata);
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

matching_public_key(CsrMetadata, CertMetadata) ->
    CsrFingerprint = maps:get(public_key_fingerprint, CsrMetadata, undefined),
    CertFingerprint = maps:get(public_key_fingerprint, CertMetadata, undefined),
    case CsrFingerprint =/= undefined andalso CsrFingerprint =:= CertFingerprint of
        true -> ok;
        false -> {error, certificate_csr_public_key_mismatch}
    end.

validate_chain(CertPem, CertMetadata) ->
    case ias_configured_ca_trust_anchor:load() of
        {ok, CaCertificate} ->
            case ias_certificate_material:get(maps:get(id, CaCertificate)) of
                {ok, #{body := CaPem}} ->
                    case ias_x509_validation:validate_pair(CaPem, CertPem) of
                        {ok, _PairMetadata} -> {ok, CertMetadata};
                        {error, Reason} -> {error, {invalid_certificate_chain, Reason}}
                    end;
                _ ->
                    {error, configured_ca_material_missing}
            end;
        {error, Reason} ->
            {error, {configured_ca_unavailable, Reason}}
    end.

store_issued_certificate(DeviceId, CsrMetadata, CmpResult, CertMetadata) ->
    EnrollmentId = ias_demo_store:add_enrollment_result(enrollment_result(
        DeviceId, CsrMetadata, CmpResult, CertMetadata)),
    case ias_certificate_material:stage_cmp(EnrollmentId,
                                            maps:get(certificate_pem, CmpResult)) of
        {ok, _Staged} ->
            case ias_cert_enrollment_import:import(EnrollmentId) of
                {ok, Certificate0} ->
                    Certificate = enrich_certificate(Certificate0, DeviceId, EnrollmentId,
                                                     CsrMetadata, CertMetadata),
                    Stored = ias_demo_store:put_runtime_object(Certificate),
                    {ok, Stored};
                not_found ->
                    {error, enrollment_import_failed}
            end;
        {error, Reason} ->
            ias_demo_store:delete_runtime_object(cmp_enrollment_result, EnrollmentId),
            {error, {material_store_failed, Reason}}
    end.

enrollment_result(DeviceId, CsrMetadata, CmpResult, CertMetadata) ->
    #{subject => maps:get(subject, CertMetadata, maps:get(subject, CmpResult, <<"not found">>)),
      issuer => maps:get(issuer, CertMetadata, maps:get(issuer, CmpResult, <<"not found">>)),
      not_before => maps:get(not_before, CertMetadata, maps:get(not_before, CmpResult, <<"not found">>)),
      not_after => maps:get(not_after, CertMetadata, maps:get(not_after, CmpResult, <<"not found">>)),
      requested_cn => maps:get(subject_cn, CsrMetadata, <<"not found">>),
      enrollment_cn => maps:get(subject_cn, CsrMetadata, <<"not found">>),
      profile => maps:get(profile, CmpResult, <<"secp384r1">>),
      cmp_server => maps:get(cmp_server, CmpResult, <<"127.0.0.1:8829">>),
      device_id => ias_html:text(DeviceId),
      csr_fingerprint => maps:get(csr_fingerprint, CsrMetadata),
      csr_public_key_fingerprint => maps:get(public_key_fingerprint, CsrMetadata),
      issued_via => cmp,
      public_key_fingerprint => maps:get(public_key_fingerprint, CertMetadata)}.

enrich_certificate(Certificate, DeviceId, EnrollmentId, CsrMetadata, CertMetadata) ->
    maps:merge(Certificate, #{
        certificate_role => client_certificate,
        material_type => client_certificate,
        certificate_status => trusted,
        device_id => ias_html:text(DeviceId),
        enrollment_id => ias_html:text(EnrollmentId),
        csr_fingerprint => maps:get(csr_fingerprint, CsrMetadata),
        csr_public_key_fingerprint => maps:get(public_key_fingerprint, CsrMetadata),
        public_key_fingerprint => maps:get(public_key_fingerprint, CertMetadata),
        issued_via => cmp,
        private_key_stored => false,
        certificate_body_stored => false
    }).
