-module(ias_policy_tests).
-include_lib("eunit/include/eunit.hrl").

administrator_security_policy_defaults_test() ->
    Profile = profile(administrator),

    ?assertEqual(enabled, ias_policy:device_lock(Profile)),
    ?assertEqual(required, ias_policy:two_factor(Profile)).

default_user_security_policy_defaults_test() ->
    Profile = profile(default_user),

    ?assertEqual(disabled, ias_policy:device_lock(Profile)),
    ?assertEqual(optional, ias_policy:two_factor(Profile)).

certificate_request_includes_security_policy_test() ->
    User = user(alice),
    Profile = profile(administrator),
    Request = ias_policy:certificate_request(User, Profile, <<"peer_new">>),

    ?assertEqual(administrator, maps:get(profile_id, Request)),
    ?assertEqual(enabled, maps:get(device_lock, Request)),
    ?assertEqual(required, maps:get(two_factor, Request)).

profile(Id) ->
    [Profile] = [Profile || Profile <- ias_demo_data:profiles(),
                            maps:get(id, Profile) =:= Id],
    Profile.

user(Id) ->
    [User] = [User || User <- ias_demo_data:users(),
                      maps:get(id, User) =:= Id],
    User.
