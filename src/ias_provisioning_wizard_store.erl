-module(ias_provisioning_wizard_store).
-compile({no_auto_import,[get/1]}).
-export([new/1,
         all/0,
         restore/1,
         get/1,
         update/2,
         delete/1,
         clear/0,
         rehydrate/0,
         project_committed_draft/1,
         abandon/1,
         next/1,
         back/1,
         select_user/2,
         select_existing_user/2,
         selected_user/1,
         select_device/2,
         select_existing_device/2,
         selected_device/1,
         select_security_profile/2,
         select_existing_security_profile/2,
         selected_security_profile/1,
         security_profile_compatibility/1,
         select_vpn_service/2,
         select_existing_vpn_service/2,
         selected_vpn_service/1,
         select_ca_certificate/2,
         select_existing_ca_certificate/2,
         selected_ca_certificate/1,
         select_client_certificate/2,
         select_existing_client_certificate/2,
         selected_client_certificate/1,
         prepare_device_csr_plan/1,
         regenerate_device_csr_plan/1,
         relationship_review/1,
         apply_relationships/1,
         relationships_ready/1,
         material_readiness/1,
         material_readiness_ready/1,
         remediate_readiness/1,
         create_provisioning/1,
         create_another_provisioning/1,
         provisioning_transaction/1,
         steps/0,
         step_title/1,
         step_description/1,
         portable_enabled/0,
         portable_reason/0,
         ovpn_import_url/0,
         clear_vpn_allocation_for_device/1]).

-define(TABLE, ias_provisioning_wizard_drafts).
-define(OWNER, ias_provisioning_wizard_store_owner).

new(device_bound) ->
    ensure(),
    Now = created_at(),
    Id = wizard_id(),
    Draft = #{
        id => Id,
        scenario => device_bound,
        current_step => user,
        user_id => undefined,
        device_id => undefined,
        security_profile_id => undefined,
        vpn_service_id => undefined,
        ca_certificate_id => undefined,
        client_certificate_id => undefined,
        pending_private_key_reference => undefined,
        pending_csr_filename => undefined,
        pending_enrollment_common_name => undefined,
        vpn_allocation_id => undefined,
        vpn_allocator_instance_id => undefined,
        vpn_client_peer_id => undefined,
        vpn_gateway_peer_id => undefined,
        vpn_allocation_slot => undefined,
        vpn_allocation_generation => undefined,
        vpn_allocation_state => undefined,
        vpn_allocation_persistence => undefined,
        vpn_allocation_created_at => undefined,
        relationships_applied => false,
        provisioning_id => undefined,
        completed => false,
        completed_at => undefined,
        created_at => Now,
        updated_at => Now
    },
    persist_and_project(Draft);
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
            case get(Id) of
                not_found -> persist_and_project(SafeDraft);
                {ok, _} -> {error, duplicate_id}
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
                    persist_and_project(Updated);
                {error, Reason} ->
                    {error, Reason}
            end;
        not_found ->
            {error, not_found}
    end.

delete(Id) ->
    ensure(),
    TextId = normalize_id(Id),
    case ias_provisioning_wizard_draft_store:delete(TextId) of
        ok -> ets:delete(?TABLE, TextId), ok;
        {error, _} = Error -> Error
    end.

clear() ->
    ensure(),
    case ias_provisioning_wizard_draft_store:reset() of
        ok -> ets:delete_all_objects(?TABLE), ok;
        {error, _} = Error -> Error
    end.

rehydrate() ->
    ensure(),
    case ias_provisioning_wizard_draft_store:all() of
        {ok, Drafts} ->
            ets:delete_all_objects(?TABLE),
            true = ets:insert(?TABLE, [{maps:get(id, Draft), Draft} || Draft <- Drafts]),
            {ok, length(Drafts)};
        {error, _} = Error -> Error
    end.

%% Project a draft that has already committed together with domain records.
project_committed_draft(#{id := Id} = Draft) ->
    ensure(),
    true = ets:insert(?TABLE, {normalize_id(Id), Draft}),
    {ok, Draft};
project_committed_draft(_Draft) ->
    {error, invalid_wizard_draft}.

abandon(Id) ->
    case get(Id) of
        {ok, Draft} ->
            Updated = Draft#{abandoned => true,
                             abandoned_at => created_at(),
                             completed => false,
                             completed_at => undefined,
                             updated_at => created_at()},
            persist_and_project(Updated);
        not_found -> {error, not_found}
    end.

clear_vpn_allocation_for_device(DeviceId0) ->
    ensure(),
    DeviceId = normalize_id(DeviceId0),
    Drafts = [Draft || {_Id, Draft} <- ets:tab2list(?TABLE),
                       normalize_id(maps:get(device_id, Draft, undefined)) =:= DeviceId],
    lists:foreach(
      fun(Draft) ->
          Updated = (maps:merge(Draft, clear_vpn_allocation_updates()))#{
              updated_at => created_at()
          },
          {ok, _} = persist_and_project(Updated)
      end,
      Drafts),
    {ok, length(Drafts)}.

next(Id) ->
    case get(Id) of
        {ok, #{current_step := client_certificate} = Draft} ->
            advance_from_client_certificate(Id, Draft);
        {ok, _Draft} ->
            move(Id, next_step);
        not_found ->
            {error, not_found}
    end.

back(Id) ->
    move(Id, previous_step).

select_user(Id, UserId) ->
    case valid_user(UserId) of
        {ok, User} ->
            update(Id, reset_completion(maps:merge(
                         clear_vpn_allocation_updates(),
                         #{user_id => maps:get(id, User),
                           device_id => undefined,
                           client_certificate_id => undefined,
                           relationships_applied => false})));
        {error, Reason} ->
            {error, Reason}
    end.

select_existing_user(Id, UserId) ->
    auto_advance_after_selection(Id, user, select_user(Id, UserId)).

selected_user(Draft) when is_map(Draft) ->
    case maps:get(user_id, Draft, undefined) of
        undefined -> not_selected;
        UserId -> valid_user(UserId)
    end.

select_device(Id, DeviceId) ->
    case {get(Id), valid_device(DeviceId)} of
        {{ok, Draft}, {ok, Device0}} ->
            SelectedUser = maps:get(user_id, Draft, undefined),
            Owner0 = maps:get(owner, Device0, undefined),
            case resolve_device_owner(SelectedUser, Owner0) of
                {ok, Owner} ->
                    Device = maybe_claim_device(Device0, Owner),
                    CurrentStep = case maps:get(current_step, Draft, user) of
                                      user -> device;
                                      Step -> Step
                                  end,
                    update(Id, reset_completion(maps:merge(
                                 clear_vpn_allocation_updates(),
                                 #{user_id => Owner,
                                   device_id => maps:get(id, Device),
                                   current_step => CurrentStep,
                                   pending_private_key_reference => undefined,
                                   pending_csr_filename => undefined,
                                   pending_enrollment_common_name => undefined,
                                   relationships_applied => false})));
                {error, Reason} -> {error, Reason}
            end;
        {not_found, _} -> {error, not_found};
        {_, {error, Reason}} -> {error, Reason}
    end.

clear_vpn_allocation_updates() ->
    #{vpn_allocation_id => undefined,
      vpn_allocator_instance_id => undefined,
      vpn_client_peer_id => undefined,
      vpn_gateway_peer_id => undefined,
      vpn_allocation_slot => undefined,
      vpn_allocation_generation => undefined,
      vpn_allocation_state => undefined,
      vpn_allocation_persistence => undefined,
      vpn_allocation_created_at => undefined}.

resolve_device_owner(undefined, undefined) ->
    case ias_demo_store:users() of
        [User | _] -> {ok, maps:get(id, User)};
        [] -> {error, user_required}
    end;
resolve_device_owner(UserId, undefined) when UserId =/= undefined -> {ok, UserId};
resolve_device_owner(undefined, Owner) when Owner =/= undefined -> {ok, Owner};
resolve_device_owner(UserId, UserId) when UserId =/= undefined -> {ok, UserId};
resolve_device_owner(_UserId, _Owner) -> {error, device_belongs_to_other_user}.

maybe_claim_device(#{owner := Owner} = Device, Owner) -> Device;
maybe_claim_device(Device, Owner) ->
    Updated = Device#{owner => Owner},
    ias_demo_store:put_runtime_object(Updated).

select_existing_device(Id, DeviceId) ->
    auto_advance_after_selection(Id, device, select_device(Id, DeviceId)).

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
                _ -> update(Id, reset_completion(#{security_profile_id => maps:get(id, Profile),
                                           relationships_applied => false}))
            end;
        {error, Reason} ->
            {error, Reason}
    end.

select_existing_security_profile(Id, ProfileId) ->
    case valid_security_profile(ProfileId) of
        {ok, Profile} ->
            case security_profile_compatibility(Profile) of
                compatible ->
                    auto_advance_after_selection(
                        Id, security_profile, select_security_profile(Id, ProfileId));
                {warning, Reason} ->
                    case select_security_profile(Id, ProfileId) of
                        {ok, Draft} -> {ok, Draft};
                        {error, _} -> {error, Reason}
                    end;
                {blocked, Reason} ->
                    {error, Reason}
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
        {ok, Service} -> update(Id, reset_completion(#{vpn_service_id => maps:get(id, Service),
                                           relationships_applied => false}));
        {error, Reason} -> {error, Reason}
    end.

select_existing_vpn_service(Id, ServiceId) ->
    auto_advance_after_selection(Id, vpn_service, select_vpn_service(Id, ServiceId)).

selected_vpn_service(Draft) when is_map(Draft) ->
    case maps:get(vpn_service_id, Draft, undefined) of
        undefined -> not_selected;
        ServiceId -> valid_vpn_service(ServiceId)
    end.

select_ca_certificate(Id, CertificateId) ->
    case valid_ca_certificate(CertificateId) of
        {ok, Certificate} -> update(Id, reset_completion(#{ca_certificate_id => maps:get(id, Certificate),
                                           relationships_applied => false}));
        {error, Reason} -> {error, Reason}
    end.

select_existing_ca_certificate(Id, CertificateId) ->
    case select_ca_certificate(Id, CertificateId) of
        {ok, Draft} ->
            case movement_allowed(next_step, ca_certificate, Draft) of
                ok -> auto_advance_after_selection(Id, ca_certificate, {ok, Draft});
                {error, _Reason} -> {ok, Draft}
            end;
        {error, Reason} ->
            {error, Reason}
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
                        ok -> update(Id, reset_completion(#{client_certificate_id => maps:get(id, Certificate),
                                                 relationships_applied => false}));
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        not_found ->
            {error, not_found}
    end.

select_existing_client_certificate(Id, CertificateId) ->
    case select_client_certificate(Id, CertificateId) of
        {ok, Draft} ->
            case movement_allowed(next_step, client_certificate, Draft) of
                ok -> commit_relationships_or_review(Id, Draft);
                {error, _Reason} -> {ok, Draft}
            end;
        {error, Reason} ->
            {error, Reason}
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

prepare_device_csr_plan(Id) ->
    prepare_or_replace_device_csr_plan(Id).

regenerate_device_csr_plan(Id) ->
    prepare_or_replace_device_csr_plan(Id).

prepare_or_replace_device_csr_plan(Id) ->
    case get(Id) of
        {ok, Draft} ->
            case selected_device(Draft) of
                {ok, Device} ->
                    case reserve_vpn_allocation(Device) of
                        {ok, AllocationUpdates} ->
                            case ias_device_csr_command:generate(Device) of
                                {ok, Plan} ->
                                    update(Id, maps:merge(AllocationUpdates, #{
                                        pending_private_key_reference => maps:get(private_key_ref, Plan),
                                        pending_csr_filename => maps:get(csr_filename, Plan),
                                        pending_enrollment_common_name => maps:get(common_name, Plan)
                                    }));
                                {error, Reason} ->
                                    {error, Reason}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                not_selected ->
                    {error, device_required};
                {error, _Reason} ->
                    {error, selected_device_missing}
            end;
        not_found ->
            {error, not_found}
    end.


reserve_vpn_allocation(Device) ->
    case ias_vpn_allocation:ensure(maps:get(id, Device)) of
        disabled ->
            {ok, #{}};
        {ok, Allocation} ->
            {ok, vpn_allocation_draft_updates(Allocation)};
        {error, Reason} ->
            {error, Reason}
    end.

vpn_allocation_draft_updates(Allocation) ->
    #{vpn_allocation_id => maps:get(allocation_id, Allocation),
      vpn_allocator_instance_id => maps:get(allocator_instance_id, Allocation),
      vpn_client_peer_id => maps:get(client_peer_id, Allocation),
      vpn_gateway_peer_id => maps:get(gateway_peer_id, Allocation),
      vpn_allocation_slot => maps:get(slot, Allocation),
      vpn_allocation_generation => maps:get(generation, Allocation),
      vpn_allocation_state => maps:get(state, Allocation),
      vpn_allocation_persistence => maps:get(persistence, Allocation),
      vpn_allocation_created_at => maps:get(created_at, Allocation, undefined)}.

relationship_review(Draft) when is_map(Draft) ->
    ias_provisioning_wizard_relationships:review(Draft);
relationship_review(_Draft) ->
    #{items => [], can_apply => false, ready => false, error => invalid_draft}.

relationships_ready(Draft) when is_map(Draft) ->
    ias_provisioning_wizard_relationships:ready(Draft);
relationships_ready(_Draft) ->
    false.

material_readiness(Draft) when is_map(Draft) ->
    ias_provisioning_wizard_readiness:preview(Draft);
material_readiness(_Draft) ->
    ias_provisioning_wizard_readiness:preview(#{}).

material_readiness_ready(Draft) when is_map(Draft) ->
    ias_provisioning_wizard_readiness:ready(Draft);
material_readiness_ready(_Draft) ->
    false.

create_provisioning(Id) ->
    case get(Id) of
        {ok, Draft} ->
            case provisioning_transaction(Draft) of
                {ok, Transaction} -> {ok, Draft, Transaction};
                not_found ->
                    case maps:get(provisioning_id, Draft, undefined) of
                        undefined -> create_new_provisioning(Draft);
                        _ -> {error, provisioning_transaction_missing}
                    end
            end;
        not_found ->
            {error, not_found}
    end.

create_another_provisioning(Id) ->
    case get(Id) of
        {ok, Draft} -> create_new_provisioning(Draft);
        not_found -> {error, not_found}
    end.

provisioning_transaction(Draft) when is_map(Draft) ->
    case maps:get(provisioning_id, Draft, undefined) of
        undefined -> not_found;
        <<>> -> not_found;
        ProvisioningId -> ias_ovpn_provisioning:get(ProvisioningId)
    end;
provisioning_transaction(_Draft) ->
    not_found.

create_new_provisioning(Draft) ->
    case material_readiness_ready(Draft) of
        false ->
            {error, material_readiness_blocked};
        true ->
            DeviceId = maps:get(device_id, Draft, undefined),
            case ias_ovpn_provisioning:prepare(device_bound, device, DeviceId) of
                {ok, Transaction} ->
                    case provisioning_matches_draft(Transaction, Draft) of
                        true -> persist_provisioning_result(Draft, Transaction);
                        false -> {error, provisioning_reference_mismatch}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

persist_provisioning_result(Draft, Transaction) ->
    ProvisioningId = maps:get(id, Transaction),
    Now = created_at(),
    Completed = (maps:merge(
                   Draft,
                   #{provisioning_id => ProvisioningId,
                     completed => true,
                     completed_at => Now,
                     current_step => provisioning}))#{updated_at => Now},
    case ias_provisioning_wizard_completion:commit(
           Draft, Completed, Transaction) of
        {ok, Updated, StoredTransaction, _Changes} ->
            {ok, Updated, StoredTransaction};
        {error, Reason} ->
            {error, Reason}
    end.

provisioning_matches_draft(Transaction, Draft) ->
    same_reference(maps:get(device_id, Transaction, undefined),
                   maps:get(device_id, Draft, undefined)) andalso
    same_reference(maps:get(vpn_service_id, Transaction, undefined),
                   maps:get(vpn_service_id, Draft, undefined)) andalso
    same_reference(maps:get(ca_certificate_id, Transaction, undefined),
                   maps:get(ca_certificate_id, Draft, undefined)) andalso
    same_reference(maps:get(certificate_id, Transaction, undefined),
                   maps:get(client_certificate_id, Draft, undefined)).

same_reference(Left, Right) ->
    normalize_id(Left) =:= normalize_id(Right).

reset_completion(Updates) ->
    Updates#{provisioning_id => undefined,
             completed => false,
             completed_at => undefined}.

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
     user,
     device,
     security_profile,
     vpn_service,
     ca_certificate,
     client_certificate,
     relationships,
     material_readiness,
     provisioning].

step_title(scheme) -> <<"Scheme">>;
step_title(user) -> <<"User">>;
step_title(device) -> <<"Device">>;
step_title(security_profile) -> <<"Security Profile & Policy">>;
step_title(vpn_service) -> <<"VPN Service">>;
step_title(ca_certificate) -> <<"CA Certificate">>;
step_title(client_certificate) -> <<"Client Certificate">>;
step_title(relationships) -> <<"Relationships">>;
step_title(material_readiness) -> <<"Material Readiness">>;
step_title(provisioning) -> <<"Provisioning">>;
step_title(Step) -> ias_html:text(Step).

step_description(scheme) ->
    <<"Choose the provisioning scenario. Stage 24A enables device-bound VPN profile orchestration only.">>;
step_description(user) ->
    <<"Select the IAS User who owns the Device and receives VPN access.">>;
step_description(device) ->
    <<"Select an existing runtime Device or create a new demo Device that will own the VPN profile.">>;
step_description(security_profile) ->
    <<"Select the Security Profile. The wizard derives its Security Policy and will apply both to the Device and Client Certificate after the certificate step.">>;
step_description(vpn_service) ->
    <<"Choose the VPN Service endpoint that will supply remote/protocol settings.">>;
step_description(ca_certificate) ->
    <<"Choose the CA trust anchor used by the VPN service.">>;
step_description(client_certificate) ->
    <<"Choose the device-bound client certificate. Continuing automatically commits the prepared relationships when preflight succeeds.">>;
step_description(relationships) ->
    <<"Review relationship conflicts or retry the automatic graph commit. Successful flows normally continue directly to Material Readiness.">>;
step_description(material_readiness) ->
    <<"Check public certificate material and assembly readiness before provisioning.">>;
step_description(provisioning) ->
    <<"Review the final device-bound inputs and create one idempotent OVPN provisioning transaction.">>;
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

auto_advance_after_selection(Id, ExpectedStep, {ok, #{current_step := ExpectedStep}}) ->
    move(Id, next_step);
auto_advance_after_selection(_Id, _ExpectedStep, {ok, Draft}) ->
    {ok, Draft};
auto_advance_after_selection(_Id, _ExpectedStep, {error, Reason}) ->
    {error, Reason}.

advance_from_client_certificate(Id, Draft) ->
    case movement_allowed(next_step, client_certificate, Draft) of
        ok ->
            commit_relationships_or_review(Id, Draft);
        {error, Reason} ->
            {error, Reason}
    end.

commit_relationships_or_review(Id, Draft) ->
    Review = relationship_review(Draft),
    case {maps:get(ready, Review, false), maps:get(can_apply, Review, false)} of
        {true, _} ->
            enter_material_readiness(Id);
        {false, true} ->
            case ias_provisioning_wizard_relationships:apply(Draft) of
                {ok, _AppliedReview} ->
                    enter_material_readiness(Id);
                {error, _Reason} ->
                    update(Id, #{relationships_applied => false,
                                 current_step => relationships})
            end;
        _ ->
            update(Id, #{relationships_applied => false,
                         current_step => relationships})
    end.

remediate_readiness(Id) ->
    case get(Id) of
        {ok, Draft0} ->
            case ensure_relationships(Draft0) of
                {ok, Draft1} ->
                    maybe_auto_verify(Draft1),
                    current_draft(Id, Draft1);
                {blocked, Draft1} ->
                    current_draft(Id, Draft1)
            end;
        not_found ->
            {error, not_found}
    end.

enter_material_readiness(Id) ->
    case get(Id) of
        {ok, _Draft0} ->
            update(Id, #{relationships_applied => true,
                         current_step => material_readiness});
        not_found ->
            {error, not_found}
    end.

ensure_relationships(Draft) ->
    Id = maps:get(id, Draft),
    Review = relationship_review(Draft),
    case {maps:get(ready, Review, false), maps:get(can_apply, Review, false)} of
        {true, _} ->
            sync_relationship_marker(Id, Draft, true, ok);
        {false, true} ->
            case ias_provisioning_wizard_relationships:apply(Draft) of
                {ok, _AppliedReview} ->
                    sync_relationship_marker(Id, Draft, true, ok);
                {error, _Reason} ->
                    sync_relationship_marker(Id, Draft, false, blocked)
            end;
        _ ->
            sync_relationship_marker(Id, Draft, false, blocked)
    end.

sync_relationship_marker(Id, Draft, Value, Result) ->
    case maps:get(relationships_applied, Draft, false) =:= Value of
        true ->
            case Result of
                ok -> {ok, Draft};
                blocked -> {blocked, Draft}
            end;
        false ->
            case update(Id, #{relationships_applied => Value}) of
                {ok, Updated} ->
                    case Result of
                        ok -> {ok, Updated};
                        blocked -> {blocked, Updated}
                    end;
                {error, _Reason} ->
                    case Result of
                        ok -> {ok, Draft};
                        blocked -> {blocked, Draft}
                    end
            end
    end.

maybe_auto_verify(Draft) ->
    case ias_provisioning_wizard_authorization:verification_status(Draft) of
        not_verified ->
            _ = ias_provisioning_wizard_authorization:verify_client_certificate(Draft),
            ok;
        _ ->
            ok
    end.

current_draft(Id, Fallback) ->
    case get(Id) of
        {ok, Draft} -> {ok, Draft};
        not_found -> {ok, Fallback}
    end.

movement_allowed(next_step, user, Draft) ->
    case selected_user(Draft) of
        {ok, _User} -> ok;
        not_selected -> {error, user_required};
        {error, _Reason} -> {error, selected_user_missing}
    end;
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
movement_allowed(next_step, material_readiness, Draft) ->
    case material_readiness_ready(Draft) of
        true -> ok;
        false -> {error, material_readiness_blocked}
    end;
movement_allowed(_Direction, _Current, _Draft) ->
    ok.

valid_user(undefined) ->
    {error, user_required};
valid_user(<<>>) ->
    {error, user_required};
valid_user(UserId) ->
    case ias_demo_store:get(normalize_id(UserId)) of
        {ok, #{kind := user} = User} -> {ok, User};
        {ok, _Other} -> {error, invalid_user};
        not_found -> {error, selected_user_missing}
    end.

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
    Allowed = [id, scenario, current_step, user_id, device_id, security_profile_id,
               vpn_service_id, ca_certificate_id, client_certificate_id,
               pending_private_key_reference, pending_csr_filename,
               pending_enrollment_common_name,
               vpn_allocation_id, vpn_allocator_instance_id,
               vpn_client_peer_id, vpn_gateway_peer_id,
               vpn_allocation_slot, vpn_allocation_generation,
               vpn_allocation_state, vpn_allocation_persistence,
               vpn_allocation_created_at,
               relationships_applied, provisioning_id, completed,
               completed_at, abandoned, abandoned_at, created_at, updated_at],
    Selected = maps:with(Allowed, Draft),
    Safe = Selected#{relationships_applied =>
                         maps:get(relationships_applied, Selected, false),
                     provisioning_id => maps:get(provisioning_id, Selected, undefined),
                     completed => maps:get(completed, Selected, false),
                     completed_at => maps:get(completed_at, Selected, undefined),
                     abandoned => maps:get(abandoned, Selected, false),
                     abandoned_at => maps:get(abandoned_at, Selected, undefined)},
    case {maps:get(id, Safe, undefined),
          maps:get(scenario, Safe, undefined),
          maps:get(current_step, Safe, undefined)} of
        {Id, device_bound, Step} ->
            case usable_restore_id(Id) andalso lists:member(Step, steps())
                 andalso valid_optional_user_reference(maps:get(user_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(device_id, Safe, undefined))
                 andalso valid_optional_profile_reference(maps:get(security_profile_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(vpn_service_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(ca_certificate_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(client_certificate_id, Safe, undefined))
                 andalso valid_optional_private_key_ref(maps:get(pending_private_key_reference, Safe, undefined))
                 andalso valid_optional_reference(maps:get(pending_csr_filename, Safe, undefined))
                 andalso valid_optional_reference(maps:get(pending_enrollment_common_name, Safe, undefined))
                 andalso valid_optional_reference(maps:get(vpn_allocation_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(vpn_allocator_instance_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(vpn_client_peer_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(vpn_gateway_peer_id, Safe, undefined))
                 andalso valid_optional_positive_integer(maps:get(vpn_allocation_slot, Safe, undefined))
                 andalso valid_optional_positive_integer(maps:get(vpn_allocation_generation, Safe, undefined))
                 andalso valid_optional_allocation_state(maps:get(vpn_allocation_state, Safe, undefined))
                 andalso valid_optional_allocation_persistence(maps:get(vpn_allocation_persistence, Safe, undefined))
                 andalso valid_optional_timestamp(maps:get(vpn_allocation_created_at, Safe, undefined))
                 andalso valid_allocation_metadata(Safe)
                 andalso valid_optional_reference(maps:get(provisioning_id, Safe, undefined))
                 andalso valid_optional_reference(maps:get(completed_at, Safe, undefined))
                 andalso is_boolean(maps:get(abandoned, Safe, false))
                 andalso valid_optional_reference(maps:get(abandoned_at, Safe, undefined))
                 andalso is_boolean(maps:get(relationships_applied, Safe, false))
                 andalso valid_completion_state(Safe) of
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

valid_optional_user_reference(undefined) -> true;
valid_optional_user_reference(Id) when is_atom(Id) -> true;
valid_optional_user_reference(Id) -> usable_restore_id(Id).

valid_optional_profile_reference(undefined) -> true;
valid_optional_profile_reference(Id) when is_atom(Id) -> true;
valid_optional_profile_reference(Id) -> usable_restore_id(Id).


valid_optional_positive_integer(undefined) -> true;
valid_optional_positive_integer(Value) -> is_integer(Value) andalso Value > 0.

valid_optional_allocation_state(undefined) -> true;
valid_optional_allocation_state(reserved) -> true;
valid_optional_allocation_state(released) -> true;
valid_optional_allocation_state(_) -> false.

valid_optional_allocation_persistence(undefined) -> true;
valid_optional_allocation_persistence(volatile) -> true;
valid_optional_allocation_persistence(durable) -> true;
valid_optional_allocation_persistence(_) -> false.

valid_optional_timestamp(undefined) -> true;
valid_optional_timestamp(Value) when is_integer(Value) -> Value >= 0;
valid_optional_timestamp(Value) -> usable_restore_id(Value).

valid_allocation_metadata(Draft) ->
    Values = [maps:get(vpn_allocation_id, Draft, undefined),
              maps:get(vpn_allocator_instance_id, Draft, undefined),
              maps:get(vpn_client_peer_id, Draft, undefined),
              maps:get(vpn_gateway_peer_id, Draft, undefined),
              maps:get(vpn_allocation_slot, Draft, undefined),
              maps:get(vpn_allocation_generation, Draft, undefined),
              maps:get(vpn_allocation_state, Draft, undefined),
              maps:get(vpn_allocation_persistence, Draft, undefined)],
    case lists:all(fun(Value) -> Value =:= undefined end, Values) of
        true -> true;
        false -> lists:all(fun(Value) -> Value =/= undefined end, Values)
    end.

valid_optional_private_key_ref(undefined) -> true;
valid_optional_private_key_ref(<<>>) -> true;
valid_optional_private_key_ref(Ref) ->
    case ias_device_key_ref:validate(<<"device_file">>, Ref) of
        {ok, _Safe} -> true;
        {error, _Reason} -> false
    end.

valid_completion_state(Draft) ->
    case maps:get(completed, Draft, false) of
        false -> true;
        true -> usable_restore_id(maps:get(provisioning_id, Draft, undefined));
        _ -> false
    end.

normalize_updates(Updates) ->
    CurrentStep = maps:get(current_step, Updates, undefined),
    case CurrentStep of
        undefined ->
            {ok, maps:without([id, created_at, abandoned, abandoned_at], Updates)};
        _ ->
            case lists:member(CurrentStep, steps()) of
                true -> {ok, maps:without([id, created_at, abandoned, abandoned_at], Updates)};
                false -> {error, invalid_step}
            end
    end.

persist_and_project(Draft) ->
    case ias_provisioning_wizard_draft_store:put(Draft) of
        {ok, Stored, _Change} ->
            ets:insert(?TABLE, {maps:get(id, Stored), Stored}),
            {ok, Stored};
        {error, _} = Error -> Error
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
