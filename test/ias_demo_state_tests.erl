-module(ias_demo_state_tests).
-include_lib("eunit/include/eunit.hrl").

export_demo_state_roundtrip_test() ->
    ias_demo_store:clear(),
    setup_demo_graph(),
    BeforeCategories = ias_relationship_graph:categorized_relationships(),
    BeforeAnalysis = warning_counts(ias_graph_analysis:report()),
    Term = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    ?assertEqual(0, maps:get(total_records, ias_demo_state:summary())),

    Result = ias_demo_state:import(Term),
    AfterCategories = ias_relationship_graph:categorized_relationships(),
    AfterAnalysis = warning_counts(ias_graph_analysis:report()),

    ?assertEqual(3, maps:get(imported_objects, Result)),
    ?assertEqual(2, maps:get(imported_relationships, Result)),
    ?assertEqual(0, maps:get(skipped_invalid_records, Result)),
    ?assertEqual(length(maps:get(known, BeforeCategories)),
                 length(maps:get(known, AfterCategories))),
    ?assertEqual([], maps:get(unknown, AfterCategories)),
    ?assertEqual([], maps:get(broken, AfterCategories)),
    ?assertEqual(BeforeAnalysis, AfterAnalysis).

clear_demo_state_test() ->
    ias_demo_store:clear(),
    setup_demo_graph(),

    ok = ias_demo_state:clear(),

    ?assertEqual(0, maps:get(total_records, ias_demo_state:summary())),
    ?assertEqual([], ias_demo_store:relationships()),
    ?assertMatch([_ | _], ias_demo_store:users()).

import_demo_state_restores_relationships_test() ->
    ias_demo_store:clear(),
    #{device := Device, certificate := Certificate} = setup_demo_graph(),
    Term = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    Result = ias_demo_state:import(Term),

    ?assertEqual(2, maps:get(imported_relationships, Result)),
    ?assert(lists:any(fun(Relationship) ->
        maps:get(relation_type, Relationship) =:= uses_certificate andalso
        maps:get(source_id, Relationship) =:= maps:get(id, Device) andalso
        maps:get(target_id, Relationship) =:= maps:get(id, Certificate)
    end, ias_demo_store:relationships())),
    ?assertEqual([], maps:get(broken, ias_relationship_graph:categorized_relationships())).

import_demo_state_rejects_malformed_snapshot_test() ->
    ias_demo_store:clear(),

    ?assertEqual({error, malformed_snapshot}, ias_demo_state:import(<<"{not-term">>)),
    ?assertEqual({error, invalid_snapshot_format},
                 ias_demo_state:import(<<"#{format => wrong, objects => [], relationships => []}.">>)),
    ?assertEqual(0, maps:get(total_records, ias_demo_state:summary())).

export_demo_state_does_not_export_private_material_test() ->
    ias_demo_store:clear(),
    _Certificate = ias_demo_store:add_certificate(#{
        id => <<"secret_certificate">>,
        source => certificate_issue_demo,
        private_key_body => <<"PRIVATE-KEY-BODY">>,
        certificate_pem => <<"CERTIFICATE-PEM-BODY">>,
        ca_body => <<"CA-CERTIFICATE-BODY">>,
        csr_body => <<"CSR-BODY">>,
        private_key_stored => true,
        certificate_body_stored => true
    }),

    Term = ias_demo_state:export(),
    {ok, Tokens, _} = erl_scan:string(binary_to_list(Term)),
    {ok, Snapshot} = erl_parse:parse_term(Tokens),
    [Exported] = maps:get(objects, Snapshot),

    ?assertEqual(nomatch, binary:match(Term, <<"PRIVATE-KEY-BODY">>)),
    ?assertEqual(nomatch, binary:match(Term, <<"CERTIFICATE-PEM-BODY">>)),
    ?assertEqual(nomatch, binary:match(Term, <<"CA-CERTIFICATE-BODY">>)),
    ?assertEqual(nomatch, binary:match(Term, <<"CSR-BODY">>)),
    ?assertEqual(false, maps:get(private_key_stored, Exported)),
    ?assertEqual(false, maps:get(certificate_body_stored, Exported)).

demo_state_export_includes_verification_objects_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_demo_graph(),
    {ok, Verification} = ias_certificate_verification:verify(verification_certificate(Certificate)),

    Snapshot = decode_snapshot(ias_demo_state:export()),
    Objects = maps:get(objects, Snapshot),
    [ExportedVerification] = [Object || Object <- Objects,
                                        maps:get(kind, Object, undefined) =:= verification],

    ?assertEqual(maps:get(id, Verification), maps:get(id, ExportedVerification)),
    ?assertEqual(maps:get(id, Certificate), maps:get(certificate_id, ExportedVerification)),
    ?assertEqual(maps:get(id, Certificate), maps:get(certificate_subject, ExportedVerification)),
    ?assertEqual(verified, maps:get(verification_status, ExportedVerification)),
    ?assertEqual(allow, maps:get(authorization_status, ExportedVerification)),
    ?assertEqual(administrator, maps:get(resolved_profile, ExportedVerification)),
    ?assertEqual(<<"high_security">>, maps:get(resolved_policy, ExportedVerification)),
    ?assertEqual(true, maps:get(trusted, ExportedVerification)),
    ?assertEqual(true, maps:get(key_match, ExportedVerification)),
    ?assertEqual(verification_demo, maps:get(source, ExportedVerification)),
    ?assert(maps:is_key(created_at, ExportedVerification)).

demo_state_import_restores_verification_objects_test() ->
    ias_demo_store:clear(),
    #{certificate := Certificate} = setup_demo_graph(),
    {ok, Verification} = ias_certificate_verification:verify(verification_certificate(Certificate)),
    BeforeAnalysis = warning_counts(ias_graph_analysis:report()),
    Term = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    Result = ias_demo_state:import(Term),
    AfterAnalysis = warning_counts(ias_graph_analysis:report()),

    ?assertEqual(BeforeAnalysis, AfterAnalysis),
    ?assertMatch({ok, #{kind := verification}}, ias_demo_store:get(maps:get(id, Verification))),
    ?assert(lists:any(fun(Relationship) ->
        maps:get(relation_type, Relationship, undefined) =:= verified_by andalso
            maps:get(source_id, Relationship, undefined) =:= maps:get(id, Certificate) andalso
            maps:get(target_id, Relationship, undefined) =:= maps:get(id, Verification)
    end, ias_demo_store:relationships())),
    ?assert(maps:get(imported_objects, Result) >= 4),
    ?assert(maps:get(imported_relationships, Result) >= 4).

import_demo_state_sanitizes_ovpn_provisioning_secret_material_test() ->
    ias_demo_store:clear(),
    Snapshot = #{
        format => ias_demo_state_v1,
        objects => [#{
            id => <<"imported_ovpn_provisioning">>,
            provisioning_id => <<"imported_ovpn_provisioning">>,
            kind => ovpn_provisioning,
            mode => portable,
            subject_kind => certificate,
            subject_id => <<"imported_certificate">>,
            private_key_body => <<"IMPORTED-PRIVATE-KEY">>,
            certificate_body => <<"IMPORTED-CERTIFICATE">>,
            ca_certificate_body => <<"IMPORTED-CA-CERTIFICATE">>,
            private_key_stored => true,
            certificate_body_stored => true,
            ca_body_stored => true
        }],
        relationships => []
    },
    Term = iolist_to_binary(io_lib:format("~tp.~n", [Snapshot])),

    Result = ias_demo_state:import(Term),
    {ok, Imported} = ias_demo_store:get(<<"imported_ovpn_provisioning">>),

    ?assertEqual(1, maps:get(imported_objects, Result)),
    ?assertEqual(false, maps:is_key(private_key_body, Imported)),
    ?assertEqual(false, maps:is_key(certificate_body, Imported)),
    ?assertEqual(false, maps:is_key(ca_certificate_body, Imported)),
    ?assertEqual(false, maps:get(private_key_stored, Imported)),
    ?assertEqual(false, maps:get(certificate_body_stored, Imported)),
    ?assertEqual(false, maps:get(ca_body_stored, Imported)).

demo_state_roundtrip_supports_ovpn_provisioning_transactions_test() ->
    ias_demo_store:clear(),
    Transaction = ias_demo_store:put_runtime_object(#{
        id => <<"state_ovpn_provisioning">>,
        provisioning_id => <<"state_ovpn_provisioning">>,
        kind => ovpn_provisioning,
        source => ovpn_provisioning_demo,
        mode => portable,
        subject_kind => certificate,
        subject_id => <<"state_certificate">>,
        status => awaiting_material,
        material_status => pending_real_material,
        artifact_status => skeleton_only,
        delivery_status => not_ready,
        downloaded => false,
        private_key_stored => false,
        certificate_body_stored => false,
        ca_body_stored => false
    }),
    Term = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    Result = ias_demo_state:import(Term),

    ?assertEqual(1, maps:get(imported_objects, Result)),
    ?assertMatch({ok, #{kind := ovpn_provisioning,
                        mode := portable,
                        status := awaiting_material}},
                 ias_demo_store:get(maps:get(id, Transaction))).

setup_demo_graph() ->
    Device = ias_demo_store:add_device(#{id => <<"state_device">>,
                                         source => ovpn_demo_import,
                                         import_id => <<"state_import">>,
                                         type => <<"vpn-client">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"state_certificate">>,
                                                   source => ovpn_demo_import,
                                                   import_id => <<"state_import">>,
                                                   ca_present => true,
                                                   private_key_stored => false,
                                                   certificate_body_stored => false}),
    Service = ias_demo_store:add_service(#{id => <<"state_vpn_service">>,
                                           source => ovpn_demo_import,
                                           import_id => <<"state_import">>,
                                           service => openvpn,
                                           remote => <<"example.com:1194">>}),
    {ok, _CertRel} = ias_relationship_link:create(uses_certificate,
                                                  maps:get(id, Device),
                                                  maps:get(id, Certificate)),
    {ok, _ServiceRel} = ias_relationship_link:create(uses_service,
                                                     maps:get(id, Device),
                                                     maps:get(id, Service)),
    #{device => Device,
      certificate => Certificate,
      service => Service}.

warning_counts(Report) ->
    maps:from_list([{Key, warning_count(Value)} || {Key, Value} <- maps:to_list(Report)]).

warning_count(Value) when is_list(Value) ->
    length(Value);
warning_count(#{ready := Ready, incomplete := Incomplete}) ->
    #{ready => length(Ready),
      incomplete => length(Incomplete)};
warning_count(Value) ->
    Value.

verification_certificate(Certificate) ->
    Certificate#{certificate_id => maps:get(id, Certificate, undefined),
                 subject_cn => maps:get(id, Certificate, undefined),
                 issuer_cn => <<"Zencrypted Dev CA">>,
                 profile => administrator_profile(),
                 profile_id => administrator,
                 claims => #{role => admin,
                             services => [vpn, ias],
                             attributes => [admin, issue_certificates, revoke_certificates],
                             trust_level => elevated},
                 trusted => true,
                 key_match => true}.

administrator_profile() ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile, undefined) =:= administrator],
    Profile.

decode_snapshot(Term) ->
    {ok, Tokens, _} = erl_scan:string(binary_to_list(Term)),
    {ok, Snapshot} = erl_parse:parse_term(Tokens),
    Snapshot.
