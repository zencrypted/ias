-module(ias_relationship_constraints).
-export([check_create/3,
         status/3,
         certificate_material_role/1,
         operational_conflicts/0,
         device_conflicts/1,
         service_conflicts/1,
         conflict_reasons/1]).

check_create(RelationType, Source, Target) ->
    case exact_relationship(RelationType, Source, Target) of
        not_found ->
            create_status(RelationType, Source, Target);
        Relationship ->
            {linked, Relationship}
    end.

status(RelationType, Source, Target) ->
    check_create(RelationType, Source, Target).

certificate_material_role(#{kind := certificate} = Certificate) ->
    role_from_material_store(Certificate);
certificate_material_role(_Certificate) ->
    unknown.

operational_conflicts() ->
    #{devices_with_multiple_certificates => ambiguous_device_certificates(),
      devices_with_multiple_vpn_services => ambiguous_device_services(),
      vpn_services_with_multiple_ca_certificates => ambiguous_service_ca_certificates()}.

device_conflicts(DeviceId) ->
    Conflicts = operational_conflicts(),
    [Conflict || Conflict <- maps:get(devices_with_multiple_certificates, Conflicts, []),
                 maps:get(device_id, Conflict, undefined) =:= DeviceId] ++
    [Conflict || Conflict <- maps:get(devices_with_multiple_vpn_services, Conflicts, []),
                 maps:get(device_id, Conflict, undefined) =:= DeviceId].

service_conflicts(ServiceId) ->
    Conflicts = operational_conflicts(),
    [Conflict || Conflict <- maps:get(vpn_services_with_multiple_ca_certificates, Conflicts, []),
                 maps:get(vpn_service_id, Conflict, undefined) =:= ServiceId].

conflict_reasons(Conflicts) ->
    [conflict_reason(Conflict) || Conflict <- Conflicts].

create_status(uses_certificate, #{kind := device} = Device,
              #{kind := certificate} = Certificate) ->
    case existing_single_target(uses_certificate, Device, certificate) of
        {ok, ExistingId, Relationship} ->
            {blocked, already_linked(uses_certificate, Device, certificate,
                                     ExistingId, Relationship)};
        not_found ->
            role_status(uses_certificate, Certificate)
    end;
create_status(uses_service, #{kind := device} = Device,
              #{kind := vpn_service}) ->
    case existing_device_service(Device) of
        {ok, ExistingId, Relationship} ->
            {blocked, already_linked(uses_service, Device, vpn_service,
                                     ExistingId, Relationship)};
        not_found ->
            {ok, []}
    end;
create_status(uses_ca_certificate, #{kind := vpn_service} = Service,
              #{kind := certificate} = Certificate) ->
    case existing_single_target(uses_ca_certificate, Service, certificate) of
        {ok, ExistingId, Relationship} ->
            {blocked, already_linked(uses_ca_certificate, Service, certificate,
                                     ExistingId, Relationship)};
        not_found ->
            role_status(uses_ca_certificate, Certificate)
    end;
create_status(_RelationType, _Source, _Target) ->
    {ok, []}.

role_status(uses_certificate, Certificate) ->
    case certificate_material_role(Certificate) of
        client_certificate ->
            {ok, []};
        ca_certificate ->
            {blocked, #{reason => incompatible_certificate_role,
                        expected_role => client_certificate,
                        actual_role => ca_certificate,
                        existing_target_id => not_found,
                        message => <<"CA certificate cannot be linked as a device client certificate">>}};
        unknown ->
            {ok, [#{warning => unclassified_certificate_role,
                    message => <<"certificate role is unclassified; link is allowed but should be reviewed">>}]}
    end;
role_status(uses_ca_certificate, Certificate) ->
    case certificate_material_role(Certificate) of
        ca_certificate ->
            {ok, []};
        client_certificate ->
            {blocked, #{reason => incompatible_certificate_role,
                        expected_role => ca_certificate,
                        actual_role => client_certificate,
                        existing_target_id => not_found,
                        message => <<"client certificate cannot be linked as a VPN service CA certificate">>}};
        unknown ->
            {ok, [#{warning => unclassified_certificate_role,
                    message => <<"certificate role is unclassified; link is allowed but should be reviewed">>}]}
    end.

already_linked(RelationType, Source, TargetKind, ExistingId, Relationship) ->
    #{reason => already_has_operational_relationship,
      relation_type => RelationType,
      source_kind => maps:get(kind, Source, undefined),
      source_id => maps:get(id, Source, undefined),
      target_kind => TargetKind,
      existing_target_id => ExistingId,
      existing_relationship_id => maps:get(id, Relationship, undefined),
      message => already_linked_message(RelationType, ExistingId)}.

already_linked_message(uses_certificate, ExistingId) ->
    ias_html:join([<<"device already has active certificate ">>, ias_html:text(ExistingId)]);
already_linked_message(uses_service, ExistingId) ->
    ias_html:join([<<"device already has active VPN service ">>, ias_html:text(ExistingId)]);
already_linked_message(uses_ca_certificate, ExistingId) ->
    ias_html:join([<<"VPN service already has active CA certificate ">>, ias_html:text(ExistingId)]);
already_linked_message(_RelationType, ExistingId) ->
    ias_html:join([<<"object already linked to ">>, ias_html:text(ExistingId)]).

role_from_material_store(Certificate) ->
    Id = maps:get(id, Certificate, undefined),
    case ias_certificate_material:status(Id) of
        {ok, #{material_type := Role}} when Role =:= ca_certificate;
                                           Role =:= client_certificate ->
            Role;
        _ ->
            role_from_metadata(Certificate)
    end.

role_from_metadata(Certificate) ->
    case maps:get(material_type, Certificate, undefined) of
        ca_certificate -> ca_certificate;
        client_certificate -> client_certificate;
        _ -> role_from_source(Certificate)
    end.

role_from_source(#{source := ca_certificate}) ->
    ca_certificate;
role_from_source(#{source := certificate_issue_demo}) ->
    client_certificate;
role_from_source(#{source := cmp_demo_enrollment}) ->
    client_certificate;
role_from_source(#{source := ovpn_demo_import}) ->
    client_certificate;
role_from_source(#{client_certificate_present := true}) ->
    client_certificate;
role_from_source(_Certificate) ->
    unknown.

exact_relationship(RelationType, Source, Target) ->
    SourceKind = maps:get(kind, Source, undefined),
    SourceId = maps:get(id, Source, undefined),
    TargetKind = maps:get(kind, Target, undefined),
    TargetId = maps:get(id, Target, undefined),
    case [Relationship || Relationship <- ias_demo_store:relationships(),
                          maps:get(relation_type, Relationship, undefined) =:= RelationType,
                          maps:get(source_kind, Relationship, undefined) =:= SourceKind,
                          maps:get(source_id, Relationship, undefined) =:= SourceId,
                          maps:get(target_kind, Relationship, undefined) =:= TargetKind,
                          maps:get(target_id, Relationship, undefined) =:= TargetId] of
        [Relationship | _] -> Relationship;
        [] -> not_found
    end.

existing_single_target(RelationType, Source, TargetKind) ->
    SourceKind = maps:get(kind, Source, undefined),
    SourceId = maps:get(id, Source, undefined),
    case [Relationship || Relationship <- ias_demo_store:relationships(),
                          maps:get(relation_type, Relationship, undefined) =:= RelationType,
                          maps:get(source_kind, Relationship, undefined) =:= SourceKind,
                          maps:get(source_id, Relationship, undefined) =:= SourceId,
                          maps:get(target_kind, Relationship, undefined) =:= TargetKind] of
        [Relationship | _] ->
            {ok, maps:get(target_id, Relationship, undefined), Relationship};
        [] ->
            not_found
    end.

existing_device_service(Device) ->
    DeviceId = maps:get(id, Device, undefined),
    case [Relationship || Relationship <- ias_demo_store:relationships(),
                          maps:get(source_kind, Relationship, undefined) =:= device,
                          maps:get(source_id, Relationship, undefined) =:= DeviceId,
                          maps:get(target_kind, Relationship, undefined) =:= vpn_service,
                          service_relation(maps:get(relation_type, Relationship, undefined))] of
        [Relationship | _] ->
            {ok, maps:get(target_id, Relationship, undefined), Relationship};
        [] ->
            not_found
    end.

ambiguous_device_certificates() ->
    [#{kind => device,
       id => DeviceId,
       device_id => DeviceId,
       certificate_ids => TargetIds}
     || #{id := DeviceId} <- ias_demo_store:devices(),
        TargetIds <- [linked_targets(uses_certificate, device, DeviceId, certificate)],
        length(TargetIds) > 1].

ambiguous_device_services() ->
    [#{kind => device,
       id => DeviceId,
       device_id => DeviceId,
       vpn_service_ids => TargetIds}
     || #{id := DeviceId} <- ias_demo_store:devices(),
        TargetIds <- [linked_service_targets(DeviceId)],
        length(TargetIds) > 1].

ambiguous_service_ca_certificates() ->
    [#{kind => vpn_service,
       id => ServiceId,
       vpn_service_id => ServiceId,
       certificate_ids => TargetIds}
     || #{id := ServiceId} <- ias_demo_store:services(),
        TargetIds <- [linked_targets(uses_ca_certificate, vpn_service, ServiceId, certificate)],
        length(TargetIds) > 1].

linked_targets(RelationType, SourceKind, SourceId, TargetKind) ->
    unique([maps:get(target_id, Relationship, undefined)
            || Relationship <- ias_demo_store:relationships(),
               maps:get(relation_type, Relationship, undefined) =:= RelationType,
               maps:get(source_kind, Relationship, undefined) =:= SourceKind,
               maps:get(source_id, Relationship, undefined) =:= SourceId,
               maps:get(target_kind, Relationship, undefined) =:= TargetKind,
               resolves(maps:get(target_id, Relationship, undefined), TargetKind)]).

linked_service_targets(DeviceId) ->
    unique([maps:get(target_id, Relationship, undefined)
            || Relationship <- ias_demo_store:relationships(),
               maps:get(source_kind, Relationship, undefined) =:= device,
               maps:get(source_id, Relationship, undefined) =:= DeviceId,
               maps:get(target_kind, Relationship, undefined) =:= vpn_service,
               service_relation(maps:get(relation_type, Relationship, undefined)),
               resolves(maps:get(target_id, Relationship, undefined), vpn_service)]).

unique(Values) ->
    unique(Values, []).

unique([], Acc) ->
    lists:reverse(Acc);
unique([Value | Rest], Acc) ->
    case lists:member(Value, Acc) of
        true -> unique(Rest, Acc);
        false -> unique(Rest, [Value | Acc])
    end.

service_relation(uses_service) -> true;
service_relation(uses_vpn_service) -> true;
service_relation(_RelationType) -> false.

resolves(Id, Kind) ->
    case ias_demo_store:get(Id) of
        {ok, #{kind := Kind}} -> true;
        _ -> false
    end.

conflict_reason(#{certificate_ids := Ids}) ->
    ias_html:join([<<"ambiguous device certificates: ">>, ias_html:join_csv(Ids)]);
conflict_reason(#{vpn_service_ids := Ids}) ->
    ias_html:join([<<"ambiguous device VPN services: ">>, ias_html:join_csv(Ids)]);
conflict_reason(#{vpn_service_id := ServiceId, certificate_ids := Ids}) ->
    ias_html:join([<<"ambiguous VPN service CA certificates for ">>,
                   ias_html:text(ServiceId), <<": ">>, ias_html:join_csv(Ids)]);
conflict_reason(_Conflict) ->
    <<"ambiguous operational relationship">>.
