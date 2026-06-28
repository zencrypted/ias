-module(ias_provisioning_wizard_relationships_tests).
-include_lib("eunit/include/eunit.hrl").

relationship_review_lists_six_pending_links_test() ->
    Draft = complete_draft(),
    Review = ias_provisioning_wizard_store:relationship_review(Draft),
    Items = maps:get(items, Review),

    ?assertEqual(6, length(Items)),
    ?assertEqual(true, maps:get(can_apply, Review)),
    ?assertEqual(false, maps:get(ready, Review)),
    ?assertEqual([will_create, will_create, will_create,
                  will_create, will_create, will_create],
                 [maps:get(status, Item) || Item <- Items]).

relationship_apply_creates_graph_and_unlocks_next_test() ->
    Draft = complete_draft(),
    WizardId = maps:get(id, Draft),

    ?assertEqual({error, relationships_not_applied},
                 ias_provisioning_wizard_store:next(WizardId)),
    {ok, AppliedDraft} = ias_provisioning_wizard_store:apply_relationships(WizardId),

    ?assertEqual(true, maps:get(relationships_applied, AppliedDraft)),
    ?assertEqual(true, ias_provisioning_wizard_store:relationships_ready(AppliedDraft)),
    ?assertEqual(6, length(ias_demo_store:relationships())),
    {ok, MaterialStep} = ias_provisioning_wizard_store:next(WizardId),
    ?assertEqual(material_readiness, maps:get(current_step, MaterialStep)).

automatic_relationship_commit_skips_review_test() ->
    Draft0 = complete_draft(),
    WizardId = maps:get(id, Draft0),
    ClientCertificateId = maps:get(client_certificate_id, Draft0),
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    {ok, _} = ias_certificate_material:put(
        ClientCertificateId, client_certificate, Pem, operator_load),
    {ok, Draft} = ias_provisioning_wizard_store:update(
        WizardId, #{current_step => client_certificate}),

    {ok, MaterialStep} = ias_provisioning_wizard_store:next(maps:get(id, Draft)),

    ?assertEqual(material_readiness, maps:get(current_step, MaterialStep)),
    ?assertEqual(true, maps:get(relationships_applied, MaterialStep)),
    ?assertEqual(true, ias_provisioning_wizard_store:relationships_ready(MaterialStep)),
    ?assertEqual(6, length(ias_demo_store:relationships())).

automatic_relationship_conflict_opens_review_test() ->
    Draft0 = complete_draft(),
    WizardId = maps:get(id, Draft0),
    DeviceId = maps:get(device_id, Draft0),
    ClientCertificateId = maps:get(client_certificate_id, Draft0),
    OtherService = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_auto_commit_other_service">>,
          kind => vpn_service,
          source => manual_vpn_service,
          name => <<"Other VPN">>,
          endpoint => <<"other.example.com">>,
          remote_port => <<"1194">>,
          protocol => <<"udp">>}),
    {ok, _} = ias_relationship_link:create(
        uses_service, DeviceId, maps:get(id, OtherService)),
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    {ok, _} = ias_certificate_material:put(
        ClientCertificateId, client_certificate, Pem, operator_load),
    {ok, Draft} = ias_provisioning_wizard_store:update(
        WizardId, #{current_step => client_certificate}),

    {ok, ReviewStep} = ias_provisioning_wizard_store:next(maps:get(id, Draft)),

    ?assertEqual(relationships, maps:get(current_step, ReviewStep)),
    ?assertEqual(false, maps:get(relationships_applied, ReviewStep)),
    Review = ias_provisioning_wizard_store:relationship_review(ReviewStep),
    ?assertEqual(false, maps:get(can_apply, Review)),
    ?assertEqual(conflict, maps:get(status, item(device_vpn_service, Review))).

automatic_commit_is_idempotent_for_existing_graph_test() ->
    Draft0 = complete_draft(),
    WizardId = maps:get(id, Draft0),
    ClientCertificateId = maps:get(client_certificate_id, Draft0),
    Pem = public_key:pem_encode([{'Certificate', <<1,2,3,4>>, not_encrypted}]),
    {ok, _} = ias_certificate_material:put(
        ClientCertificateId, client_certificate, Pem, operator_load),
    {ok, _AppliedDraft} = ias_provisioning_wizard_store:apply_relationships(WizardId),
    {ok, Draft} = ias_provisioning_wizard_store:update(
        WizardId, #{current_step => client_certificate,
                    relationships_applied => false}),
    ExistingIds = relationship_ids(),

    {ok, MaterialStep} = ias_provisioning_wizard_store:next(maps:get(id, Draft)),

    ?assertEqual(material_readiness, maps:get(current_step, MaterialStep)),
    ?assertEqual(true, maps:get(relationships_applied, MaterialStep)),
    ?assertEqual(ExistingIds, relationship_ids()).

relationship_apply_is_idempotent_test() ->
    Draft = complete_draft(),
    WizardId = maps:get(id, Draft),

    {ok, _} = ias_provisioning_wizard_store:apply_relationships(WizardId),
    FirstIds = relationship_ids(),
    {ok, _} = ias_provisioning_wizard_store:apply_relationships(WizardId),
    SecondIds = relationship_ids(),

    ?assertEqual(FirstIds, SecondIds),
    ?assertEqual(6, length(SecondIds)).

security_policy_relationships_are_applied_test() ->
    Draft = complete_draft(),
    DeviceId = maps:get(device_id, Draft),
    CertificateId = maps:get(client_certificate_id, Draft),
    {ok, _AppliedDraft} = ias_provisioning_wizard_store:apply_relationships(
        maps:get(id, Draft)),

    ?assertMatch(#{kind := relationship}, ias_relationship_link:exists(
        uses_security_policy, DeviceId, <<"high_security">>)),
    ?assertMatch(#{kind := relationship}, ias_relationship_link:exists(
        uses_security_policy, CertificateId, <<"high_security">>)).

different_security_policy_blocks_apply_test() ->
    Draft = complete_draft(),
    DeviceId = maps:get(device_id, Draft),
    {ok, _} = ias_relationship_link:create(
        uses_security_policy, DeviceId, <<"standard">>),

    Review = ias_provisioning_wizard_store:relationship_review(Draft),
    PolicyItem = item(device_security_policy, Review),

    ?assertEqual(conflict, maps:get(status, PolicyItem)),
    ?assertEqual(false, maps:get(can_apply, Review)).

existing_operational_conflict_blocks_apply_test() ->
    Draft = complete_draft(),
    DeviceId = maps:get(device_id, Draft),
    OtherService = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_relationship_other_service">>,
          kind => vpn_service,
          source => manual_vpn_service,
          name => <<"Other VPN">>,
          endpoint => <<"other.example.com">>,
          remote_port => <<"1194">>,
          protocol => <<"udp">>}),
    {ok, _} = ias_relationship_link:create(
        uses_service, DeviceId, maps:get(id, OtherService)),

    Review = ias_provisioning_wizard_store:relationship_review(Draft),
    ServiceItem = item(device_vpn_service, Review),

    ?assertEqual(conflict, maps:get(status, ServiceItem)),
    ?assertEqual(false, maps:get(can_apply, Review)),
    ?assertMatch({error, {relationship_preflight_failed, _}},
                 ias_provisioning_wizard_store:apply_relationships(maps:get(id, Draft))),
    ?assertEqual(1, length(ias_demo_store:relationships())).

different_security_profile_blocks_apply_test() ->
    Draft = complete_draft(),
    DeviceId = maps:get(device_id, Draft),
    {ok, _} = ias_relationship_link:create(
        uses_security_profile, DeviceId, default_user),

    Review = ias_provisioning_wizard_store:relationship_review(Draft),
    ProfileItem = item(device_security_profile, Review),

    ?assertEqual(conflict, maps:get(status, ProfileItem)),
    ?assertEqual(false, maps:get(can_apply, Review)).

client_certificate_linked_to_other_device_blocks_review_test() ->
    Draft = complete_draft(),
    OtherDevice = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_relationship_other_device">>,
          kind => device,
          source => manual_device,
          name => <<"Other Device">>}),
    {ok, _} = ias_relationship_link:create(
        uses_certificate, maps:get(id, OtherDevice),
        maps:get(client_certificate_id, Draft)),

    Review = ias_provisioning_wizard_store:relationship_review(Draft),
    ClientItem = item(device_client_certificate, Review),

    ?assertEqual(conflict, maps:get(status, ClientItem)),
    ?assertEqual(false, maps:get(can_apply, Review)).

stale_reference_is_reported_test() ->
    Draft = complete_draft(),
    ClientId = maps:get(client_certificate_id, Draft),
    ok = ias_demo_store:delete_runtime_object(certificate, ClientId),

    Review = ias_provisioning_wizard_store:relationship_review(Draft),
    ClientItem = item(device_client_certificate, Review),

    ?assertEqual(stale_reference, maps:get(status, ClientItem)),
    ?assertEqual(false, maps:get(can_apply, Review)),
    ?assertEqual(false, maps:get(ready, Review)).

already_linked_graph_is_ready_test() ->
    Draft = complete_draft(),
    WizardId = maps:get(id, Draft),
    {ok, AppliedDraft} = ias_provisioning_wizard_store:apply_relationships(WizardId),

    Review = ias_provisioning_wizard_store:relationship_review(AppliedDraft),

    ?assertEqual(true, maps:get(ready, Review)),
    ?assertEqual([already_linked, already_linked, already_linked,
                  already_linked, already_linked, already_linked],
                 [maps:get(status, Item) || Item <- maps:get(items, Review)]).

relationship_review_renders_apply_action_test() ->
    Draft = complete_draft(),
    Html = render(ias_provisioning_wizard:content_for({draft, Draft})),

    ?assertMatch({_, _}, binary:match(Html, <<"Apply Relationships">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"will_create">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"VPN Service">>)),
    ?assertMatch({_, _}, binary:match(Html, <<">Next</span>">>)).

relationship_review_uses_responsive_cards_test() ->
    Draft = complete_draft(),
    Html = render(ias_provisioning_wizard:content_for({draft, Draft})),

    ?assertMatch({_, _}, binary:match(Html, <<"grid-template-columns:repeat(auto-fit,minmax(260px,1fr))">>)),
    ?assertMatch({_, _}, binary:match(Html, <<">Source</span>">>)),
    ?assertMatch({_, _}, binary:match(Html, <<">Target</span>">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"min-width:0;overflow:hidden">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"width:20%;">>)).

relationship_review_renders_applied_state_test() ->
    Draft = complete_draft(),
    {ok, AppliedDraft} = ias_provisioning_wizard_store:apply_relationships(
        maps:get(id, Draft)),
    Html = render(ias_provisioning_wizard:content_for({draft, AppliedDraft})),

    ?assertMatch({_, _}, binary:match(Html, <<"Relationships Applied">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"already_linked">>)).

relationship_apply_marker_roundtrips_demo_state_test() ->
    Draft = complete_draft(),
    WizardId = maps:get(id, Draft),
    {ok, _AppliedDraft} = ias_provisioning_wizard_store:apply_relationships(WizardId),
    Snapshot = ias_demo_state:export(),

    ok = ias_demo_state:clear(),
    Result = ias_demo_state:import(Snapshot),
    {ok, Restored} = ias_provisioning_wizard_store:get(WizardId),

    ?assertEqual(1, maps:get(imported_wizard_drafts, Result)),
    ?assertEqual(true, maps:get(relationships_applied, Restored)),
    ?assertEqual(true, ias_provisioning_wizard_store:relationships_ready(Restored)).

selection_change_resets_applied_flag_test() ->
    Draft = complete_draft(),
    {ok, AppliedDraft} = ias_provisioning_wizard_store:apply_relationships(
        maps:get(id, Draft)),
    ?assertEqual(true, maps:get(relationships_applied, AppliedDraft)),

    NewService = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_relationship_new_service">>,
          kind => vpn_service,
          source => manual_vpn_service,
          name => <<"New VPN">>,
          endpoint => <<"new.example.com">>,
          remote_port => <<"1194">>,
          protocol => <<"udp">>}),
    {ok, Changed} = ias_provisioning_wizard_store:select_vpn_service(
        maps:get(id, AppliedDraft), maps:get(id, NewService)),

    ?assertEqual(false, maps:get(relationships_applied, Changed)).

complete_draft() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    Device = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_relationship_device">>,
          kind => device,
          source => manual_device,
          name => <<"Wizard Device">>,
          type => <<"vpn-client">>,
          tunnel_device => <<"tun">>,
          transport => <<"udp">>}),
    Service = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_relationship_service">>,
          kind => vpn_service,
          source => manual_vpn_service,
          name => <<"Wizard VPN">>,
          endpoint => <<"vpn.example.com">>,
          remote_port => <<"1194">>,
          protocol => <<"udp">>}),
    CaCertificate = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_relationship_ca">>,
          kind => certificate,
          source => ca_certificate,
          certificate_role => ca_certificate,
          material_type => ca_certificate,
          name => <<"Wizard CA">>,
          subject => <<"CN=Wizard CA">>}),
    ClientCertificate = ias_demo_store:put_runtime_object(
        #{id => <<"wizard_relationship_client">>,
          kind => certificate,
          source => certificate_issue_demo,
          certificate_role => client_certificate,
          material_type => client_certificate,
          subject_cn => <<"wizard-client">>}),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0),
        #{current_step => relationships,
          device_id => maps:get(id, Device),
          security_profile_id => administrator,
          vpn_service_id => maps:get(id, Service),
          ca_certificate_id => maps:get(id, CaCertificate),
          client_certificate_id => maps:get(id, ClientCertificate)}),
    Draft.

item(Key, Review) ->
    [Found] = [Item || Item <- maps:get(items, Review),
                       maps:get(key, Item) =:= Key],
    Found.

relationship_ids() ->
    lists:sort([maps:get(id, Relationship)
                || Relationship <- ias_demo_store:relationships()]).

render(Element) ->
    iolist_to_binary(nitro:render(Element)).
