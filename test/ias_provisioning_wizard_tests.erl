-module(ias_provisioning_wizard_tests).
-include_lib("eunit/include/eunit.hrl").

draft_creation_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    ?assertMatch(<<"provisioning_wizard_", _/binary>>, maps:get(id, Draft)),
    ?assertEqual(device_bound, maps:get(scenario, Draft)),
    ?assertEqual(device, maps:get(current_step, Draft)),
    ?assertEqual(undefined, maps:get(device_id, Draft)),
    ?assertMatch({ok, Draft}, ias_provisioning_wizard_store:get(maps:get(id, Draft))).

unique_ids_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, First} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Second} = ias_provisioning_wizard_store:new(device_bound),
    ?assertNotEqual(maps:get(id, First), maps:get(id, Second)).

scenario_selection_starts_device_step_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    ?assertEqual(device_bound, maps:get(scenario, Draft)),
    ?assertEqual(device, maps:get(current_step, Draft)).

next_and_back_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft1} = ias_provisioning_wizard_store:next(maps:get(id, Draft0)),
    ?assertEqual(security_profile, maps:get(current_step, Draft1)),
    {ok, Draft2} = ias_provisioning_wizard_store:back(maps:get(id, Draft1)),
    ?assertEqual(device, maps:get(current_step, Draft2)).

step_boundaries_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, SchemeDraft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => scheme}),
    {ok, StillScheme} = ias_provisioning_wizard_store:back(maps:get(id, SchemeDraft)),
    ?assertEqual(scheme, maps:get(current_step, StillScheme)),
    {ok, LastDraft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{current_step => provisioning}),
    {ok, StillLast} = ias_provisioning_wizard_store:next(maps:get(id, LastDraft)),
    ?assertEqual(provisioning, maps:get(current_step, StillLast)).

cancel_deletes_draft_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    Id = maps:get(id, Draft),
    ok = ias_provisioning_wizard_store:delete(Id),
    ?assertEqual(not_found, ias_provisioning_wizard_store:get(Id)).

refresh_get_restores_current_step_test() ->
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft1} = ias_provisioning_wizard_store:next(maps:get(id, Draft0)),
    {ok, Restored} = ias_provisioning_wizard_store:get(maps:get(id, Draft1)),
    ?assertEqual(security_profile, maps:get(current_step, Restored)).

invalid_wizard_id_test() ->
    ias_provisioning_wizard_store:clear(),
    ?assertEqual(not_found, ias_provisioning_wizard_store:get(<<"missing_wizard">>)),
    Html = render(ias_provisioning_wizard:content_for({error, <<"missing_wizard">>})),
    ?assertMatch({_, _}, binary:match(Html, <<"Wizard draft not found">>)).

drafts_are_not_exported_in_demo_state_test() ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    Snapshot = ias_demo_state:export(),
    ?assertEqual(nomatch, binary:match(Snapshot, maps:get(id, Draft))),
    ?assertEqual(nomatch, binary:match(Snapshot, <<"provisioning_wizard_">>)).

portable_scheme_is_disabled_test() ->
    Html = render(ias_provisioning_wizard:content_for(start)),
    ?assertEqual(false, ias_provisioning_wizard_store:portable_enabled()),
    ?assertMatch({_, _}, binary:match(Html, <<"Portable VPN Profile">>)),
    ?assertMatch({_, _}, binary:match(Html, ias_provisioning_wizard_store:portable_reason())),
    ?assertMatch({_, _}, binary:match(Html, <<"Disabled">>)).

ovpn_import_scheme_links_existing_route_test() ->
    Html = render(ias_provisioning_wizard:content_for(start)),
    ?assertEqual(<<"/app/ovpn.htm">>, ias_provisioning_wizard_store:ovpn_import_url()),
    ?assertMatch({_, _}, binary:match(Html, <<"Import Existing OVPN">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"/app/ovpn.htm">>)).

render(Doc) ->
    iolist_to_binary(nitro:render(Doc)).
