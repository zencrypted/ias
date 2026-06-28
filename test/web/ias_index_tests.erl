-module(ias_index_tests).
-include_lib("eunit/include/eunit.hrl").

index_source_contains_provisioning_cta_test() ->
    {ok, Source} = file:read_file(filename:join(["src", "pages", "ias_index.erl"])),
    ?assertMatch({_, _}, binary:match(Source, <<"Start Device-bound Provisioning">>)),
    ?assertMatch({_, _}, binary:match(Source, <<"/app/provisioning-wizard.htm">>)).

static_index_contains_provisioning_cta_and_navigation_test() ->
    {ok, Html} = file:read_file(filename:join(["priv", "static", "index.htm"])),
    ?assertMatch({_, _}, binary:match(Html, <<"href=\"provisioning-wizard.htm\"">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Start Device-bound Provisioning">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Create a new VPN configuration step by step">>)).
