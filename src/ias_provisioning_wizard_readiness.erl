-module(ias_provisioning_wizard_readiness).
-export([preview/1, ready/1]).

preview(Draft) when is_map(Draft) ->
    DeviceId = maps:get(device_id, Draft, undefined),
    RelationshipReview = ias_provisioning_wizard_relationships:review(Draft),
    Plan = ias_ovpn_provisioning:preview(device_bound, device, DeviceId),
    ExportPreview = ias_ovpn_export:device_preview(DeviceId),
    ProvisioningPreview = ias_ovpn_export:device_provisioning_preview(DeviceId),
    Components = maps:get(material_components, Plan, #{}),
    ReferenceMatch = references_match(Draft, Plan),
    Items = [
        relationships_item(RelationshipReview),
        security_profile_item(Draft),
        endpoint_item(ExportPreview, ProvisioningPreview),
        certificate_item(ca_certificate, Draft, ExportPreview),
        material_item(ca_certificate_pem, Components),
        certificate_item(client_certificate, Draft, ExportPreview),
        material_item(client_certificate_pem, Components),
        private_key_item(Components),
        tls_auth_item(Draft),
        authorization_item(Plan),
        assembly_item(Plan)
    ],
    Ready = maps:get(ready, RelationshipReview, false)
        andalso ReferenceMatch
        andalso maps:get(authorization, Plan, deny) =:= allow
        andalso maps:get(vpn_endpoint_status, ProvisioningPreview, missing) =:= available
        andalso maps:get(ca_certificate, Components, missing_body) =:= available
        andalso maps:get(client_certificate, Components, missing_body) =:= available
        andalso maps:get(private_key, Components, unavailable) =:= available_on_device
        andalso maps:get(assembly_status, Plan, blocked) =:= ready_for_device_assembly,
    #{ready => Ready,
      reference_match => ReferenceMatch,
      relationship_review => RelationshipReview,
      plan => Plan,
      export_preview => ExportPreview,
      provisioning_preview => ProvisioningPreview,
      items => Items,
      reason => readiness_reason(Ready, ReferenceMatch, RelationshipReview, Plan),
      next_step => maps:get(next_step, Plan,
                            <<"Resolve the blocked material or authorization check.">>)};
preview(_Draft) ->
    #{ready => false,
      reference_match => false,
      relationship_review => #{ready => false},
      plan => #{authorization => deny, assembly_status => blocked},
      items => [],
      reason => <<"Wizard draft is invalid">>,
      next_step => <<"Return to the previous wizard steps and select valid objects.">>}.

ready(Draft) ->
    maps:get(ready, preview(Draft), false).

relationships_item(#{ready := true}) ->
    item(relationships, <<"Relationships">>, ready,
         <<"All required operational relationships are present and consistent.">>);
relationships_item(_Review) ->
    item(relationships, <<"Relationships">>, blocked,
         <<"Required relationships are missing, stale or conflicting.">>).

security_profile_item(Draft) ->
    case ias_provisioning_wizard_store:selected_security_profile(Draft) of
        {ok, Profile} ->
            case ias_provisioning_wizard_store:security_profile_compatibility(Profile) of
                compatible ->
                    item(security_profile, <<"Security Profile">>, compatible,
                         <<"Device-bound profile requirements are satisfied.">>);
                {warning, Reason} ->
                    item(security_profile, <<"Security Profile">>, warning,
                         ias_html:text(Reason));
                {blocked, Reason} ->
                    item(security_profile, <<"Security Profile">>, blocked,
                         ias_html:text(Reason))
            end;
        not_selected ->
            item(security_profile, <<"Security Profile">>, missing,
                 <<"No Security Profile is selected.">>);
        {error, _Reason} ->
            item(security_profile, <<"Security Profile">>, stale_reference,
                 <<"The selected Security Profile no longer exists.">>)
    end.

endpoint_item(ExportPreview, ProvisioningPreview) ->
    case maps:get(vpn_endpoint_status, ProvisioningPreview, missing) of
        available ->
            Host = maps:get(remote_host, ExportPreview, <<"not found">>),
            Port = maps:get(remote_port, ExportPreview, <<"not found">>),
            Protocol = maps:get(protocol, ExportPreview, <<"not found">>),
            item(vpn_endpoint, <<"VPN Endpoint">>, available,
                 ias_html:join([Host, <<":">>, Port, <<" / ">>, Protocol]));
        _ ->
            item(vpn_endpoint, <<"VPN Endpoint">>, missing,
                 <<"The selected VPN Service has no usable endpoint.">>)
    end.

certificate_item(ca_certificate, Draft, ExportPreview) ->
    Status = maps:get(ca_certificate_status, ExportPreview, missing),
    case ias_provisioning_wizard_store:selected_ca_certificate(Draft) of
        {ok, Certificate} ->
            EffectiveStatus = maps:get(certificate_status, Certificate, Status),
            item(ca_certificate, <<"CA Certificate">>, EffectiveStatus,
                 certificate_detail(Certificate));
        not_selected ->
            item(ca_certificate, <<"CA Certificate">>, missing,
                 <<"No CA Certificate is selected.">>);
        {error, _Reason} ->
            item(ca_certificate, <<"CA Certificate">>, stale_reference,
                 <<"The selected CA Certificate no longer exists.">>)
    end;
certificate_item(client_certificate, Draft, ExportPreview) ->
    Status = maps:get(certificate_status, ExportPreview, unknown),
    case ias_provisioning_wizard_store:selected_client_certificate(Draft) of
        {ok, Certificate} ->
            EffectiveStatus = maps:get(certificate_status, Certificate, Status),
            item(client_certificate, <<"Client Certificate">>, EffectiveStatus,
                 certificate_detail(Certificate));
        not_selected ->
            item(client_certificate, <<"Client Certificate">>, missing,
                 <<"No Client Certificate is selected.">>);
        {error, _Reason} ->
            item(client_certificate, <<"Client Certificate">>, stale_reference,
                 <<"The selected Client Certificate is unavailable or invalid.">>)
    end.

material_item(ca_certificate_pem, Components) ->
    Status = maps:get(ca_certificate, Components, missing_body),
    item(ca_certificate_pem, <<"CA Certificate PEM">>, Status,
         material_detail(Status, <<"Public CA certificate material is available.">>));
material_item(client_certificate_pem, Components) ->
    Status = maps:get(client_certificate, Components, missing_body),
    item(client_certificate_pem, <<"Client Certificate PEM">>, Status,
         material_detail(Status, <<"Public client certificate material is available.">>)).

private_key_item(Components) ->
    Status = maps:get(private_key, Components, unavailable),
    item(private_key, <<"Private Key">>, Status,
         case Status of
             available_on_device -> <<"The private key remains owned by the selected Device.">>;
             _ -> <<"The device-owned private-key requirement is not satisfied.">>
         end).

tls_auth_item(Draft) ->
    case ias_provisioning_wizard_store:selected_vpn_service(Draft) of
        {ok, Service} ->
            Status = tls_auth_status(Service),
            item(tls_auth, <<"TLS Auth / TLS Crypt">>, Status,
                 case Status of
                     configured -> <<"Additional TLS key material is configured by the VPN Service.">>;
                     optional -> <<"No TLS auth material is configured; it is optional for this demo flow.">>
                 end);
        _ ->
            item(tls_auth, <<"TLS Auth / TLS Crypt">>, optional,
                 <<"No TLS auth material is configured.">>)
    end.

authorization_item(Plan) ->
    Authorization = maps:get(authorization, Plan, deny),
    item(authorization, <<"Provisioning Authorization">>, Authorization,
         maps:get(authorization_reason, Plan, <<"OVPN provisioning denied">>)).

assembly_item(Plan) ->
    Status = maps:get(assembly_status, Plan, blocked),
    item(assembly, <<"OVPN Assembly">>, Status,
         maps:get(assembly_reason, Plan, <<"Assembly readiness is unavailable">>)).

item(Key, Label, Status, Detail) ->
    #{key => Key, label => Label, status => Status, detail => ias_html:text(Detail)}.

certificate_detail(Certificate) ->
    Id = maps:get(id, Certificate, undefined),
    Name = first_defined([maps:get(name, Certificate, undefined),
                          maps:get(subject_cn, Certificate, undefined),
                          maps:get(subject, Certificate, undefined),
                          Id]),
    ias_html:join([ias_html:text(Name), <<" (">>, ias_html:text(Id), <<")">>]).

material_detail(available, AvailableText) -> AvailableText;
material_detail(not_linked, _AvailableText) -> <<"The certificate is not linked.">>;
material_detail(_Status, _AvailableText) -> <<"Public certificate PEM is unavailable.">>.

tls_auth_status(Service) ->
    Value = maps:get(tls_auth, Service, maps:get(tls_auth_present, Service, not_configured)),
    case Value of
        true -> configured;
        configured -> configured;
        present -> configured;
        enabled -> configured;
        _ -> optional
    end.

references_match(Draft, Plan) ->
    same_id(maps:get(device_id, Draft, undefined), maps:get(device_id, Plan, not_found))
        andalso same_id(maps:get(vpn_service_id, Draft, undefined),
                        maps:get(vpn_service_id, Plan, not_found))
        andalso same_id(maps:get(ca_certificate_id, Draft, undefined),
                        maps:get(ca_certificate_id, Plan, not_found))
        andalso same_id(maps:get(client_certificate_id, Draft, undefined),
                        maps:get(certificate_id, Plan, not_found)).

same_id(undefined, _Right) -> false;
same_id(_Left, not_found) -> false;
same_id(Left, Right) -> ias_html:text(Left) =:= ias_html:text(Right).

readiness_reason(true, _ReferenceMatch, _Relationships, _Plan) ->
    <<"All device-bound authorization, relationship and public-material checks passed.">>;
readiness_reason(false, false, _Relationships, _Plan) ->
    <<"The current operational graph no longer matches the objects selected by this wizard draft.">>;
readiness_reason(false, _ReferenceMatch, #{ready := false}, _Plan) ->
    <<"Required relationships are missing, stale or conflicting.">>;
readiness_reason(false, _ReferenceMatch, _Relationships, Plan) ->
    case maps:get(authorization, Plan, deny) of
        allow -> maps:get(assembly_reason, Plan, <<"Material readiness is blocked">>);
        _ -> maps:get(authorization_reason, Plan, <<"OVPN provisioning is denied">>)
    end.

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([<<>> | Rest]) -> first_defined(Rest);
first_defined([Value | _Rest]) -> Value.
