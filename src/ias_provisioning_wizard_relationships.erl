-module(ias_provisioning_wizard_relationships).
-export([review/1, apply/1, ready/1]).

review(Draft) when is_map(Draft) ->
    Items = [review_item(Item, Draft) || Item <- required_relationships(Draft)],
    #{items => Items,
      can_apply => lists:all(fun applicable_item/1, Items),
      ready => lists:all(fun linked_item/1, Items)};
review(_Draft) ->
    #{items => [], can_apply => false, ready => false, error => invalid_draft}.

ready(Draft) ->
    maps:get(ready, review(Draft), false).

apply(Draft) when is_map(Draft) ->
    Review = review(Draft),
    case maps:get(can_apply, Review, false) of
        false ->
            {error, {relationship_preflight_failed, Review}};
        true ->
            ExistingIds = relationship_ids(),
            case apply_items(maps:get(items, Review, []), ExistingIds, []) of
                {ok, _Created} ->
                    AppliedReview = review(Draft),
                    case maps:get(ready, AppliedReview, false) of
                        true -> {ok, AppliedReview};
                        false -> {error, {relationship_apply_incomplete, AppliedReview}}
                    end;
                {error, Reason, CreatedIds} ->
                    rollback(CreatedIds),
                    {error, Reason}
            end
    end;
apply(_Draft) ->
    {error, invalid_draft}.

required_relationships(Draft) ->
    DeviceId = maps:get(device_id, Draft, undefined),
    ProfileId = maps:get(security_profile_id, Draft, undefined),
    ServiceId = maps:get(vpn_service_id, Draft, undefined),
    CaCertificateId = maps:get(ca_certificate_id, Draft, undefined),
    ClientCertificateId = maps:get(client_certificate_id, Draft, undefined),
    PolicyId = ias_provisioning_wizard_authorization:derived_policy_id(Draft),
    [relationship(device_security_profile, uses_security_profile,
                  device, DeviceId, security_profile, ProfileId),
     relationship(device_security_policy, uses_security_policy,
                  device, DeviceId, security_policy, PolicyId),
     relationship(device_vpn_service, uses_service,
                  device, DeviceId, vpn_service, ServiceId),
     relationship(device_client_certificate, uses_certificate,
                  device, DeviceId, certificate, ClientCertificateId),
     relationship(client_certificate_security_policy, uses_security_policy,
                  certificate, ClientCertificateId, security_policy, PolicyId),
     relationship(vpn_service_ca_certificate, uses_ca_certificate,
                  vpn_service, ServiceId, certificate, CaCertificateId)].

relationship(Key, RelationType, SourceKind, SourceId, TargetKind, TargetId) ->
    #{key => Key,
      relation_type => RelationType,
      source_kind => SourceKind,
      source_id => SourceId,
      target_kind => TargetKind,
      target_id => TargetId}.

review_item(Item, Draft) ->
    SourceKind = maps:get(source_kind, Item),
    SourceId = maps:get(source_id, Item),
    TargetKind = maps:get(target_kind, Item),
    TargetId = maps:get(target_id, Item),
    case {resolve_reference(SourceKind, SourceId),
          resolve_reference(TargetKind, TargetId)} of
        {{ok, Source}, {ok, Target}} ->
            review_resolved(Item#{source_label => object_label(Source),
                                  target_label => object_label(Target)}, Draft);
        {{error, Reason}, _} ->
            reference_error(Item, source, Reason);
        {_, {error, Reason}} ->
            reference_error(Item, target, Reason)
    end.

review_resolved(#{key := device_client_certificate} = Item, Draft) ->
    case client_certificate_binding(Draft) of
        ok -> review_operational(Item);
        {error, DeviceIds} ->
            Item#{status => conflict,
                  existing_target_ids => DeviceIds,
                  notes => ias_html:join([
                      <<"Client Certificate is already linked to another Device: ">>,
                      ias_html:join_csv(DeviceIds)])}
    end;
review_resolved(#{relation_type := uses_security_profile} = Item, _Draft) ->
    profile_review(Item);
review_resolved(#{relation_type := uses_security_policy} = Item, _Draft) ->
    security_policy_review(Item);
review_resolved(Item, _Draft) ->
    review_operational(Item).

review_operational(Item) ->
    RelationType = maps:get(relation_type, Item),
    SourceId = maps:get(source_id, Item),
    TargetId = maps:get(target_id, Item),
    case ias_relationship_link:status(RelationType, SourceId, TargetId) of
        link ->
            Item#{status => will_create, notes => <<"-">>};
        {link_warning, Warnings} ->
            Item#{status => will_create, warnings => Warnings,
                  notes => warning_notes(Warnings)};
        {linked, Relationship} ->
            Item#{status => already_linked,
                  relationship_id => maps:get(id, Relationship, undefined),
                  notes => <<"-">>};
        {blocked, #{reason := already_has_operational_relationship,
                    existing_target_id := ExistingTargetId} = Reason} ->
            case same_id(ExistingTargetId, TargetId) of
                true ->
                    Item#{status => already_linked, reason => Reason,
                          relationship_id => maps:get(existing_relationship_id, Reason, undefined),
                          notes => <<"Existing compatible operational link">>};
                false ->
                    Item#{status => conflict, reason => Reason,
                          notes => reason_text(Reason)}
            end;
        {blocked, Reason} ->
            Item#{status => conflict, reason => Reason,
                  notes => reason_text(Reason)};
        not_found ->
            Item#{status => invalid,
                  notes => <<"Relationship type is not supported for the selected objects">>};
        Other ->
            Item#{status => invalid, reason => Other,
                  notes => term_text(Other)}
    end.


security_policy_review(Item) ->
    SourceId = maps:get(source_id, Item),
    TargetId = maps:get(target_id, Item),
    case ias_relationship_link:status(uses_security_policy, SourceId, TargetId) of
        link ->
            Item#{status => will_create, notes => <<"-">>};
        {linked, Relationship} ->
            Item#{status => already_linked,
                  relationship_id => maps:get(id, Relationship, undefined),
                  notes => <<"-">>};
        {already_has_policy, ExistingPolicyId, Relationship} ->
            Item#{status => conflict,
                  relationship_id => maps:get(id, Relationship, undefined),
                  existing_target_ids => [ExistingPolicyId],
                  notes => ias_html:join([
                      <<"Object already uses a different Security Policy: ">>,
                      ias_html:text(ExistingPolicyId)])};
        not_found ->
            Item#{status => invalid,
                  notes => <<"Security Policy relationship is not supported for the selected objects">>};
        Other ->
            Item#{status => invalid, reason => Other,
                  notes => term_text(Other)}
    end.

client_certificate_binding(Draft) ->
    CertificateId = maps:get(client_certificate_id, Draft, undefined),
    SelectedDeviceId = maps:get(device_id, Draft, undefined),
    DeviceIds = lists:usort([
        maps:get(source_id, Relationship, undefined)
        || Relationship <- ias_demo_store:relationships(),
           maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
           maps:get(source_kind, Relationship, undefined) =:= device,
           same_id(maps:get(target_id, Relationship, undefined), CertificateId),
           not same_id(maps:get(source_id, Relationship, undefined), SelectedDeviceId)
    ]),
    case DeviceIds of
        [] -> ok;
        _ -> {error, DeviceIds}
    end.

profile_review(Item) ->
    SourceId = maps:get(source_id, Item),
    TargetId = maps:get(target_id, Item),
    case exact_relationship(uses_security_profile, SourceId, TargetId) of
        {ok, Relationship} ->
            Item#{status => already_linked,
                  relationship_id => maps:get(id, Relationship, undefined),
                  notes => <<"-">>};
        not_found ->
            case other_profile_relationships(SourceId, TargetId) of
                [] ->
                    Item#{status => will_create, notes => <<"-">>};
                Relationships ->
                    ExistingIds = [maps:get(target_id, Relationship, undefined)
                                   || Relationship <- Relationships],
                    Item#{status => conflict,
                          existing_target_ids => ExistingIds,
                          notes => ias_html:join([
                              <<"Device already has a different Security Profile: ">>,
                              ias_html:join_csv(ExistingIds)])}
            end
    end.

resolve_reference(_Kind, undefined) ->
    {error, not_selected};
resolve_reference(_Kind, <<>>) ->
    {error, not_selected};
resolve_reference(Kind, Id) ->
    case ias_demo_store:get(Id) of
        {ok, #{kind := Kind} = Object} -> {ok, Object};
        {ok, _Other} -> {error, invalid_kind};
        not_found -> {error, missing}
    end.

reference_error(Item, Side, not_selected) ->
    Item#{status => invalid,
          notes => ias_html:join([reference_side(Side), <<" is not selected">>])};
reference_error(Item, Side, missing) ->
    Item#{status => stale_reference,
          notes => ias_html:join([reference_side(Side), <<" no longer exists">>])};
reference_error(Item, Side, invalid_kind) ->
    Item#{status => invalid,
          notes => ias_html:join([reference_side(Side), <<" has an unexpected object kind">>])}.

reference_side(source) -> <<"Source object">>;
reference_side(target) -> <<"Target object">>.

applicable_item(#{status := will_create}) -> true;
applicable_item(#{status := already_linked}) -> true;
applicable_item(_) -> false.

linked_item(#{status := already_linked}) -> true;
linked_item(_) -> false.

apply_items([], _ExistingIds, CreatedIds) ->
    {ok, lists:reverse(CreatedIds)};
apply_items([#{status := already_linked} | Rest], ExistingIds, CreatedIds) ->
    apply_items(Rest, ExistingIds, CreatedIds);
apply_items([#{status := will_create} = Item | Rest], ExistingIds, CreatedIds) ->
    RelationType = maps:get(relation_type, Item),
    SourceId = maps:get(source_id, Item),
    TargetId = maps:get(target_id, Item),
    case ias_relationship_link:create(RelationType, SourceId, TargetId) of
        {ok, Relationship} ->
            RelationshipId = maps:get(id, Relationship, undefined),
            NewCreatedIds = case lists:member(RelationshipId, ExistingIds) of
                                true -> CreatedIds;
                                false -> [RelationshipId | CreatedIds]
                            end,
            apply_items(Rest, ExistingIds, NewCreatedIds);
        {error, Reason} ->
            {error, {relationship_apply_failed, maps:get(key, Item), Reason},
             CreatedIds}
    end.

rollback(RelationshipIds) ->
    [ias_demo_store:delete_relationship(RelationshipId)
     || RelationshipId <- RelationshipIds,
        RelationshipId =/= undefined],
    ok.

relationship_ids() ->
    [maps:get(id, Relationship, undefined)
     || Relationship <- ias_demo_store:relationships()].

exact_relationship(RelationType, SourceId, TargetId) ->
    case [Relationship || Relationship <- ias_demo_store:relationships(),
                          maps:get(relation_type, Relationship, undefined) =:= RelationType,
                          same_id(maps:get(source_id, Relationship, undefined), SourceId),
                          same_id(maps:get(target_id, Relationship, undefined), TargetId)] of
        [Relationship | _] -> {ok, Relationship};
        [] -> not_found
    end.

other_profile_relationships(SourceId, TargetId) ->
    [Relationship || Relationship <- ias_demo_store:relationships(),
                     maps:get(relation_type, Relationship, undefined) =:= uses_security_profile,
                     maps:get(source_kind, Relationship, undefined) =:= device,
                     same_id(maps:get(source_id, Relationship, undefined), SourceId),
                     not same_id(maps:get(target_id, Relationship, undefined), TargetId)].

same_id(Left, Right) ->
    ias_html:text(Left) =:= ias_html:text(Right).

object_label(Object) ->
    First = first_defined([maps:get(name, Object, undefined),
                           maps:get(subject_cn, Object, undefined),
                           maps:get(subject, Object, undefined),
                           maps:get(profile, Object, undefined),
                           maps:get(id, Object, undefined)]),
    ias_html:text(First).

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([<<>> | Rest]) -> first_defined(Rest);
first_defined([Value | _Rest]) -> Value.

warning_notes([]) -> <<"-">>;
warning_notes(Warnings) ->
    ias_html:join_csv([maps:get(message, Warning,
                               maps:get(warning, Warning, undefined))
                       || Warning <- Warnings]).

reason_text(#{message := Message}) -> ias_html:text(Message);
reason_text(Reason) -> term_text(Reason).

term_text(Value) when is_binary(Value); is_atom(Value); is_integer(Value);
                      is_float(Value); is_list(Value) ->
    ias_html:text(Value);
term_text(Value) ->
    iolist_to_binary(io_lib:format("~tp", [Value])).
