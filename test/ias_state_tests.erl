-module(ias_state_tests).

-include_lib("eunit/include/eunit.hrl").

synchronized_projection_health_is_rendered_test() ->
    setup(),
    try
        {ok, _Health} = ias_demo_store:rehydrate(),
        Html = iolist_to_binary(nitro:render(ias_state:content())),
        ?assertMatch({_, _}, binary:match(Html, <<"Durable Projection Health">>)),
        ?assertMatch({_, _}, binary:match(Html, <<"SYNCHRONIZED">>)),
        ?assertMatch({_, _}, binary:match(Html, <<"Durable Objects">>)),
        ?assertMatch({_, _}, binary:match(Html, <<"ETS Projection Total">>))
    after
        ok = ias_demo_store:clear()
    end.

mismatched_projection_health_is_rendered_test() ->
    setup(),
    try
        DeviceId = <<"state-health-mismatch-device">>,
        _ = ias_demo_store:put_runtime_object(device(DeviceId)),
        true = ets:delete_all_objects(ias_demo_store),
        Html = iolist_to_binary(nitro:render(ias_state:content())),
        ?assertMatch({_, _}, binary:match(Html, <<"MISMATCH">>)),
        ?assertMatch({_, _}, binary:match(Html, <<"Rehydration is required">>))
    after
        ok = ias_demo_store:clear()
    end.

setup() ->
    ok = ias_domain_store:ensure(),
    ok = ias_vpn_authority:ensure(),
    ok = ias_vpn_reconciliation_incidents:ensure(),
    ok = ias_demo_store:clear().

device(Id) ->
    #{id => Id,
      kind => device,
      source => state_health_test,
      owner => alice,
      name => <<"State health device">>,
      type => <<"vpn-client">>,
      private_key_stored => false,
      certificate_body_stored => false,
      ca_body_stored => false}.
