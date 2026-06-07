-module(ias_demo_data).
-export([users/0, devices/0, services/0, certificates/0, profiles/0]).

users() ->
    [
        #{id => alice, name => <<"Alice">>, role => <<"admin">>},
        #{id => bob, name => <<"Bob">>, role => <<"operator">>}
    ].

devices() ->
    [
        #{id => laptop1, owner => alice, type => <<"laptop">>},
        #{id => phone1, owner => alice, type => <<"phone">>},
        #{id => workstation1, owner => bob, type => <<"workstation">>}
    ].

services() ->
    [
        #{id => vpn, name => <<"VPN">>},
        #{id => portal, name => <<"Admin Portal">>}
    ].

certificates() ->
    [
        #{id => cert1, owner => alice, status => <<"valid">>},
        #{id => cert2, owner => bob, status => <<"pending">>}
    ].

profiles() ->
    [
        #{id => default_user, description => <<"Default user profile">>},
        #{id => administrator, description => <<"Administrator profile">>}
    ].
