-module(ias_certificate_replacement_tests).
-include_lib("eunit/include/eunit.hrl").

replacement_available_action_is_shown_test() ->
    ias_demo_store:clear(),
    #{device := Device, candidate := Candidate} = setup_replacement_graph(),
    verify_candidate(Candidate),

    Html = iolist_to_binary(nitro:render(ias_demo:certificate_lifecycle_preview(Device))),

    ?assertMatch({_, _}, binary:match(Html, <<"Replace Certificate">>)).

replacement_blocked_for_unverified_candidate_test() ->
    ias_demo_store:clear(),
    #{device := Device} = setup_replacement_graph(),

    ?assertEqual({error, candidate_certificate_not_verified},
                 ias_certificate_replacement:replace(maps:get(id, Device))),
    Html = iolist_to_binary(nitro:render(ias_demo:certificate_lifecycle_preview(Device))),

    ?assertMatch({_, _}, binary:match(Html, <<"Replacement blocked: candidate certificate is not verified">>)).

replacement_succeeds_for_verified_candidate_test() ->
    ias_demo_store:clear(),
    #{device := Device, candidate := Candidate} = setup_replacement_graph(),
    verify_candidate(Candidate),

    ?assertMatch({ok, #{kind := certificate_replacement}},
                 ias_certificate_replacement:replace(maps:get(id, Device))).

replacement_creates_audit_object_test() ->
    ias_demo_store:clear(),
    #{device := Device, current := Current, candidate := Candidate} = setup_replacement_graph(),
    verify_candidate(Candidate),

    {ok, Replacement} = ias_certificate_replacement:replace(maps:get(id, Device)),
    Relationships = ias_demo_store:relationships(),

    ?assertEqual(certificate_replacement, maps:get(kind, Replacement)),
    ?assertEqual(maps:get(id, Device), maps:get(device_id, Replacement)),
    ?assertEqual(maps:get(id, Current), maps:get(old_certificate_id, Replacement)),
    ?assertEqual(maps:get(id, Candidate), maps:get(new_certificate_id, Replacement)),
    ?assert(lists:any(edge(replaced_certificate_by, device, maps:get(id, Device),
                           certificate_replacement, maps:get(id, Replacement)), Relationships)),
    ?assert(lists:any(edge(old_certificate, certificate_replacement, maps:get(id, Replacement),
                           certificate, maps:get(id, Current)), Relationships)),
    ?assert(lists:any(edge(new_certificate, certificate_replacement, maps:get(id, Replacement),
                           certificate, maps:get(id, Candidate)), Relationships)).

replacement_sets_candidate_as_current_certificate_test() ->
    ias_demo_store:clear(),
    #{device := Device, current := Current, candidate := Candidate} = setup_replacement_graph(),
    verify_candidate(Candidate),

    {ok, _Replacement} = ias_certificate_replacement:replace(maps:get(id, Device)),
    Active = active_certificate_links(maps:get(id, Device)),
    Status = ias_certificate_role:device_status(Device),

    ?assertEqual([maps:get(id, Candidate)], Active),
    ?assertEqual(maps:get(id, Candidate),
                 maps:get(id, maps:get(current_certificate, Status))),
    ?assertNot(lists:member(maps:get(id, Current), Active)).

replacement_preserves_old_certificate_history_test() ->
    ias_demo_store:clear(),
    #{device := Device, current := Current, candidate := Candidate} = setup_replacement_graph(),
    verify_candidate(Candidate),

    {ok, Replacement} = ias_certificate_replacement:replace(maps:get(id, Device)),

    ?assertMatch({ok, #{kind := certificate}}, ias_demo_store:get(maps:get(id, Current))),
    ?assert(lists:any(edge(old_certificate, certificate_replacement, maps:get(id, Replacement),
                           certificate, maps:get(id, Current)),
                      ias_demo_store:relationships())).

replacement_updates_graph_analysis_test() ->
    ias_demo_store:clear(),
    #{device := Device, candidate := Candidate} = setup_replacement_graph(),
    verify_candidate(Candidate),
    Before = ias_graph_analysis:report(),

    {ok, _Replacement} = ias_certificate_replacement:replace(maps:get(id, Device)),
    After = ias_graph_analysis:report(),

    ?assertEqual(1, length(maps:get(devices_with_replacement_available, Before))),
    ?assertEqual(0, length(maps:get(devices_with_replacement_available, After))).

replacement_snapshot_roundtrip_test() ->
    ias_demo_store:clear(),
    #{device := Device, candidate := Candidate} = setup_replacement_graph(),
    verify_candidate(Candidate),
    {ok, Replacement} = ias_certificate_replacement:replace(maps:get(id, Device)),
    Term = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    Result = ias_demo_state:import(Term),

    ?assertMatch({ok, #{kind := certificate_replacement}}, ias_demo_store:get(maps:get(id, Replacement))),
    ?assert(maps:get(imported_objects, Result) >= 4),
    ?assert(lists:any(edge(replaced_certificate_by, device, maps:get(id, Device),
                           certificate_replacement, maps:get(id, Replacement)),
                      ias_demo_store:relationships())),
    ?assertEqual([], maps:get(broken, ias_relationship_graph:categorized_relationships())).

replacement_relationships_are_protected_test() ->
    ias_demo_store:clear(),
    #{device := Device, candidate := Candidate} = setup_replacement_graph(),
    verify_candidate(Candidate),
    {ok, Replacement} = ias_certificate_replacement:replace(maps:get(id, Device)),
    ReplacementRelationships = [Relationship || Relationship <- ias_demo_store:relationships(),
                                                lists:member(maps:get(relation_type, Relationship, undefined),
                                                             [replaced_certificate_by,
                                                              old_certificate,
                                                              new_certificate])],

    ?assertEqual(3, length(ReplacementRelationships)),
    [?assertEqual(false, ias_relationship_link:unlinkable(Relationship))
     || Relationship <- ReplacementRelationships],
    [?assertEqual({error, protected_relationship},
                  ias_relationship_link:unlink(maps:get(id, Relationship)))
     || Relationship <- ReplacementRelationships],
    ?assertMatch({ok, #{kind := certificate_replacement}}, ias_demo_store:get(maps:get(id, Replacement))).

setup_replacement_graph() ->
    Device = ias_demo_store:add_device(#{
        id => <<"replace_device">>,
        import_id => <<"replace_import">>,
        source => ovpn_demo_import,
        type => <<"vpn-client">>,
        endpoint => <<"example.com:1194">>
    }),
    Current = ias_demo_store:add_certificate(#{
        id => <<"replace_current_certificate">>,
        import_id => <<"replace_import">>,
        source => ovpn_demo_import,
        ca_present => true,
        private_key_stored => false,
        certificate_body_stored => false
    }),
    Candidate = ias_demo_store:add_certificate(#{
        id => <<"replace_candidate_certificate">>,
        import_id => <<"replace_enrollment">>,
        source => cmp_demo_enrollment,
        subject => <<"CN=vpn-client-20260616">>,
        requested_cn => <<"vpn-client">>,
        enrollment_cn => <<"vpn-client-20260616">>,
        private_key_stored => false,
        certificate_body_stored => false
    }),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, Device),
                                           maps:get(id, Current)),
    #{device => Device,
      current => Current,
      candidate => Candidate}.

verify_candidate(Candidate) ->
    {ok, Verification} = ias_certificate_verification:verify(
        Candidate#{certificate_id => maps:get(id, Candidate),
                   subject_cn => maps:get(subject, Candidate, maps:get(id, Candidate)),
                   issuer_cn => <<"Zencrypted Dev CA">>,
                   profile => administrator_profile(),
                   profile_id => administrator,
                   claims => #{role => admin,
                               services => [vpn, ias],
                               attributes => [admin, issue_certificates, revoke_certificates],
                               trust_level => elevated},
                   trusted => true,
                   key_match => true}),
    Verification.

administrator_profile() ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile, undefined) =:= administrator],
    Profile.

active_certificate_links(DeviceId) ->
    [maps:get(target_id, Relationship, undefined)
     || Relationship <- ias_demo_store:relationships(),
        maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
        maps:get(source_kind, Relationship, undefined) =:= device,
        maps:get(source_id, Relationship, undefined) =:= DeviceId,
        maps:get(target_kind, Relationship, undefined) =:= certificate].

edge(RelationType, SourceKind, SourceId, TargetKind, TargetId) ->
    fun(Relationship) ->
        maps:get(relation_type, Relationship, undefined) =:= RelationType andalso
            maps:get(source_kind, Relationship, undefined) =:= SourceKind andalso
            maps:get(source_id, Relationship, undefined) =:= SourceId andalso
            maps:get(target_kind, Relationship, undefined) =:= TargetKind andalso
            maps:get(target_id, Relationship, undefined) =:= TargetId
    end.
