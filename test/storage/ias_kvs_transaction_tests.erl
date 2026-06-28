-module(ias_kvs_transaction_tests).

-include_lib("eunit/include/eunit.hrl").
-include("ias_domain_object.hrl").
-include("ias_provisioning_wizard_draft.hrl").

kvs_transaction_provider_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun cross_table_abort_rolls_back_all_kvs_writes/0,
      fun unsupported_provider_fails_closed/0]}.

setup() ->
    ok = ias_domain_store:ensure(),
    ok = ias_provisioning_wizard_draft_store:ensure(),
    ok = ias_domain_store:reset(),
    ok = ias_provisioning_wizard_draft_store:reset(),
    application:get_env(ias, kvs_transaction_provider).

cleanup(PreviousProvider) ->
    restore_provider(PreviousProvider),
    ok = ias_domain_store:reset(),
    ok = ias_provisioning_wizard_draft_store:reset().

cross_table_abort_rolls_back_all_kvs_writes() ->
    ObjectId = <<"kvs-provider-domain">>,
    DomainRecord = #ias_domain_object{
                      key = {device, ObjectId},
                      kind = device,
                      object_id = ObjectId,
                      payload = #{id => ObjectId, kind => device},
                      created_at = 1,
                      updated_at = 1},
    DraftId = <<"kvs-provider-draft">>,
    DraftRecord = #ias_provisioning_wizard_draft{
                     draft_id = DraftId,
                     payload = #{id => DraftId,
                                 scenario => device_bound,
                                 current_step => user},
                     created_at = 1,
                     updated_at = 1},

    ?assertEqual(
       {error, forced_kvs_transaction_abort},
       ias_kvs_transaction:run(
         fun() ->
             ok = kvs:put(DomainRecord),
             ok = kvs:put(DraftRecord),
             ias_kvs_transaction:abort(forced_kvs_transaction_abort)
         end)),
    ?assertEqual({error, not_found},
                 kvs:get(ias_domain_object, {device, ObjectId})),
    ?assertEqual({error, not_found},
                 kvs:get(ias_provisioning_wizard_draft, DraftId)).

unsupported_provider_fails_closed() ->
    application:set_env(ias,
                        kvs_transaction_provider,
                        ias_kvs_transaction_unsupported),
    ?assertMatch(
       {error, {kvs_transactions_not_supported, _}},
       ias_kvs_transaction:ensure()),
    ?assertMatch(
       {error, {kvs_transactions_not_supported, _}},
       ias_kvs_transaction:run(fun() -> ok end)).

restore_provider({ok, Provider}) ->
    application:set_env(ias, kvs_transaction_provider, Provider);
restore_provider(undefined) ->
    application:unset_env(ias, kvs_transaction_provider).
