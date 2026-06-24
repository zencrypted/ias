-module(ias_vpn_provisioning_state).
-export([ensure/0,
         reset/0,
         prepare/2,
         ensure_minimum_revision/2,
         current_revision/1,
         last_command/1,
         status/0]).

ensure() ->
    ias_vpn_authority:ensure().

reset() ->
    ias_vpn_authority:reset_provisioning().

prepare(DeviceId, Command) ->
    ias_vpn_authority:prepare(DeviceId, Command).

ensure_minimum_revision(DeviceId, Revision) ->
    ias_vpn_authority:ensure_minimum_revision(DeviceId, Revision).

current_revision(DeviceId) ->
    ias_vpn_authority:current_revision(DeviceId).

last_command(DeviceId) ->
    ias_vpn_authority:last_command(DeviceId).

status() ->
    ias_vpn_authority:status().
