-ifndef(IAS_CERTIFICATE_MATERIAL_RECORD_HRL).
-define(IAS_CERTIFICATE_MATERIAL_RECORD_HRL, true).

-record(ias_certificate_material_record, {
    key,
    schema_version = 1,
    subject_kind,
    subject_id,
    material_type,
    encoding = pem,
    source,
    fingerprint_sha256,
    body_envelope = #{},
    revision = 1,
    created_at = 0,
    updated_at = 0,
    expires_at = undefined
}).

-endif.
