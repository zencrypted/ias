-module(ias_ovpn_provisioning).
-export([preview/3,
         create/3,
         get/1]).

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

create(Mode, SubjectKind, SubjectId) ->
    Plan = preview(Mode, SubjectKind, SubjectId),
    case maps:get(authorization, Plan, deny) of
        allow ->
            Now = erlang:system_time(second),
            Id = provisioning_id(),
            Transaction = Plan#{
                id => Id,
                provisioning_id => Id,
                kind => ovpn_provisioning,
                source => ovpn_provisioning_demo,
                created_at => timestamp(Now),
                expires_at => timestamp(Now + ?TTL_SECONDS),
                downloaded => false,
                private_key_stored => false,
                certificate_body_stored => false,
                ca_body_stored => false
            },
            {ok, ias_demo_store:put_runtime_object(Transaction)};
        _ ->
            {error, maps:get(authorization_reason, Plan,
                             <<"OVPN provisioning denied">>)}
    end.

get(ProvisioningId) ->
    case ias_demo_store:get(ProvisioningId) of
        {ok, #{kind := ovpn_provisioning} = Transaction} ->
            {ok, Transaction};
        _ ->
            not_found
    end.

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
    #{mode => Mode,
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
      artifact_status => artifact_status(Authorization),
      delivery_status => not_ready,
      private_key_policy => private_key_policy(Mode),
      downloaded => false,
      private_key_stored => false,
      certificate_body_stored => false,
      ca_body_stored => false}.

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
      artifact_status => unavailable,
      delivery_status => not_ready,
      private_key_policy => private_key_policy(Mode),
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
