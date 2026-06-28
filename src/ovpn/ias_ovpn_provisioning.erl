-module(ias_ovpn_provisioning).
-export([preview/3,
         prepare/3,
         create/3,
         get/1,
         refresh/1,
         artifact_filename/1]).

-define(TTL_SECONDS, 900).

preview(portable, certificate, CertificateId) ->
    Preview = portable_readiness(
        ias_ovpn_export:portable_certificate_preview(CertificateId)),
    export_plan(portable, certificate, CertificateId, Preview);
preview(device_bound, device, DeviceId) ->
    ExportPreview = ias_ovpn_export:device_preview(DeviceId),
    Provisioning = ias_ovpn_export:device_provisioning_preview(DeviceId),
    Preview = ExportPreview#{
        authorization => maps:get(provisioning, Provisioning, deny),
        authorization_reason => maps:get(provisioning_reason, Provisioning,
                                         <<"device-bound OVPN provisioning unavailable">>),
        certificate_id => maps:get(current_certificate_id, Provisioning,
                                   maps:get(certificate_id, ExportPreview, not_found)),
        vpn_service_id => maps:get(vpn_service_id, Provisioning,
                                   maps:get(vpn_service_id, ExportPreview, not_found))
    },
    export_plan(device_bound, device, DeviceId, Preview);
preview(Mode, SubjectKind, SubjectId) ->
    blocked_plan(Mode, SubjectKind, SubjectId,
                 <<"unsupported OVPN provisioning mode or subject">>).

prepare(Mode, SubjectKind, SubjectId) ->
    Plan = preview(Mode, SubjectKind, SubjectId),
    case maps:get(authorization, Plan, deny) of
        allow ->
            Now = erlang:system_time(second),
            Id = provisioning_id(),
            {ok,
             Plan#{id => Id,
                   provisioning_id => Id,
                   kind => ovpn_provisioning,
                   source => ovpn_provisioning_demo,
                   created_at => timestamp(Now),
                   expires_at => timestamp(Now + ?TTL_SECONDS),
                   downloaded => false,
                   private_key_stored => false,
                   certificate_body_stored => false,
                   ca_body_stored => false}};
        _ ->
            {error, maps:get(authorization_reason, Plan,
                             <<"OVPN provisioning denied">>)}
    end.

create(Mode, SubjectKind, SubjectId) ->
    case prepare(Mode, SubjectKind, SubjectId) of
        {ok, Transaction} ->
            {ok, ias_demo_store:put_runtime_object(Transaction)};
        {error, _} = Error ->
            Error
    end.

get(ProvisioningId) ->
    case ias_demo_store:get(ProvisioningId) of
        {ok, #{kind := ovpn_provisioning} = Transaction} ->
            {ok, refresh(Transaction)};
        _ ->
            not_found
    end.

refresh(#{kind := ovpn_provisioning} = Transaction) ->
    Mode = maps:get(mode, Transaction, undefined),
    Authorization = maps:get(authorization, Transaction, deny),
    Components = material_components_from_transaction(Mode, Transaction, Authorization),
    ArtifactStatus = refreshed_artifact_status(Mode, Components, Authorization),
    Transaction#{material_components => Components,
                 status => refreshed_transaction_status(Mode, Components, Authorization),
                 material_status => refreshed_material_status(Components, Authorization),
                 assembly_status => refreshed_assembly_status(Mode, Components, Authorization),
                 assembly_reason => refreshed_assembly_reason(Mode, Components,
                                                               Authorization, Transaction),
                 next_step => assembly_next_step_for(Mode, Components, Authorization),
                 artifact_status => ArtifactStatus,
                 delivery_status => refreshed_delivery_status(ArtifactStatus),
                 artifact_filename => refreshed_artifact_filename(Mode, Transaction,
                                                                  ArtifactStatus)};
refresh(Transaction) ->
    Transaction.

portable_readiness(Preview) ->
    AuthorizationReasons = case maps:get(authorization, Preview, deny) of
        allow -> [];
        _ -> [maps:get(authorization_reason, Preview, <<"OVPN provisioning denied">>)]
    end,
    EndpointReasons = case {maps:get(remote_host, Preview, <<"not found">>),
                            maps:get(remote_port, Preview, <<"not found">>)} of
        {<<"not found">>, _} -> [<<"no vpn endpoint">>];
        {_, <<"not found">>} -> [<<"no vpn endpoint">>];
        _ -> []
    end,
    CaReasons = case maps:get(ca_certificate_id, Preview, not_found) of
        not_found -> [<<"no CA certificate">>];
        _ -> []
    end,
    Reasons = unique_reasons(AuthorizationReasons ++ EndpointReasons ++ CaReasons),
    case Reasons of
        [] -> Preview;
        _ -> Preview#{authorization => deny,
                     authorization_reason => reason_text(Reasons)}
    end.

unique_reasons(Reasons) ->
    unique_reasons(Reasons, [], []).

unique_reasons([], _Seen, Acc) ->
    lists:reverse(Acc);
unique_reasons([Reason | Rest], Seen, Acc) ->
    Text = ias_html:text(Reason),
    case lists:member(Text, Seen) of
        true -> unique_reasons(Rest, Seen, Acc);
        false -> unique_reasons(Rest, [Text | Seen], [Text | Acc])
    end.

reason_text([]) ->
    <<"OVPN provisioning denied">>;
reason_text([Reason]) ->
    ias_html:text(Reason);
reason_text(Reasons) ->
    ias_html:join(lists:join(<<"; ">>, [ias_html:text(Reason) || Reason <- Reasons])).

export_plan(Mode, SubjectKind, SubjectId, Preview) ->
    Authorization = maps:get(authorization, Preview, deny),
    Reason = maps:get(authorization_reason, Preview, <<"OVPN provisioning denied">>),
    refresh(#{kind => ovpn_provisioning,
      mode => Mode,
      subject_kind => SubjectKind,
      subject_id => ias_html:text(SubjectId),
      device_id => maps:get(device_id, Preview, not_found),
      certificate_id => maps:get(certificate_id, Preview, not_found),
      vpn_service_id => maps:get(vpn_service_id, Preview, not_found),
      ca_certificate_id => maps:get(ca_certificate_id, Preview, not_found),
      authorization => Authorization,
      authorization_reason => ias_html:text(Reason),
      status => transaction_status(Authorization),
      material_status => material_status(Authorization),
      material_requirements => material_requirements(Mode),
      material_sources => material_sources(Mode),
      material_components => material_components(Mode, Preview, Authorization),
      assembly_status => assembly_status(Authorization),
      assembly_reason => assembly_reason(Mode, Preview, Authorization),
      next_step => assembly_next_step(Authorization),
      artifact_status => artifact_status(Authorization),
      delivery_status => not_ready,
      private_key_policy => private_key_policy(Mode),
      private_key_provider => maps:get(private_key_provider, Preview, undefined),
      private_key_ref => maps:get(private_key_ref, Preview, undefined),
      certificate_validation_mode => ias_x509_validation:mode(),
      certificate_validation_bypass => ias_x509_validation:mode() =:= development,
      downloaded => false,
      private_key_stored => false,
      certificate_body_stored => false,
      ca_body_stored => false}).

blocked_plan(Mode, SubjectKind, SubjectId, Reason) ->
    #{mode => Mode,
      subject_kind => SubjectKind,
      subject_id => ias_html:text(SubjectId),
      device_id => not_found,
      certificate_id => not_found,
      vpn_service_id => not_found,
      ca_certificate_id => not_found,
      authorization => deny,
      authorization_reason => ias_html:text(Reason),
      status => blocked,
      material_status => blocked,
      material_requirements => material_requirements(Mode),
      material_sources => material_sources(Mode),
      material_components => blocked_material_components(Mode),
      assembly_status => blocked,
      assembly_reason => ias_html:text(Reason),
      next_step => <<"Resolve OVPN provisioning authorization before material assembly.">>,
      artifact_status => unavailable,
      delivery_status => not_ready,
      private_key_policy => private_key_policy(Mode),
      private_key_provider => undefined,
      private_key_ref => undefined,
      certificate_validation_mode => ias_x509_validation:mode(),
      certificate_validation_bypass => ias_x509_validation:mode() =:= development,
      downloaded => false,
      private_key_stored => false,
      certificate_body_stored => false,
      ca_body_stored => false}.

transaction_status(allow) ->
    awaiting_material;
transaction_status(_Authorization) ->
    blocked.

material_status(allow) ->
    pending_real_material;
material_status(_Authorization) ->
    blocked.

artifact_status(allow) ->
    skeleton_only;
artifact_status(_Authorization) ->
    unavailable.

material_requirements(Mode) ->
    #{ca_certificate => required,
      client_certificate => required,
      private_key => private_key_requirement(Mode),
      tls_auth => optional}.

material_sources(Mode) ->
    #{ca_certificate => ca_certificate_store,
      client_certificate => certificate_store,
      private_key => private_key_source(Mode),
      tls_auth => vpn_service}.

material_components(Mode, Preview, allow) ->
    #{ca_certificate => referenced_material_status(
          maps:get(ca_certificate_id, Preview, not_found)),
      client_certificate => referenced_material_status(
          maps:get(certificate_id, Preview, not_found)),
      private_key => private_key_component_status(Mode, Preview),
      tls_auth => not_configured};
material_components(Mode, _Preview, _Authorization) ->
    blocked_material_components(Mode).

blocked_material_components(Mode) ->
    #{ca_certificate => blocked,
      client_certificate => blocked,
      private_key => blocked_private_key_status(Mode),
      tls_auth => blocked}.

referenced_material_status(not_found) ->
    not_linked;
referenced_material_status(Id) ->
    case ias_certificate_material:status(Id) of
        {ok, _} -> available;
        not_found -> missing_body
    end.

assembly_status(Authorization) ->
    assembly_status_for(undefined, #{}, Authorization).

assembly_reason(Mode, Preview, Authorization) ->
    Components = material_components(Mode, Preview, Authorization),
    assembly_reason_for(Mode, Components, Authorization).

assembly_next_step(Authorization) ->
    assembly_next_step_for(undefined, #{}, Authorization).

material_components_from_transaction(Mode, Transaction, allow) ->
    #{ca_certificate => referenced_material_status(
          maps:get(ca_certificate_id, Transaction, not_found)),
      client_certificate => referenced_material_status(
          maps:get(certificate_id, Transaction, not_found)),
      private_key => private_key_component_status(Mode, Transaction),
      tls_auth => maps:get(tls_auth, maps:get(material_components, Transaction, #{}),
                           not_configured)};
material_components_from_transaction(Mode, _Transaction, _Authorization) ->
    blocked_material_components(Mode).



refreshed_assembly_reason(_Mode, _Components, Authorization, Transaction)
  when Authorization =/= allow ->
    ias_html:text(maps:get(authorization_reason, Transaction,
                           <<"OVPN provisioning authorization is denied">>));
refreshed_assembly_reason(Mode, Components, allow, _Transaction) ->
    assembly_reason_for(Mode, Components, allow).

refreshed_material_status(_Components, Authorization) when Authorization =/= allow -> blocked;
refreshed_material_status(Components, allow) ->
    case public_material_available(Components) of
        true -> public_material_available;
        false -> pending_real_material
    end.

refreshed_transaction_status(Mode, Components, allow) ->
    case artifact_ready(Mode, Components) of
        true -> ready_for_delivery;
        false -> awaiting_material
    end;
refreshed_transaction_status(_Mode, _Components, _Authorization) ->
    blocked.

refreshed_assembly_status(Mode, Components, allow) ->
    case artifact_ready(Mode, Components) of
        true -> public_bundle_ready;
        false -> assembly_status_for(Mode, Components, allow)
    end;
refreshed_assembly_status(Mode, Components, Authorization) ->
    assembly_status_for(Mode, Components, Authorization).

refreshed_artifact_status(Mode, Components, allow) ->
    case artifact_ready(Mode, Components) of
        true -> public_bundle_ready;
        false -> artifact_status(allow)
    end;
refreshed_artifact_status(_Mode, _Components, _Authorization) ->
    unavailable.

refreshed_delivery_status(public_bundle_ready) ->
    ready_for_device_import;
refreshed_delivery_status(_ArtifactStatus) ->
    not_ready.

refreshed_artifact_filename(device_bound, Transaction, public_bundle_ready) ->
    artifact_filename(maps:get(device_id, Transaction,
                               maps:get(subject_id, Transaction, <<"device">>)));
refreshed_artifact_filename(_Mode, Transaction, _ArtifactStatus) ->
    maps:get(artifact_filename, Transaction, undefined).

artifact_ready(device_bound, Components) ->
    public_material_available(Components) andalso private_key_available(Components);
artifact_ready(_Mode, _Components) ->
    false.

assembly_status_for(_Mode, _Components, Authorization) when Authorization =/= allow -> blocked;
assembly_status_for(device_bound, Components, allow) ->
    case public_material_available(Components) andalso private_key_available(Components) of
        true -> ready_for_device_assembly;
        false -> blocked
    end;
assembly_status_for(portable, Components, allow) ->
    case public_material_available(Components) of
        true -> awaiting_private_key_generation;
        false -> blocked
    end;
assembly_status_for(_, _, _) -> blocked.

assembly_reason_for(_Mode, _Components, Authorization) when Authorization =/= allow ->
    <<"OVPN provisioning authorization is denied">>;
assembly_reason_for(device_bound, Components, allow) ->
    case missing_public_material_reasons(Components) ++ missing_private_key_reasons(Components) of
        [] -> <<"public certificate material is available; assembly remains on the device">>;
        Reasons -> reason_text(Reasons)
    end;
assembly_reason_for(portable, Components, allow) ->
    case missing_public_material_reasons(Components) of
        [] -> <<"public certificate material is available; one-time private key generation is pending">>;
        Reasons -> reason_text(Reasons ++ [<<"one-time private key generation is pending">>])
    end;
assembly_reason_for(_, Components, allow) -> reason_text(missing_public_material_reasons(Components)).

assembly_next_step_for(_Mode, _Components, Authorization) when Authorization =/= allow ->
    <<"Resolve OVPN provisioning authorization before material assembly.">>;
assembly_next_step_for(device_bound, Components, allow) ->
    case public_material_available(Components) andalso private_key_available(Components) of
        true -> <<"Send the public OVPN bundle to the device for local private-key assembly.">>;
        false -> <<"Load public certificate material and configure the device-owned private-key reference.">>
    end;
assembly_next_step_for(portable, Components, allow) ->
    case public_material_available(Components) of
        true -> <<"Generate the one-time private key and CSR in a later provisioning stage.">>;
        false -> <<"Load public certificate material from the CA/CMP response or certificate store.">>
    end;
assembly_next_step_for(_, _, _) -> <<"Load required OVPN material.">>.

public_material_available(Components) ->
    maps:get(ca_certificate, Components, missing_body) =:= available andalso
    maps:get(client_certificate, Components, missing_body) =:= available.

private_key_available(Components) ->
    maps:get(private_key, Components, unavailable) =:= available_on_device.

missing_public_material_reasons(Components) ->
    Ca = case maps:get(ca_certificate, Components, missing_body) of
        available -> [];
        not_linked -> [<<"CA certificate is not linked">>];
        _ -> [<<"CA certificate PEM is unavailable">>]
    end,
    Cert = case maps:get(client_certificate, Components, missing_body) of
        available -> [];
        not_linked -> [<<"client certificate is not linked">>];
        _ -> [<<"client certificate PEM is unavailable">>]
    end,
    Ca ++ Cert.

missing_private_key_reasons(Components) ->
    case maps:get(private_key, Components, unavailable) of
        available_on_device -> [];
        missing_private_key_ref -> [<<"Device-owned private key reference is missing.">>];
        unsupported_private_key_provider -> [<<"Device-owned private key provider is unsupported.">>];
        invalid_private_key_ref -> [<<"Device-owned private key reference is invalid.">>];
        _ -> [<<"Device-owned private key reference is missing.">>]
    end.

private_key_requirement(portable) -> pending_one_time_generation;
private_key_requirement(device_bound) -> device_owned;
private_key_requirement(_Mode) -> undefined.

private_key_source(portable) -> provisioning_transaction;
private_key_source(device_bound) -> device;
private_key_source(_Mode) -> undefined.

private_key_component_status(portable, _Context) -> pending_one_time_generation;
private_key_component_status(device_bound, Context) ->
    DeviceId = maps:get(device_id, Context, undefined),
    case ias_device_key_ref:status(DeviceId) of
        {ok, Safe} ->
            case maps:get(private_key_provider, Safe, undefined) of
                <<"device_file">> -> available_on_device;
                _ -> unsupported_private_key_provider
            end;
        {error, missing_private_key_ref} -> missing_private_key_ref;
        {error, <<"Private Key Provider must be device_file">>} -> unsupported_private_key_provider;
        {error, <<"Private Key Provider is required">>} -> unsupported_private_key_provider;
        {error, _Reason} -> invalid_private_key_ref
    end;
private_key_component_status(_Mode, _Context) -> unavailable.

blocked_private_key_status(portable) -> pending_one_time_generation;
blocked_private_key_status(device_bound) -> device_owned;
blocked_private_key_status(_Mode) -> blocked.

private_key_policy(portable) ->
    one_time_in_memory;
private_key_policy(device_bound) ->
    device_owned;
private_key_policy(_Mode) ->
    undefined.

provisioning_id() ->
    ias_html:join([<<"ovpn_provisioning_">>,
                   erlang:system_time(millisecond), <<"_">>,
                   erlang:unique_integer([positive, monotonic])]).

timestamp(SystemTime) ->
    iolist_to_binary(calendar:system_time_to_rfc3339(SystemTime, [{unit, second}])).

artifact_filename(SubjectId) ->
    SafeId = safe_filename_part(ias_html:text(SubjectId)),
    ias_html:join([SafeId, <<".ovpn">>]).

safe_filename_part(Value) ->
    << <<(safe_filename_char(Char))>> || <<Char>> <= Value >>.

safe_filename_char(Char) when Char >= $a, Char =< $z -> Char;
safe_filename_char(Char) when Char >= $A, Char =< $Z -> Char;
safe_filename_char(Char) when Char >= $0, Char =< $9 -> Char;
safe_filename_char($_) -> $_;
safe_filename_char($-) -> $-;
safe_filename_char($.) -> $.;
safe_filename_char(_) -> $_.
