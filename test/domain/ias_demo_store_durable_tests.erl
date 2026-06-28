-module(ias_demo_store_durable_tests).

-include_lib("eunit/include/eunit.hrl").

write_through_contract_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Context) ->
         {inorder,
          [?_test(object_is_committed_before_ets_projection()),
           ?_test(unchanged_projection_is_idempotent()),
           ?_test(rejected_object_never_reaches_ets()),
           ?_test(runtime_identity_representation_is_preserved()),
           ?_test(relationship_and_guarded_delete_are_write_through()),
           ?_test(clear_removes_durable_and_runtime_state())]}
     end}.

object_is_committed_before_ets_projection() ->
    Id = <<"demo-store-durable-device">>,
    Stored = ias_demo_store:put_runtime_object(
               (device(Id))#{transient_debug => must_not_persist}),

    ?assertEqual(false, maps:is_key(transient_debug, Stored)),
    ?assertMatch({ok, #{id := Id}}, ias_demo_store:get(Id)),
    {ok, DomainRecord} = ias_domain_store:get(device, Id),
    ?assertEqual(Stored, maps:get(payload, DomainRecord)),
    ?assertEqual(false,
                 maps:is_key(transient_debug, maps:get(payload, DomainRecord))).

unchanged_projection_is_idempotent() ->
    Id = <<"demo-store-idempotent-device">>,
    First = ias_demo_store:put_runtime_object(device(Id)),
    {ok, FirstRecord} = ias_domain_store:get(device, Id),
    Second = ias_demo_store:put_runtime_object(
               (device(Id))#{transient_debug => ignored}),
    {ok, SecondRecord} = ias_domain_store:get(device, Id),

    ?assertEqual(First, Second),
    ?assertEqual(maps:get(revision, FirstRecord),
                 maps:get(revision, SecondRecord)),
    ?assertEqual(maps:get(updated_at, FirstRecord),
                 maps:get(updated_at, SecondRecord)).

rejected_object_never_reaches_ets() ->
    Id = <<"demo-store-secret-device">>,
    ?assertError(
       {demo_store_domain_write_failed,
        {forbidden_domain_material, [metadata, private_key]}},
       ias_demo_store:put_runtime_object(
         (device(Id))#{metadata => #{private_key => <<"secret">>}})),
    ?assertEqual(not_found, ias_demo_store:get(Id)),
    ?assertEqual(not_found, ias_domain_store:get(device, Id)).

runtime_identity_representation_is_preserved() ->
    User = ias_demo_store:put_runtime_object(
             #{id => durable_demo_user,
               kind => user,
               source => durable_store_test,
               name => <<"Durable Demo User">>,
               profile_id => administrator}),
    Certificate = ias_demo_store:put_runtime_object(
                    certificate(<<"demo-store-identity-certificate">>)),
    Relationship = ias_demo_store:add_relationship(
                     #{relationship_id => <<"demo-store-identity-relationship">>,
                       relation_type => issued_certificate,
                       source_kind => user,
                       source_id => maps:get(id, User),
                       target_kind => certificate,
                       target_id => maps:get(id, Certificate)}),

    ?assertEqual(durable_demo_user, maps:get(id, User)),
    ?assertEqual(durable_demo_user, maps:get(source_id, Relationship)),
    {ok, DomainRecord} = ias_domain_store:get(user, durable_demo_user),
    ?assertEqual(durable_demo_user,
                 maps:get(id, maps:get(payload, DomainRecord))),
    {ok, RelationshipRecord} =
        ias_domain_store:get(relationship, maps:get(id, Relationship)),
    ?assertEqual(durable_demo_user,
                 maps:get(source_id, maps:get(payload, RelationshipRecord))),
    ?assertMatch({ok, #{id := durable_demo_user}},
                 ias_demo_store:get(durable_demo_user)).

relationship_and_guarded_delete_are_write_through() ->
    Device = ias_demo_store:put_runtime_object(
               device(<<"demo-store-related-device">>)),
    Certificate = ias_demo_store:put_runtime_object(
                    certificate(<<"demo-store-related-certificate">>)),
    Relationship = ias_demo_store:add_relationship(
                     #{relationship_id => <<"demo-store-relationship">>,
                       relation_type => uses_certificate,
                       source_kind => device,
                       source_id => maps:get(id, Device),
                       target_kind => certificate,
                       target_id => maps:get(id, Certificate)}),

    ?assertMatch({ok, _},
                 ias_domain_store:get(relationship,
                                      maps:get(id, Relationship))),
    ?assertMatch(
       {error, {domain_object_referenced, device, _, [_]}},
       ias_demo_store:delete_runtime_object(device, maps:get(id, Device))),
    ?assertMatch({ok, _}, ias_demo_store:get(maps:get(id, Device))),
    ?assertMatch({ok, _},
                 ias_domain_store:get(device, maps:get(id, Device))),

    ok = ias_demo_store:delete_relationship(maps:get(id, Relationship)),
    ?assertEqual(not_found,
                 ias_domain_store:get(relationship,
                                      maps:get(id, Relationship))),
    ok = ias_demo_store:delete_runtime_object(device, maps:get(id, Device)),
    ?assertEqual(not_found, ias_demo_store:get(maps:get(id, Device))),
    ?assertEqual(not_found,
                 ias_domain_store:get(device, maps:get(id, Device))).

clear_removes_durable_and_runtime_state() ->
    Id = <<"demo-store-clear-device">>,
    _ = ias_demo_store:put_runtime_object(device(Id)),
    ok = ias_demo_store:clear(),

    ?assertEqual(not_found, ias_demo_store:get(Id)),
    ?assertEqual(not_found, ias_domain_store:get(device, Id)),
    ?assertEqual([], ias_demo_store:runtime_objects()).

setup() ->
    ok = ias_demo_store:clear(),
    ok.

cleanup(_Context) ->
    ok = ias_demo_store:clear().

device(Id) ->
    #{id => Id,
      kind => device,
      source => durable_store_test,
      name => <<"Durable demo device">>,
      type => <<"vpn-client">>,
      endpoint => <<"127.0.0.1:1194">>,
      transport => udp,
      tunnel_device => tun,
      private_key_provider => <<"device_file">>,
      private_key_ref => <<"client.key">>,
      private_key_stored => false,
      certificate_body_stored => false,
      ca_body_stored => false}.

certificate(Id) ->
    #{id => Id,
      kind => certificate,
      source => durable_store_test,
      subject => <<"CN=Durable Demo Device">>,
      issuer => <<"CN=Test CA">>,
      certificate_role => client_certificate,
      certificate_status => trusted,
      private_key_stored => false,
      certificate_body_stored => false}.
