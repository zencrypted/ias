-module(ias_demo_data).
-export([users/0, devices/0, services/0, certificates/0, profiles/0]).

users() ->
    [
        #{id => alice,
          name => <<"Alice">>,
          role => <<"admin">>,
          devices => [laptop1, phone1]},
        #{id => bob,
          name => <<"Bob">>,
          role => <<"operator">>,
          devices => [workstation1]}
    ].

devices() ->
    [
        #{id => laptop1,
          owner => alice,
          type => <<"laptop">>,
          certificate => cert1,
          services => [vpn],
          vpn_peer => <<"peer_a">>},
        #{id => phone1,
          owner => alice,
          type => <<"phone">>,
          certificate => cert2,
          services => [portal]},
        #{id => workstation1,
          owner => bob,
          type => <<"workstation">>,
          certificate => cert3,
          services => [vpn],
          vpn_peer => <<"peer_b">>}
    ].

services() ->
    [
        #{id => vpn, name => <<"VPN">>, owners => [alice, bob]},
        #{id => portal, name => <<"Admin Portal">>, owners => [alice]}
    ].

certificates() ->
    [
        #{id => cert1, owner => alice, device => laptop1, status => <<"valid">>},
        #{id => cert2, owner => alice, device => phone1, status => <<"valid">>},
        #{id => cert3, owner => bob, device => workstation1, status => <<"pending">>}
    ].

profiles() ->
    [
        #{id => default_user, description => <<"Default user profile">>},
        #{id => administrator, description => <<"Administrator profile">>}
    ].
