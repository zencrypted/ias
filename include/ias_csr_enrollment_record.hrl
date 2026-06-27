-ifndef(IAS_CSR_ENROLLMENT_RECORD_HRL).
-define(IAS_CSR_ENROLLMENT_RECORD_HRL, true).

-record(ias_csr_enrollment_record, {
    csr_fingerprint,
    schema_version = 1,
    status = submitted,
    retryable = false,
    payload = #{},
    revision = 1,
    created_at = 0,
    updated_at = 0
}).

-endif.
