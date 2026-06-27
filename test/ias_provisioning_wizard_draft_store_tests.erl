-module(ias_provisioning_wizard_draft_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ias_provisioning_wizard_draft.hrl").

wizard_draft_persistence_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [fun draft_is_written_and_rehydrated/0,
      fun repeated_rehydration_is_idempotent/0,
      fun completed_and_abandoned_lifecycle_is_durable/0,
      fun secret_material_is_rejected/0,
      fun incompatible_schema_fails_closed/0]}.

setup() ->
    ok = ias_provisioning_wizard_draft_store:ensure(),
    ok = ias_provisioning_wizard_store:clear(),
    ok.

cleanup(_) ->
    ok = ias_provisioning_wizard_store:clear().

draft_is_written_and_rehydrated() ->
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    Id = maps:get(id, Draft0),
    {ok, Draft1} = ias_provisioning_wizard_store:update(Id, #{current_step => device,
                                                               user_id => alice}),
    ets:delete_all_objects(ias_provisioning_wizard_drafts),
    ?assertEqual(not_found, ias_provisioning_wizard_store:get(Id)),
    ?assertEqual({ok, 1}, ias_provisioning_wizard_store:rehydrate()),
    ?assertEqual({ok, Draft1}, ias_provisioning_wizard_store:get(Id)).

repeated_rehydration_is_idempotent() ->
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    ?assertEqual({ok, 1}, ias_provisioning_wizard_store:rehydrate()),
    ?assertEqual({ok, 1}, ias_provisioning_wizard_store:rehydrate()),
    ?assertEqual([Draft], ias_provisioning_wizard_store:all()).

completed_and_abandoned_lifecycle_is_durable() ->
    {ok, Completed0} = ias_provisioning_wizard_store:new(device_bound),
    CompletedId = maps:get(id, Completed0),
    {ok, _} = ias_provisioning_wizard_store:update(
                CompletedId, #{completed => true,
                               provisioning_id => <<"provisioning-1">>,
                               completed_at => <<"2026-06-27T19:00:00Z">>}),
    {ok, Active} = ias_provisioning_wizard_store:new(device_bound),
    ActiveId = maps:get(id, Active),
    {ok, Abandoned} = ias_provisioning_wizard_store:abandon(ActiveId),
    ?assertEqual(true, maps:get(abandoned, Abandoned)),
    ets:delete_all_objects(ias_provisioning_wizard_drafts),
    {ok, 2} = ias_provisioning_wizard_store:rehydrate(),
    {ok, Completed} = ias_provisioning_wizard_store:get(CompletedId),
    {ok, RestoredAbandoned} = ias_provisioning_wizard_store:get(ActiveId),
    ?assertEqual(true, maps:get(completed, Completed)),
    ?assertEqual(true, maps:get(abandoned, RestoredAbandoned)).

secret_material_is_rejected() ->
    Draft = #{id => <<"secret-draft">>, scenario => device_bound,
              current_step => user, private_key => <<"secret">>},
    ?assertEqual({error, {forbidden_wizard_draft_material, [private_key]}},
                 ias_provisioning_wizard_draft_store:put(Draft)),
    ?assertEqual(not_found,
                 ias_provisioning_wizard_draft_store:get(<<"secret-draft">>)).

incompatible_schema_fails_closed() ->
    Record = #ias_provisioning_wizard_draft{
                draft_id = <<"bad-schema">>, schema_version = 999,
                payload = #{id => <<"bad-schema">>}},
    {atomic, ok} = mnesia:transaction(fun() -> mnesia:write(Record) end),
    ?assertEqual({error, {unsupported_wizard_draft_schema_version, 999}},
                 ias_provisioning_wizard_draft_store:ensure()),
    {atomic, ok} = mnesia:transaction(
                     fun() -> mnesia:delete({ias_provisioning_wizard_draft,
                                             <<"bad-schema">>}) end).
