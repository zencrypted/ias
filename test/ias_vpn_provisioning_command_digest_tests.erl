-module(ias_vpn_provisioning_command_digest_tests).
-include_lib("eunit/include/eunit.hrl").

portable_digest_matches_vpn_contract_fixture_test() ->
    Command = #{peer_id => <<"peer-a">>, revision => 7, operation => upsert,
                source => ias, desired_state => #{enabled => true, port => 1194},
                dynamic_device_id => <<"device-a">>},
    Expected = <<16#95,16#8f,16#4c,16#4c,16#e1,16#c5,16#a7,16#24,
                 16#69,16#e6,16#f8,16#0d,16#9a,16#7b,16#ae,16#80,
                 16#91,16#dc,16#87,16#27,16#b1,16#78,16#fb,16#0d,
                 16#19,16#0c,16#1c,16#ea,16#5a,16#bf,16#f8,16#3a>>,
    ?assertEqual(Expected, ias_vpn_provisioning_command_digest:digest(Command)).
