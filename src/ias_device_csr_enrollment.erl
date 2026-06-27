-module(ias_device_csr_enrollment).
-export([enroll_for_wizard/2,
         enroll_for_wizard/3,
         enroll_for_wizard_with/3,
         enroll_for_wizard_with/4,
         complete_for_wizard/3,
         import_issued_certificate/3,
         import_issued_certificate/4,
         normalize_cmp_error/1]).

enroll_for_wizard(WizardId, CsrPem) ->
    PendingKeyRef = pending_key_ref(WizardId),
    enroll_for_wizard(WizardId, CsrPem, PendingKeyRef).

enroll_for_wizard(WizardId, CsrPem, PrivateKeyRef) ->
    enroll_for_wizard_with(WizardId, CsrPem, PrivateKeyRef,
                           fun(Request) -> ias_cmp_enrollment:enroll_external_csr(Request) end).

enroll_for_wizard_with(WizardId, CsrPem, CmpFun) when is_function(CmpFun, 1) ->
    PendingKeyRef = pending_key_ref(WizardId),
    enroll_for_wizard_with(WizardId, CsrPem, PendingKeyRef, CmpFun).

enroll_for_wizard_with(WizardId, CsrPem, PrivateKeyRef, CmpFun) when is_function(CmpFun, 1) ->
    case ias_provisioning_wizard_store:get(WizardId) of
        {ok, Draft} ->
            case ias_provisioning_wizard_store:selected_device(Draft) of
                {ok, Device} ->
                    enroll_for_device(WizardId, Device, CsrPem, PrivateKeyRef, CmpFun);
                _ ->
                    {error, device_required}
            end;
        not_found ->
            {error, wizard_not_found}
    end.

pending_key_ref(WizardId) ->
    case ias_provisioning_wizard_store:get(WizardId) of
        {ok, Draft} -> maps:get(pending_private_key_reference, Draft, undefined);
        not_found -> undefined
    end.

enroll_for_device(WizardId, Device, CsrPem, PrivateKeyRef0, CmpFun) ->
    case ias_csr_validation:validate(CsrPem) of
        {ok, CsrMetadata} ->
            case validate_private_key_ref(PrivateKeyRef0) of
                {ok, PrivateKeyRef} ->
                    enroll_validated_csr(WizardId, Device, CsrMetadata, PrivateKeyRef, CmpFun);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

validate_private_key_ref(undefined) ->
    {error, private_key_reference_required};
validate_private_key_ref(<<>>) ->
    {error, private_key_reference_required};
validate_private_key_ref(PrivateKeyRef0) ->
    case ias_device_key_ref:validate(<<"device_file">>, PrivateKeyRef0) of
        {ok, #{private_key_ref := PrivateKeyRef}} -> {ok, PrivateKeyRef};
        {error, Reason} -> {error, {invalid_private_key_reference, Reason}}
    end.

enroll_validated_csr(WizardId, Device, CsrMetadata, PrivateKeyRef, CmpFun) ->
    Fingerprint = maps:get(csr_fingerprint, CsrMetadata),
    DeviceId = maps:get(id, Device, undefined),
    PublicKeyFingerprint = maps:get(public_key_fingerprint, CsrMetadata),
    case ias_csr_enrollment_state:submitted(Fingerprint) of
        ok ->
            case ias_csr_enrollment_state:public_key_available(DeviceId, PublicKeyFingerprint) of
                ok ->
                    submit_unique_csr(WizardId, Device, CsrMetadata, PrivateKeyRef, CmpFun);
                {error, {reused_public_key, Record}} ->
                    {error, {reused_public_key, Record}}
            end;
        {error, {duplicate_csr, Record}} ->
            {error, {duplicate_csr, Record}}
    end.

submit_unique_csr(WizardId, Device, CsrMetadata, PrivateKeyRef, CmpFun) ->
    Fingerprint = maps:get(csr_fingerprint, CsrMetadata),
    DeviceId = maps:get(id, Device, undefined),
    Metadata = #{wizard_id => ias_html:text(WizardId),
                 device_id => ias_html:text(DeviceId),
                 subject_cn => maps:get(subject_cn, CsrMetadata, <<"vpn-client">>),
                 public_key_fingerprint => maps:get(public_key_fingerprint, CsrMetadata),
                 private_key_reference => PrivateKeyRef,
                 key_rotation => new_key_pair},
    {ok, _} = ias_csr_enrollment_state:mark_submitted(Fingerprint, Metadata),
    Request = #{csr_pem => maps:get(pem, CsrMetadata),
                common_name => maps:get(subject_cn, CsrMetadata, <<"vpn-client">>),
                profile => <<"secp384r1">>,
                server => <<"127.0.0.1:8829">>},
    case CmpFun(Request) of
        {ok, CmpResult} ->
            case complete_for_wizard(WizardId, Device, CsrMetadata, CmpResult, PrivateKeyRef) of
                {ok, Draft, Certificate} ->
                    ias_csr_enrollment_state:mark_issued(
                        Fingerprint,
                        #{certificate_id => maps:get(id, Certificate, undefined)}),
                    {ok, Draft, Certificate};
                {error, Reason} ->
                    ias_csr_enrollment_state:mark_failed(
                        Fingerprint, enrollment_failure_label(Reason), false),
                    {error, Reason}
            end;
        {error, Reason0} ->
            Reason = normalize_cmp_error(Reason0),
            ias_csr_enrollment_state:mark_failed(
                Fingerprint, Reason, retryable_cmp_error(Reason)),
            {error, {cmp_failed, Reason}}
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
    complete_for_wizard(WizardId, Device, CsrMetadata, CmpResult, pending_key_ref(WizardId)).

complete_for_wizard(WizardId, Device, CsrMetadata, CmpResult, PrivateKeyRef) ->
    DeviceId = maps:get(id, Device),
    case import_issued_certificate(DeviceId, CsrMetadata, CmpResult, PrivateKeyRef) of
        {ok, Certificate} ->
            case update_device_key_reference(DeviceId, PrivateKeyRef) of
                {ok, _Device} ->
                    case ias_provisioning_wizard_store:select_existing_client_certificate(
                           WizardId, maps:get(id, Certificate)) of
                        {ok, Updated0} ->
                            {ok, Updated} = ias_provisioning_wizard_store:update(
                                maps:get(id, Updated0), clear_pending_key_rotation()),
                            {ok, Updated, Certificate};
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

update_device_key_reference(_DeviceId, undefined) ->
    {error, private_key_reference_required};
update_device_key_reference(DeviceId, PrivateKeyRef) ->
    ias_device_key_ref:update(DeviceId, #{private_key_provider => <<"device_file">>,
                                          private_key_ref => PrivateKeyRef}).

clear_pending_key_rotation() ->
    #{pending_private_key_reference => undefined,
      pending_csr_filename => undefined,
      pending_enrollment_common_name => undefined}.

normalize_cmp_error(ca_unavailable) ->
    cmp_connection_failed;
normalize_cmp_error(timeout) ->
    cmp_timeout;
normalize_cmp_error(Reason) ->
    Text = string:lowercase(ias_html:text(Reason)),
    case contains_any(Text, [<<"certresponse not found">>, <<"expected certreqid">>]) of
        true -> cmp_unexpected_certificate_response;
        false -> normalize_cmp_error_text(Text)
    end.

normalize_cmp_error_text(Text) ->
    case contains_any(Text, [<<"timed out">>, <<"timeout">>]) of
        true -> cmp_timeout;
        false ->
            case contains_any(Text, [<<"connection refused">>, <<"connect">>,
                                     <<"network is unreachable">>, <<"ca unavailable">>]) of
                true -> cmp_connection_failed;
                false ->
                    case contains_any(Text, [<<"malformed">>, <<"bad response">>, <<"parse">>]) of
                        true -> cmp_malformed_response;
                        false ->
                            case contains_any(Text, [<<"rejection">>, <<"rejected">>,
                                                     <<"pkistatus">>, <<"bad request">>]) of
                                true -> cmp_ca_rejection;
                                false -> cmp_failed
                            end
                    end
            end
    end.

contains_any(Text, Needles) ->
    lists:any(fun(Needle) -> binary:match(Text, Needle) =/= nomatch end, Needles).

retryable_cmp_error(cmp_connection_failed) -> true;
retryable_cmp_error(cmp_timeout) -> true;
retryable_cmp_error(_) -> false.

enrollment_failure_label({invalid_certificate_chain, _Reason}) -> invalid_certificate_chain;
enrollment_failure_label({configured_ca_unavailable, _Reason}) -> configured_ca_unavailable;
enrollment_failure_label(Reason) -> ias_html:text(Reason).

import_issued_certificate(DeviceId, CsrMetadata, CmpResult) ->
    import_issued_certificate(DeviceId, CsrMetadata, CmpResult, undefined).

import_issued_certificate(DeviceId, CsrMetadata, CmpResult, PrivateKeyRef) ->
    CertPem = maps:get(certificate_pem, CmpResult, <<>>),
    case validate_issued_certificate(CsrMetadata, CertPem) of
        {ok, CertMetadata} ->
            store_issued_certificate(DeviceId, CsrMetadata, CmpResult, CertMetadata,
                                     PrivateKeyRef);
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
            case ias_certificate_material:get(maps:get(id, CaCertificate),
                                              certificate_chain_validation) of
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

store_issued_certificate(DeviceId, CsrMetadata, CmpResult, CertMetadata, PrivateKeyRef) ->
    EnrollmentId = ias_demo_store:add_enrollment_result(enrollment_result(
        DeviceId, CsrMetadata, CmpResult, CertMetadata, PrivateKeyRef)),
    case ias_certificate_material:stage_cmp(EnrollmentId,
                                            maps:get(certificate_pem, CmpResult)) of
        {ok, _Staged} ->
            case ias_cert_enrollment_import:import(EnrollmentId) of
                {ok, Certificate0} ->
                    Certificate = enrich_certificate(Certificate0, DeviceId, EnrollmentId,
                                                     CsrMetadata, CertMetadata, PrivateKeyRef),
                    Stored = ias_demo_store:put_runtime_object(Certificate),
                    {ok, Stored};
                not_found ->
                    {error, enrollment_import_failed}
            end;
        {error, Reason} ->
            ias_demo_store:delete_runtime_object(cmp_enrollment_result, EnrollmentId),
            {error, {material_store_failed, Reason}}
    end.

enrollment_result(DeviceId, CsrMetadata, CmpResult, CertMetadata, PrivateKeyRef) ->
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
      certificate_public_key_fingerprint => maps:get(public_key_fingerprint, CertMetadata),
      private_key_reference => maybe_text(PrivateKeyRef),
      key_rotation => new_key_pair,
      issued_via => cmp,
      public_key_fingerprint => maps:get(public_key_fingerprint, CertMetadata)}.

enrich_certificate(Certificate, DeviceId, EnrollmentId, CsrMetadata, CertMetadata, PrivateKeyRef) ->
    maps:merge(Certificate, #{
        certificate_role => client_certificate,
        material_type => client_certificate,
        certificate_status => trusted,
        device_id => ias_html:text(DeviceId),
        enrollment_id => ias_html:text(EnrollmentId),
        csr_fingerprint => maps:get(csr_fingerprint, CsrMetadata),
        csr_public_key_fingerprint => maps:get(public_key_fingerprint, CsrMetadata),
        certificate_public_key_fingerprint => maps:get(public_key_fingerprint, CertMetadata),
        private_key_reference => maybe_text(PrivateKeyRef),
        key_rotation => new_key_pair,
        public_key_fingerprint => maps:get(public_key_fingerprint, CertMetadata),
        issued_via => cmp,
        private_key_stored => false,
        certificate_body_stored => false
    }).

maybe_text(undefined) -> undefined;
maybe_text(Value) -> ias_html:text(Value).
