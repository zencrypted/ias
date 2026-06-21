-module(ias_provisioning_wizard_authorization_tests).
-include_lib("eunit/include/eunit.hrl").

locked_profile_derives_high_security_policy_test() ->
    Draft = draft_with_profile(administrator),
    {ok, Policy} = ias_provisioning_wizard_authorization:derived_policy(Draft),
    ?assertEqual(<<"high_security">>, maps:get(id, Policy)).

unlocked_profile_derives_standard_policy_test() ->
    Draft = draft_with_profile(default_user),
    {ok, Policy} = ias_provisioning_wizard_authorization:derived_policy(Draft),
    ?assertEqual(<<"standard">>, maps:get(id, Policy)).

draft_with_profile(ProfileId) ->
    ias_demo_state:clear(),
    ias_provisioning_wizard_store:clear(),
    {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
    {ok, Draft} = ias_provisioning_wizard_store:update(
        maps:get(id, Draft0), #{security_profile_id => ProfileId}),
    Draft.
