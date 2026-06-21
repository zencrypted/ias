-module(ias_provisioning_wizard_store).
-compile({no_auto_import,[get/1]}).
-export([new/1,
         all/0,
         restore/1,
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
         select_vpn_service/2,
         selected_vpn_service/1,
         select_ca_certificate/2,
         selected_ca_certificate/1,
         select_client_certificate/2,
         selected_client_certificate/1,
         relationship_review/1,
         apply_relationships/1,
         relationships_ready/1,
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
        relationships_applied => false,
        created_at => Now,
        updated_at => Now
    },
    ets:insert(?TABLE, {Id, Draft}),
    {ok, Draft};
new(_Scenario) ->
    {error, unsupported_scenario}.

all() ->
    ensure(),
    lists:sort(fun(A, B) -> maps:get(id, A) =< maps:get(id, B) end,
               [Draft || {_Id, Draft} <- ets:tab2list(?TABLE)]).

restore(Draft) when is_map(Draft) ->
    ensure(),
    case validate_restored_draft(Draft) of
        {ok, SafeDraft} ->
            Id = maps:get(id, SafeDraft),
            case ets:insert_new(?TABLE, {Id, SafeDraft}) of
                true -> {ok, SafeDraft};
                false -> {error, duplicate_id}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
restore(_Draft) ->
    {error, invalid_draft}.

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
            update(Id, #{device_id => maps:get(id, Device),
                         relationships_applied => false});
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
                _ -> update(Id, #{security_profile_id => maps:get(id, Profile),
                                   relationships_applied => false})
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

select_vpn_service(Id, ServiceId) ->
    case valid_vpn_service(ServiceId) of
        {ok, Service} -> update(Id, #{vpn_service_id => maps:get(id, Service),
                                        relationships_applied => false});
        {error, Reason} -> {error, Reason}
    end.

selected_vpn_service(Draft) when is_map(Draft) ->
    case maps:get(vpn_service_id, Draft, undefined) of
        undefined -> not_selected;
        ServiceId -> valid_vpn_service(ServiceId)
    end.

select_ca_certificate(Id, CertificateId) ->
    case valid_ca_certificate(CertificateId) of
        {ok, Certificate} -> update(Id, #{ca_certificate_id => maps:get(id, Certificate),
                                            relationships_applied => false});
        {error, Reason} -> {error, Reason}
    end.

selected_ca_certificate(Draft) when is_map(Draft) ->
    case maps:get(ca_certificate_id, Draft, undefined) of
        undefined -> not_selected;
        CertificateId -> valid_ca_certificate(CertificateId)
    end.

select_client_certificate(Id, CertificateId) ->
    case get(Id) of
        {ok, Draft} ->
            case valid_client_certificate(CertificateId) of
                {ok, Certificate} ->
                    case client_certificate_device_status(Certificate, Draft) of
                        ok -> update(Id, #{client_certificate_id => maps:get(id, Certificate),
                                         relationships_applied => false});
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        not_found ->
            {error, not_found}
    end.

selected_client_certificate(Draft) when is_map(Draft) ->
    case maps:get(client_certificate_id, Draft, undefined) of
        undefined -> not_selected;
        CertificateId ->
            case valid_client_certificate(CertificateId) of
                {ok, Certificate} ->
                    case client_certificate_device_status(Certificate, Draft) of
                        ok -> {ok, Certificate};
                        {error, Reason} -> {error, Reason}
                    end;
                Error -> Error
            end
    end.

relationship_review(Draft) when is_map(Draft) ->
    ias_provisioning_wizard_relationships:review(Draft);
relationship_review(_Draft) ->
    #{items => [], can_apply => false, ready => false, error => invalid_draft}.

relationships_ready(Draft) when is_map(Draft) ->
    ias_provisioning_wizard_relationships:ready(Draft);
relationships_ready(_Draft) ->
    false.

apply_relationships(Id) ->
    case get(Id) of
        {ok, Draft} ->
            case ias_provisioning_wizard_relationships:apply(Draft) of
                {ok, _Review} ->
                    update(Id, #{relationships_applied => true});
                {error, Reason} ->
                    {error, Reason}
            end;
        not_found ->
            {error, not_found}
    end.

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
movement_allowed(next_step, vpn_service, Draft) ->
    case selected_vpn_service(Draft) of
        {ok, _Service} -> ok;
        not_selected -> {error, vpn_service_required};
        {error, _Reason} -> {error, selected_vpn_service_missing}
    end;
movement_allowed(next_step, ca_certificate, Draft) ->
    case selected_ca_certificate(Draft) of
        {ok, Certificate} ->
            case ias_certificate_material:status(maps:get(id, Certificate)) of
                {ok, #{material_type := ca_certificate}} -> ok;
                _ -> {error, ca_certificate_material_required}
            end;
        not_selected -> {error, ca_certificate_required};
        {error, _Reason} -> {error, selected_ca_certificate_missing}
    end;
movement_allowed(next_step, client_certificate, Draft) ->
    case selected_client_certificate(Draft) of
        {ok, Certificate} ->
            case ias_certificate_material:status(maps:get(id, Certificate)) of
                {ok, #{material_type := client_certificate}} -> ok;
                _ -> {error, client_certificate_material_required}
            end;
        not_selected -> {error, client_certificate_required};
        {error, client_certificate_linked_to_other_device} ->
            {error, client_certificate_linked_to_other_device};
        {error, invalid_client_certificate} -> {error, invalid_client_certificate};
        {error, _Reason} -> {error, selected_client_certificate_missing}
    end;
movement_allowed(next_step, relationships, Draft) ->
    case relationships_ready(Draft) of
        true -> ok;
        false -> {error, relationships_not_applied}
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

valid_vpn_service(undefined) ->
    {error, vpn_service_required};
valid_vpn_service(<<>>) ->
    {error, vpn_service_required};
valid_vpn_service(ServiceId) ->
    case ias_demo_store:get(normalize_id(ServiceId)) of
        {ok, #{kind := vpn_service} = Service} -> {ok, Service};
        {ok, _Other} -> {error, invalid_vpn_service};
        not_found -> {error, selected_vpn_service_missing}
    end.

valid_ca_certificate(undefined) ->
    {error, ca_certificate_required};
valid_ca_certificate(<<>>) ->
    {error, ca_certificate_required};
valid_ca_certificate(CertificateId) ->
    case ias_demo_store:get(normalize_id(CertificateId)) of
        {ok, #{kind := certificate} = Certificate} ->
            case ca_certificate_role(Certificate) of
                true -> {ok, Certificate};
                false -> {error, invalid_ca_certificate}
            end;
        {ok, _Other} -> {error, invalid_ca_certificate};
        not_found -> {error, selected_ca_certificate_missing}
    end.

ca_certificate_role(#{certificate_role := ca_certificate}) -> true;
ca_certificate_role(#{material_type := ca_certificate}) -> true;
ca_certificate_role(#{source := ca_certificate}) -> true;
ca_certificate_role(_) -> false.

valid_client_certificate(undefined) ->
    {error, client_certificate_required};
valid_client_certificate(<<>>) ->
    {error, client_certificate_required};
valid_client_certificate(CertificateId) ->
    case ias_demo_store:get(normalize_id(CertificateId)) of
        {ok, #{kind := certificate} = Certificate} ->
            case client_certificate_role(Certificate) of
                true -> {ok, Certificate};
                false -> {error, invalid_client_certificate}
            end;
        {ok, _Other} -> {error, invalid_client_certificate};
        not_found -> {error, selected_client_certificate_missing}
    end.

client_certificate_role(#{certificate_role := client_certificate}) -> true;
client_certificate_role(#{material_type := client_certificate}) -> true;
client_certificate_role(#{source := certificate_issue_demo}) -> true;
client_certificate_role(#{source := cmp_demo_enrollment}) -> true;
client_certificate_role(#{source := ovpn_demo_import}) -> true;
client_certificate_role(_) -> false.

client_certificate_device_status(Certificate, Draft) ->
    CertificateId = maps:get(id, Certificate, undefined),
    SelectedDeviceId = maps:get(device_id, Draft, undefined),
    DeviceIds = lists:usort([
        maps:get(source_id, Relationship, undefined)
        || Relationship <- ias_demo_store:relationships(),
           maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
           maps:get(source_kind, Relationship, undefined) =:= device,
           maps:get(target_kind, Relationship, undefined) =:= certificate,
           maps:get(target_id, Relationship, undefined) =:= CertificateId
    ]),
    case DeviceIds of
        [] -> ok;
        [SelectedDeviceId] when SelectedDeviceId =/= undefined -> ok;
        _ -> {error, client_certificate_linked_to_other_device}
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

validate_restored_draft(Draft) ->
    Allowed = [id, scenario, current_step, device_id, security_profile_id,
               vpn_service_id, ca_certificate_id, client_certificate_id,
               relationships_applied, created_at, updated_at],
    Selected = maps:with(Allowed, Draft),
    Safe = Selected#{relationships_applied =>
                         maps:get(relationships_applied, Selected, false)},
    case {maps:get(id, Safe, undefined),
          maps:get(scenario, Safe, undefined),
          maps:get(current_step, Safe, undefined)} of
        {Id, device_bound, Step} ->
            case usable_restore_id(Id) andalso lists:member(Step, steps())
                 andalso valid_optional_reference(maps:get(device_id, Safe, undefined))
                 andalso valid_optional_profile_reference(maps:get(security_profile_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(vpn_service_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(ca_certificate_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(client_certificate_id, Safe, undefined))
                 andalso is_boolean(maps:get(relationships_applied, Safe, false)) of
                true -> {ok, Safe};
                false -> {error, invalid_draft}
            end;
        _ ->
            {error, invalid_draft}
    end.

usable_restore_id(Id) when is_binary(Id) -> byte_size(Id) > 0;
usable_restore_id(Id) when is_list(Id) -> Id =/= [];
usable_restore_id(_) -> false.

valid_optional_reference(undefined) -> true;
valid_optional_reference(Id) -> usable_restore_id(Id).

valid_optional_profile_reference(undefined) -> true;
valid_optional_profile_reference(Id) when is_atom(Id) -> true;
valid_optional_profile_reference(Id) -> usable_restore_id(Id).

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
