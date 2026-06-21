-module(ias_provisioning_wizard_store).
-compile({no_auto_import,[get/1]}).
-export([new/1,
         get/1,
         update/2,
         delete/1,
         clear/0,
         next/1,
         back/1,
         select_device/2,
         selected_device/1,
         select_security_profile/2,
         selected_security_profile/1,
         security_profile_compatibility/1,
         steps/0,
         step_title/1,
         step_description/1,
         portable_enabled/0,
         portable_reason/0,
         ovpn_import_url/0]).

-define(TABLE, ias_provisioning_wizard_drafts).
-define(OWNER, ias_provisioning_wizard_store_owner).

new(device_bound) ->
    ensure(),
    Now = created_at(),
    Id = wizard_id(),
    Draft = #{
        id => Id,
        scenario => device_bound,
        current_step => device,
        device_id => undefined,
        security_profile_id => undefined,
        vpn_service_id => undefined,
        ca_certificate_id => undefined,
        client_certificate_id => undefined,
        created_at => Now,
        updated_at => Now
    },
    ets:insert(?TABLE, {Id, Draft}),
    {ok, Draft};
new(_Scenario) ->
    {error, unsupported_scenario}.

get(undefined) ->
    not_found;
get(<<>>) ->
    not_found;
get([]) ->
    not_found;
get(Id) ->
    ensure(),
    TextId = normalize_id(Id),
    case ets:lookup(?TABLE, TextId) of
        [{_Key, Draft}] -> {ok, Draft};
        [] -> not_found
    end.

update(Id, Updates) when is_map(Updates) ->
    case get(Id) of
        {ok, Draft} ->
            case normalize_updates(Updates) of
                {ok, SafeUpdates} ->
                    Updated = (maps:merge(Draft, SafeUpdates))#{
                        updated_at => created_at()
                    },
                    ets:insert(?TABLE, {maps:get(id, Updated), Updated}),
                    {ok, Updated};
                {error, Reason} ->
                    {error, Reason}
            end;
        not_found ->
            {error, not_found}
    end.

delete(Id) ->
    ensure(),
    ets:delete(?TABLE, normalize_id(Id)),
    ok.

clear() ->
    ensure(),
    ets:delete_all_objects(?TABLE),
    ok.

next(Id) ->
    move(Id, next_step).

back(Id) ->
    move(Id, previous_step).

select_device(Id, DeviceId) ->
    case valid_device(DeviceId) of
        {ok, Device} ->
            update(Id, #{device_id => maps:get(id, Device)});
        {error, Reason} ->
            {error, Reason}
    end.

selected_device(Draft) when is_map(Draft) ->
    case maps:get(device_id, Draft, undefined) of
        undefined -> not_selected;
        DeviceId -> valid_device(DeviceId)
    end.

select_security_profile(Id, ProfileId) ->
    case valid_security_profile(ProfileId) of
        {ok, Profile} ->
            case security_profile_compatibility(Profile) of
                {blocked, Reason} -> {error, Reason};
                _ -> update(Id, #{security_profile_id => maps:get(id, Profile)})
            end;
        {error, Reason} ->
            {error, Reason}
    end.

selected_security_profile(Draft) when is_map(Draft) ->
    case maps:get(security_profile_id, Draft, undefined) of
        undefined -> not_selected;
        ProfileId -> valid_security_profile(ProfileId)
    end.

security_profile_compatibility(#{device_lock := enabled}) ->
    compatible;
security_profile_compatibility(#{device_lock := disabled}) ->
    {warning, <<"This profile does not require device lock. The wizard will still use device-bound provisioning and a device-owned private key.">>};
security_profile_compatibility(_Profile) ->
    {blocked, incompatible_security_profile}.

steps() ->
    [scheme,
     device,
     security_profile,
     vpn_service,
     ca_certificate,
     client_certificate,
     relationships,
     material_readiness,
     provisioning].

step_title(scheme) -> <<"Scheme">>;
step_title(device) -> <<"Device">>;
step_title(security_profile) -> <<"Security Profile">>;
step_title(vpn_service) -> <<"VPN Service">>;
step_title(ca_certificate) -> <<"CA Certificate">>;
step_title(client_certificate) -> <<"Client Certificate">>;
step_title(relationships) -> <<"Relationships">>;
step_title(material_readiness) -> <<"Material Readiness">>;
step_title(provisioning) -> <<"Provisioning">>;
step_title(Step) -> ias_html:text(Step).

step_description(scheme) ->
    <<"Choose the provisioning scenario. Stage 24A enables device-bound VPN profile orchestration only.">>;
step_description(device) ->
    <<"Select an existing runtime Device or create a new demo Device that will own the VPN profile.">>;
step_description(security_profile) ->
    <<"Select the Security Profile that defines device lock, 2FA, services and trust expectations for this device-bound flow.">>;
step_description(vpn_service) ->
    <<"Choose the VPN Service endpoint that will supply remote/protocol settings.">>;
step_description(ca_certificate) ->
    <<"Choose the CA trust anchor used by the VPN service.">>;
step_description(client_certificate) ->
    <<"Choose the device-bound client certificate.">>;
step_description(relationships) ->
    <<"Review the required Device, Certificate, Security Profile and VPN Service relationships.">>;
step_description(material_readiness) ->
    <<"Check public certificate material and assembly readiness before provisioning.">>;
step_description(provisioning) ->
    <<"Preview the future device-bound OVPN provisioning transaction. No artifact is created in Stage 24A.">>;
step_description(Step) ->
    ias_html:join([<<"Provisioning step: ">>, step_title(Step)]).

portable_enabled() ->
    false.

portable_reason() ->
    <<"Portable provisioning requires one-time private-key generation and delivery and is not implemented yet.">>.

ovpn_import_url() ->
    <<"/app/ovpn.htm">>.

move(Id, Direction) ->
    case get(Id) of
        {ok, Draft} ->
            Current = maps:get(current_step, Draft, scheme),
            case movement_allowed(Direction, Current, Draft) of
                ok ->
                    Target = case Direction of
                                 next_step -> adjacent_step(Current, 1);
                                 previous_step -> adjacent_step(Current, -1)
                             end,
                    update(Id, #{current_step => Target});
                {error, Reason} ->
                    {error, Reason}
            end;
        not_found ->
            {error, not_found}
    end.

movement_allowed(next_step, device, Draft) ->
    case selected_device(Draft) of
        {ok, _Device} -> ok;
        not_selected -> {error, device_required};
        {error, _Reason} -> {error, selected_device_missing}
    end;
movement_allowed(next_step, security_profile, Draft) ->
    case selected_security_profile(Draft) of
        {ok, Profile} ->
            case security_profile_compatibility(Profile) of
                {blocked, Reason} -> {error, Reason};
                _ -> ok
            end;
        not_selected -> {error, security_profile_required};
        {error, _Reason} -> {error, selected_security_profile_missing}
    end;
movement_allowed(_Direction, _Current, _Draft) ->
    ok.

valid_device(undefined) ->
    {error, device_required};
valid_device(<<>>) ->
    {error, device_required};
valid_device(DeviceId) ->
    case ias_demo_store:get(normalize_id(DeviceId)) of
        {ok, #{kind := device} = Device} -> {ok, Device};
        {ok, _Other} -> {error, invalid_device};
        not_found -> {error, selected_device_missing}
    end.

valid_security_profile(undefined) ->
    {error, security_profile_required};
valid_security_profile(<<>>) ->
    {error, security_profile_required};
valid_security_profile(ProfileId) ->
    case ias_security_profile:profile(normalize_id(ProfileId)) of
        {ok, Profile} -> {ok, Profile};
        not_found -> {error, selected_security_profile_missing}
    end.

adjacent_step(Current, Delta) ->
    StepList = steps(),
    case step_index(Current) of
        not_found ->
            scheme;
        Index ->
            NewIndex = clamp(Index + Delta, 1, length(StepList)),
            lists:nth(NewIndex, StepList)
    end.

step_index(Step) ->
    step_index(Step, steps(), 1).

step_index(_Step, [], _Index) ->
    not_found;
step_index(Step, [Step | _Rest], Index) ->
    Index;
step_index(Step, [_Other | Rest], Index) ->
    step_index(Step, Rest, Index + 1).

clamp(Value, Min, _Max) when Value < Min ->
    Min;
clamp(Value, _Min, Max) when Value > Max ->
    Max;
clamp(Value, _Min, _Max) ->
    Value.

normalize_updates(Updates) ->
    CurrentStep = maps:get(current_step, Updates, undefined),
    case CurrentStep of
        undefined ->
            {ok, maps:without([id, created_at], Updates)};
        _ ->
            case lists:member(CurrentStep, steps()) of
                true -> {ok, maps:without([id, created_at], Updates)};
                false -> {error, invalid_step}
            end
    end.

normalize_id(Id) when is_binary(Id) ->
    Id;
normalize_id(Id) when is_list(Id) ->
    unicode:characters_to_binary(Id);
normalize_id(Id) ->
    ias_html:text(Id).

wizard_id() ->
    ias_html:join([<<"provisioning_wizard_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive])]).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).

ensure() ->
    case ets:info(?TABLE) of
        undefined ->
            ensure_owner(),
            wait_table(20);
        _ ->
            ok
    end.

ensure_owner() ->
    case whereis(?OWNER) of
        undefined ->
            spawn(fun table_owner/0),
            ok;
        _Pid ->
            ok
    end.

wait_table(0) ->
    case ets:info(?TABLE) of
        undefined -> error({provisioning_wizard_store_unavailable, ?TABLE});
        _ -> ok
    end;
wait_table(Attempts) ->
    case ets:info(?TABLE) of
        undefined ->
            timer:sleep(5),
            wait_table(Attempts - 1);
        _ ->
            ok
    end.

table_owner() ->
    case catch register(?OWNER, self()) of
        true ->
            ensure_owner_table(),
            table_owner_loop();
        _ ->
            ok
    end.

ensure_owner_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.

table_owner_loop() ->
    receive
        stop -> ok;
        _ -> table_owner_loop()
    end.
