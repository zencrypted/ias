-module(ias_demo_store_graph_tests).

-include_lib("eunit/include/eunit.hrl").

graph_write_contract_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         {inorder,
          [?_test(objects_and_relationships_commit_together()),
           ?_test(invalid_object_rolls_back_the_complete_graph()),
           ?_test(missing_relationship_reference_rolls_back_objects()),
           ?_test(duplicate_graph_identity_is_rejected())]}
     end}.

objects_and_relationships_commit_together() ->
    Service = service(<<"graph-service">>),
    Certificate = certificate(<<"graph-ca-certificate">>),
    Relationship = #{relationship_id => <<"graph-service-ca">>,
                     relation_type => uses_ca_certificate,
                     source_kind => vpn_service,
                     source_id => maps:get(id, Service),
                     target_kind => certificate,
                     target_id => maps:get(id, Certificate)},

    {ok, #{objects := [StoredService, StoredCertificate],
           relationships := [StoredRelationship]}} =
        ias_demo_store:commit_graph([Service, Certificate], [Relationship]),

    ?assertEqual(maps:get(id, Service), maps:get(id, StoredService)),
    ?assertEqual(maps:get(id, Certificate), maps:get(id, StoredCertificate)),
    ?assertEqual(<<"graph-service-ca">>, maps:get(id, StoredRelationship)),
    ?assertMatch({ok, _}, ias_demo_store:get(maps:get(id, Service))),
    ?assertMatch({ok, _}, ias_demo_store:get(maps:get(id, Certificate))),
    ?assertMatch({ok, _}, ias_demo_store:get(maps:get(id, StoredRelationship))),
    ?assertMatch({ok, _}, ias_domain_store:get(vpn_service, maps:get(id, Service))),
    ?assertMatch({ok, _}, ias_domain_store:get(certificate, maps:get(id, Certificate))),
    ?assertMatch({ok, _},
                 ias_domain_store:get(relationship,
                                      maps:get(id, StoredRelationship))).

invalid_object_rolls_back_the_complete_graph() ->
    Service = service(<<"graph-valid-service">>),
    Invalid = (certificate(<<"graph-invalid-certificate">>))#{
                metadata => #{private_key => <<"must-not-persist">>}},

    ?assertEqual(
       {error, {forbidden_domain_material, [metadata, private_key]}},
       ias_demo_store:commit_graph([Service, Invalid], [])),
    ?assertEqual(not_found, ias_demo_store:get(maps:get(id, Service))),
    ?assertEqual(not_found,
                 ias_domain_store:get(vpn_service, maps:get(id, Service))),
    ?assertEqual(not_found,
                 ias_domain_store:get(certificate, maps:get(id, Invalid))).

missing_relationship_reference_rolls_back_objects() ->
    Service = service(<<"graph-rollback-service">>),
    Relationship = #{relationship_id => <<"graph-missing-reference">>,
                     relation_type => uses_ca_certificate,
                     source_kind => vpn_service,
                     source_id => maps:get(id, Service),
                     target_kind => certificate,
                     target_id => <<"missing-certificate">>},

    ?assertEqual(
       {error, {missing_domain_reference, certificate,
                <<"missing-certificate">>}},
       ias_demo_store:commit_graph([Service], [Relationship])),
    ?assertEqual(not_found, ias_demo_store:get(maps:get(id, Service))),
    ?assertEqual(not_found,
                 ias_domain_store:get(vpn_service, maps:get(id, Service))),
    ?assertEqual(not_found,
                 ias_domain_store:get(relationship,
                                      <<"graph-missing-reference">>)).

duplicate_graph_identity_is_rejected() ->
    Service = service(<<"graph-duplicate-service">>),
    ?assertEqual(
       {error, {duplicate_domain_graph_identity, vpn_service,
                <<"graph-duplicate-service">>}},
       ias_demo_store:commit_graph([Service, Service], [])),
    ?assertEqual(not_found, ias_demo_store:get(maps:get(id, Service))).

setup() ->
    ok = ias_demo_store:clear(),
    ok.

cleanup(_Context) ->
    ok = ias_demo_store:clear().

service(Id) ->
    #{id => Id,
      kind => vpn_service,
      source => graph_store_test,
      service => openvpn,
      remote => <<"127.0.0.1:1194">>,
      protocol => udp,
      private_key_stored => false,
      certificate_body_stored => false}.

certificate(Id) ->
    #{id => Id,
      kind => certificate,
      source => graph_store_test,
      subject => <<"CN=Graph Test CA">>,
      issuer => <<"CN=Graph Test CA">>,
      certificate_role => ca_certificate,
      certificate_status => trusted,
      private_key_stored => false,
      certificate_body_stored => false}.
