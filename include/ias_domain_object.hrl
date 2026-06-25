-ifndef(IAS_DOMAIN_OBJECT_HRL).
-define(IAS_DOMAIN_OBJECT_HRL, true).

-record(ias_domain_object, {
    key,
    schema_version = 1,
    kind,
    object_id,
    payload = #{},
    revision = 1,
    created_at = 0,
    updated_at = 0
}).

-endif.
