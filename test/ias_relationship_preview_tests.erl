-module(ias_relationship_preview_tests).
-include_lib("eunit/include/eunit.hrl").

device_relationship_preview_test() ->
    {Device, Certificate, Service} = ovpn_objects(),
    Preview = ias_relationship_preview:preview(Device),

    ?assertEqual(not_linked, maps:get(related_certificate, Preview)),
    ?assertEqual(not_linked, maps:get(related_vpn_service, Preview)),
    ?assertEqual([maps:get(id, Certificate)], ids(maps:get(suggested_certificates, Preview))),
    ?assertEqual([maps:get(id, Service)], ids(maps:get(suggested_services, Preview))).

certificate_relationship_preview_test() ->
    {Device, Certificate, _Service} = ovpn_objects(),
    Preview = ias_relationship_preview:preview(Certificate),

    ?assertEqual(not_linked, maps:get(used_by_device, Preview)),
    ?assertEqual([maps:get(id, Device)], ids(maps:get(suggested_devices, Preview))).

vpn_service_relationship_preview_test() ->
    {Device, _Certificate, Service} = ovpn_objects(),
    Preview = ias_relationship_preview:preview(Service),

    ?assertEqual(not_linked, maps:get(used_by_device, Preview)),
    ?assertEqual([maps:get(id, Device)], ids(maps:get(suggested_devices, Preview))).

relationship_preview_creates_no_relationship_records_test() ->
    {Device, Certificate, Service} = ovpn_objects(),
    _ = ias_relationship_preview:preview(Device),
    _ = ias_relationship_preview:preview(Certificate),
    _ = ias_relationship_preview:preview(Service),

    RelationshipRecords = [Object || Object <- ias_demo_store:all(),
                                     maps:get(kind, Object, undefined) =:= relationship],
    ?assertEqual([], RelationshipRecords).

link_certificate_to_device_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_link_cert">>,
                                         common_name => <<"router-1">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"cert_link_device">>,
                                                  requested_cn => <<"router-1">>}),

    {ok, Relationship} = ias_relationship_link:create(uses_certificate,
                                                      maps:get(id, Device),
                                                      maps:get(id, Certificate)),

    ?assertEqual(relationship, maps:get(kind, Relationship)),
    ?assertEqual(uses_certificate, maps:get(relation_type, Relationship)),
    ?assertEqual(device, maps:get(source_kind, Relationship)),
    ?assertEqual(maps:get(id, Device), maps:get(source_id, Relationship)),
    ?assertEqual(certificate, maps:get(target_kind, Relationship)),
    ?assertEqual(maps:get(id, Certificate), maps:get(target_id, Relationship)),
    ?assertEqual(130, maps:get(score, Relationship)).

link_vpn_service_to_device_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_link_service">>,
                                         import_id => <<"service_import">>,
                                         endpoint => <<"example.com:1194">>}),
    Service = ias_demo_store:add_service(#{id => <<"service_link_device">>,
                                           import_id => <<"service_import">>,
                                           remote => <<"example.com:1194">>}),

    {ok, Relationship} = ias_relationship_link:create(uses_service,
                                                      maps:get(id, Service),
                                                      maps:get(id, Device)),

    ?assertEqual(relationship, maps:get(kind, Relationship)),
    ?assertEqual(uses_service, maps:get(relation_type, Relationship)),
    ?assertEqual(device, maps:get(source_kind, Relationship)),
    ?assertEqual(maps:get(id, Device), maps:get(source_id, Relationship)),
    ?assertEqual(vpn_service, maps:get(target_kind, Relationship)),
    ?assertEqual(maps:get(id, Service), maps:get(target_id, Relationship)),
    ?assert(maps:get(score, Relationship) > 0).

relationship_object_rendering_metadata_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_rel_detail">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"cert_rel_detail">>}),

    {ok, Relationship} = ias_relationship_link:create(uses_certificate,
                                                      maps:get(id, Device),
                                                      maps:get(id, Certificate)),
    {ok, Loaded} = ias_demo_store:get(maps:get(id, Relationship)),

    ?assertEqual(relationship, maps:get(kind, Loaded)),
    ?assertEqual(maps:get(relationship_id, Relationship), maps:get(relationship_id, Loaded)),
    ?assertEqual(uses_certificate, maps:get(relation_type, Loaded)),
    ?assertEqual(maps:get(id, Device), maps:get(source_id, Loaded)),
    ?assertEqual(maps:get(id, Certificate), maps:get(target_id, Loaded)).

clicking_link_twice_creates_one_relationship_only_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_duplicate_link">>,
                                         common_name => <<"router-1">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"cert_duplicate_link">>,
                                                  requested_cn => <<"router-1">>}),

    {ok, First} = ias_relationship_link:create(uses_certificate,
                                               maps:get(id, Device),
                                               maps:get(id, Certificate)),
    {ok, Second} = ias_relationship_link:create(uses_certificate,
                                                maps:get(id, Device),
                                                maps:get(id, Certificate)),

    ?assertEqual(maps:get(id, First), maps:get(id, Second)),
    ?assertEqual([maps:get(id, First)], ids(ias_demo_store:relationships())).

existing_relationship_is_detected_for_link_action_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_linked_action">>}),
    Service = ias_demo_store:add_service(#{id => <<"service_linked_action">>}),

    ?assertEqual(not_found,
                 ias_relationship_link:exists(uses_service,
                                              maps:get(id, Device),
                                              maps:get(id, Service))),
    {ok, Relationship} = ias_relationship_link:create(uses_service,
                                                      maps:get(id, Device),
                                                      maps:get(id, Service)),

    ?assertEqual(maps:get(id, Relationship),
                 maps:get(id, ias_relationship_link:exists(uses_service,
                                                           maps:get(id, Device),
                                                           maps:get(id, Service)))).

certificate_security_policy_is_singleton_test() ->
    ias_demo_store:clear(),
    Certificate = ias_demo_store:add_certificate(#{id => <<"cert_policy_singleton">>}),

    {ok, HighSecurity} = ias_relationship_link:create(uses_security_policy,
                                                      maps:get(id, Certificate),
                                                      <<"high_security">>),
    ?assertMatch({error, {already_has_policy, <<"high_security">>}},
                 ias_relationship_link:create(uses_security_policy,
                                              maps:get(id, Certificate),
                                              <<"standard">>)),
    ?assertMatch({already_has_policy, <<"high_security">>, _},
                 ias_relationship_link:status(uses_security_policy,
                                              maps:get(id, Certificate),
                                              <<"standard">>)),

    Relationships = security_policy_relationships_for(Certificate),
    ?assertEqual([maps:get(id, HighSecurity)], ids(Relationships)),
    ?assertEqual([<<"high_security">>], [maps:get(target_id, Relationship)
                                         || Relationship <- Relationships]).

same_security_policy_link_is_idempotent_test() ->
    ias_demo_store:clear(),
    Certificate = ias_demo_store:add_certificate(#{id => <<"cert_policy_idempotent">>}),

    {ok, First} = ias_relationship_link:create(uses_security_policy,
                                               maps:get(id, Certificate),
                                               <<"high_security">>),
    {ok, Second} = ias_relationship_link:create(uses_security_policy,
                                                maps:get(id, Certificate),
                                                <<"high_security">>),

    ?assertEqual(maps:get(id, First), maps:get(id, Second)),
    ?assertEqual([maps:get(id, First)], ids(security_policy_relationships_for(Certificate))).

security_policy_can_apply_to_many_certificates_test() ->
    ias_demo_store:clear(),
    Certificate1 = ias_demo_store:add_certificate(#{id => <<"cert_policy_many_1">>}),
    Certificate2 = ias_demo_store:add_certificate(#{id => <<"cert_policy_many_2">>}),

    {ok, Relationship1} = ias_relationship_link:create(uses_security_policy,
                                                       maps:get(id, Certificate1),
                                                       <<"high_security">>),
    {ok, Relationship2} = ias_relationship_link:create(uses_security_policy,
                                                       maps:get(id, Certificate2),
                                                       <<"high_security">>),

    ?assertEqual(lists:sort([maps:get(id, Relationship1), maps:get(id, Relationship2)]),
                 lists:sort(ids(security_policy_relationships()))),
    ?assertEqual(lists:sort([maps:get(id, Certificate1), maps:get(id, Certificate2)]),
                 lists:sort([maps:get(source_id, Relationship)
                             || Relationship <- security_policy_relationships()])).

no_duplicate_relationships_appear_in_device_detail_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_detail_duplicates">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"cert_detail_duplicates">>}),

    {ok, _First} = ias_relationship_link:create(uses_certificate,
                                                maps:get(id, Device),
                                                maps:get(id, Certificate)),
    {ok, _Second} = ias_relationship_link:create(uses_certificate,
                                                 maps:get(id, Certificate),
                                                 maps:get(id, Device)),

    Relationships = ias_relationship_link:relationships_for(Device),
    ?assertEqual(1, length(Relationships)),
    [Relationship] = Relationships,
    ?assertEqual(maps:get(id, Certificate), maps:get(target_id, Relationship)).

score_zero_candidates_are_excluded_from_suggested_test() ->
    Candidates = [
        #{id => <<"suggested">>, relationship_score => 20},
        #{id => <<"available">>, relationship_score => 0}
    ],

    ?assertEqual([<<"suggested">>],
                 ids(ias_relationship_preview:suggested_candidates(Candidates))),
    ?assertEqual([<<"available">>],
                 ids(ias_relationship_preview:available_candidates(Candidates))).

exact_cn_match_ranks_highest_test() ->
    ias_demo_store:clear(),
    Certificate = ias_demo_store:add_certificate(#{
        id => <<"cert_exact">>,
        import_id => <<"cert_flow">>,
        requested_cn => <<"router-1">>,
        enrollment_cn => <<"router-1-20260614-012345">>,
        subject => <<"CN=router-1-20260614-012345">>,
        source => cmp_demo_enrollment
    }),
    Exact = ias_demo_store:add_device(#{id => <<"device_exact">>,
                                        import_id => <<"device_flow">>,
                                        common_name => <<"router-1">>}),
    Prefix = ias_demo_store:add_device(#{id => <<"device_prefix">>,
                                         import_id => <<"device_flow">>,
                                         device_name => <<"router">>}),

    Preview = ias_relationship_preview:preview(Certificate),
    [First, Second | _] = maps:get(suggested_devices, Preview),

    ?assertEqual(maps:get(id, Exact), maps:get(id, First)),
    ?assertEqual(100, maps:get(relationship_score, First)),
    ?assertEqual(maps:get(id, Prefix), maps:get(id, Second)),
    ?assertEqual(50, maps:get(relationship_score, Second)).

prefix_match_ranks_below_exact_device_name_test() ->
    ias_demo_store:clear(),
    Certificate = ias_demo_store:add_certificate(#{
        id => <<"cert_prefix">>,
        import_id => <<"cert_flow">>,
        requested_cn => <<"vpn-client">>,
        enrollment_cn => <<"vpn-client-20260614-012345">>,
        source => cmp_demo_enrollment
    }),
    ExactDeviceName = ias_demo_store:add_device(#{id => <<"device_name_exact">>,
                                                 device_name => <<"vpn-client">>}),
    Prefix = ias_demo_store:add_device(#{id => <<"device_prefix">>,
                                         device_name => <<"vpn">>}),

    Preview = ias_relationship_preview:preview(Certificate),
    [First, Second | _] = maps:get(suggested_devices, Preview),

    ?assertEqual(maps:get(id, ExactDeviceName), maps:get(id, First)),
    ?assertEqual(80, maps:get(relationship_score, First)),
    ?assertEqual(maps:get(id, Prefix), maps:get(id, Second)),
    ?assertEqual(50, maps:get(relationship_score, Second)).

same_import_id_improves_ranking_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"device_import">>,
                                         import_id => <<"import_a">>}),
    SameImport = ias_demo_store:add_certificate(#{id => <<"cert_same_import">>,
                                                 import_id => <<"import_a">>}),
    Unrelated = ias_demo_store:add_certificate(#{id => <<"cert_unrelated">>,
                                                import_id => <<"import_b">>}),

    Preview = ias_relationship_preview:preview(Device),
    [First, Second | _] = maps:get(suggested_certificates, Preview),

    ?assertEqual(maps:get(id, SameImport), maps:get(id, First)),
    ?assert(maps:get(relationship_score, First) > maps:get(relationship_score, Second)),
    ?assertEqual(maps:get(id, Unrelated), maps:get(id, Second)).

unrelated_objects_are_ranked_lower_test() ->
    ias_demo_store:clear(),
    Certificate = ias_demo_store:add_certificate(#{id => <<"cert_unrelated_rank">>,
                                                  import_id => <<"cert_rank_flow">>,
                                                  source => cmp_demo_enrollment,
                                                  requested_cn => <<"router-1">>,
                                                  enrollment_cn => <<"router-1-20260614-012345">>}),
    Match = ias_demo_store:add_device(#{id => <<"device_match_rank">>,
                                        import_id => <<"device_match_flow">>,
                                        source => ovpn_demo_import,
                                        common_name => <<"router-1">>}),
    Unrelated = ias_demo_store:add_device(#{id => <<"device_unrelated_rank">>,
                                           import_id => <<"device_unrelated_flow">>,
                                           source => ovpn_demo_import,
                                           common_name => <<"other">>}),

    Preview = ias_relationship_preview:preview(Certificate),
    [First, Second | _] = maps:get(suggested_devices, Preview),

    ?assertEqual(maps:get(id, Match), maps:get(id, First)),
    ?assert(maps:get(relationship_score, First) > maps:get(relationship_score, Second)),
    ?assertEqual(maps:get(id, Unrelated), maps:get(id, Second)),
    ?assertEqual(0, maps:get(relationship_score, Second)).

ovpn_objects() ->
    ias_demo_store:clear(),
    {ok, OVPN} = file:read_file("test/fixtures/example.ovpn"),
    Preview = ias_ovpn_preview:analyze(OVPN),
    _ImportId = ias_demo_store:add_import(ias_ovpn_import:import_map(Preview)),
    [Device] = ias_demo_store:devices(),
    [Certificate] = ias_demo_store:certificates(),
    [Service] = ias_demo_store:services(),
    {Device, Certificate, Service}.

ids(Objects) ->
    [maps:get(id, Object) || Object <- Objects].

security_policy_relationships_for(Certificate) ->
    CertificateId = maps:get(id, Certificate),
    [Relationship || Relationship <- security_policy_relationships(),
                     maps:get(source_id, Relationship) =:= CertificateId].

security_policy_relationships() ->
    [Relationship || Relationship <- ias_demo_store:relationships(),
                     maps:get(relation_type, Relationship, undefined) =:= uses_security_policy,
                     maps:get(source_kind, Relationship, undefined) =:= certificate,
                     maps:get(target_kind, Relationship, undefined) =:= security_policy].
