-module(ias_ovpn_export).
-export([certificate_preview/1,
         device_preview/1,
         ovpn_provisioning_decision/1,
         certificate_artifact/1,
         device_artifact/1,
         export_artifact/1]).


export_artifact(CertificateId) ->
    certificate_artifact(CertificateId).

certificate_artifact(CertificateId) ->
    artifact_from_preview(certificate_preview(CertificateId), CertificateId).

device_artifact(DeviceId) ->
    artifact_from_preview(device_preview(DeviceId), DeviceId).

artifact_from_preview(Preview, SubjectId) ->
    case maps:get(authorization, Preview, deny) of
        allow ->
            {ok, artifact_filename(SubjectId), maps:get(preview, Preview, <<>>)};
        _ ->
            {error, maps:get(authorization_reason, Preview, <<"OVPN provisioning denied">>)}
    end.

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

device_preview(DeviceId) ->
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} ->
            Certificate = current_certificate(Device),
            Service = linked_service(Device),
            Policy = ias_security_profile:applied_policy(Device),
            Enforcement = ias_authorization_enforcement:device_enforcement(DeviceId),
            build_preview(Device, Certificate, Service, Policy, Enforcement);
        _ ->
            denied_preview(<<"device not found">>)
    end.

certificate_preview(CertificateId) ->
    case ias_demo_store:get(CertificateId) of
        {ok, #{kind := certificate} = Certificate} ->
            Device = linked_device(Certificate),
            Service = linked_service(Device),
            Policy = ias_certificate_detail:security_policy(Certificate),
            Enforcement = ovpn_provisioning_decision(Certificate),
            build_preview(Device, Certificate, Service, Policy, Enforcement);
        _ ->
            denied_preview(<<"certificate not found">>)
    end.

ovpn_provisioning_decision(CertificateId) when is_binary(CertificateId); is_atom(CertificateId) ->
    case ias_demo_store:get(CertificateId) of
        {ok, #{kind := certificate} = Certificate} ->
            ovpn_provisioning_decision(Certificate);
        _ ->
            denied_enforcement(<<"certificate not found">>)
    end;
ovpn_provisioning_decision(#{kind := certificate} = Certificate) ->
    Policy = ias_certificate_detail:security_policy(Certificate),
    Status = ias_trust_status:effective_certificate_status(maps:get(id, Certificate, undefined)),
    Reasons = ovpn_provisioning_reasons(Certificate, Policy, Status),
    case Reasons of
        [] -> allowed_enforcement(<<"OVPN Provisioning">>,
                                  ovpn_provisioning_allowed_reason(Certificate, Policy));
        _ -> denied_enforcement(Reasons)
    end;
ovpn_provisioning_decision(_Certificate) ->
    denied_enforcement(<<"certificate not found">>).

build_preview(Device, Certificate, Service, Policy, Enforcement) ->
    {RemoteHost, RemotePort} = remote_endpoint(Service),
    Protocol = protocol(Service),
    CertificateStatus = certificate_status(Certificate),
    CaCertificate = linked_ca_certificate(Service),
    Authorization = maps:get(result, Enforcement, deny),
    #{authorization => Authorization,
      authorization_reason => maps:get(reason, Enforcement, <<"authorization denied">>),
      device_id => object_id(Device),
      certificate_id => object_id(Certificate),
      vpn_service_id => object_id(Service),
      ca_certificate_id => object_id(CaCertificate),
      ca_certificate_status => ca_certificate_status(CaCertificate),
      device_lock => policy_device_lock(Policy),
      two_factor => policy_two_factor(Policy),
      remote_host => RemoteHost,
      remote_port => RemotePort,
      protocol => Protocol,
      certificate_status => CertificateStatus,
      preview => ovpn_skeleton(RemoteHost, RemotePort, Protocol)}.

denied_preview(Reason) ->
    build_preview(not_found, not_found, not_found, ias_security_profile:default_policy(),
                  denied_enforcement(Reason)).

allowed_enforcement(Operation, Reason) ->
    #{operation => Operation,
      action => ovpn_provision,
      result => allow,
      reason => ias_html:text(Reason),
      reasons => [ias_html:text(Reason)]}.

denied_enforcement(Reasons) when is_list(Reasons) ->
    TextReasons = [ias_html:text(Reason) || Reason <- Reasons],
    #{operation => <<"OVPN Provisioning">>,
      action => ovpn_provision,
      result => deny,
      reason => reason_text(TextReasons),
      reasons => TextReasons};
denied_enforcement(Reason) ->
    denied_enforcement([Reason]).

reason_text([]) ->
    <<"authorization denied">>;
reason_text([Reason]) ->
    ias_html:text(Reason);
reason_text(Reasons) ->
    ias_html:join(join_reasons(Reasons, [])).

join_reasons([], Acc) ->
    lists:reverse(Acc);
join_reasons([Reason | Rest], []) ->
    join_reasons(Rest, [ias_html:text(Reason)]);
join_reasons([Reason | Rest], Acc) ->
    join_reasons(Rest, [ias_html:text(Reason), <<"; ">> | Acc]).

ovpn_provisioning_reasons(Certificate, Policy, Status) ->
    case policy_required_reasons(Certificate, Policy) of
        [] ->
            case device_binding_required_reasons(Certificate, Policy) of
                [] ->
                    TrustReasons = [ias_html:text(maps:get(text, Reason, undefined))
                                    || Reason <- maps:get(reasons, Status, [])],
                    unique_reasons(provisioning_trust_reasons(Certificate, TrustReasons));
                DeviceReasons ->
                    unique_reasons(DeviceReasons)
            end;
        PolicyReasons ->
            unique_reasons(PolicyReasons)
    end.

provisioning_trust_reasons(Certificate, Reasons) ->
    [Reason || Reason <- Reasons,
               provisioning_reason_applies(Certificate, Reason)].

provisioning_reason_applies(_Certificate, <<"no device binding">>) ->
    false;
provisioning_reason_applies(Certificate, <<"no security policy">>) ->
    not certificate_has_security_policy(Certificate);
provisioning_reason_applies(_Certificate, _Reason) ->
    true.

ovpn_provisioning_allowed_reason(Certificate, Policy) ->
    case policy_device_lock(Policy) of
        enabled ->
            case has_device_binding(Certificate) of
                true ->
                    <<"device-bound profile allows OVPN provisioning">>;
                false ->
                    <<"device binding is required before OVPN provisioning">>
            end;
        _ ->
            <<"standard profile allows OVPN provisioning without device binding">>
    end.

policy_required_reasons(Certificate, _Policy) ->
    case certificate_has_security_policy(Certificate) of
        true -> [];
        false -> [<<"no security policy">>]
    end.

device_binding_required_reasons(Certificate, Policy) ->
    case policy_device_lock(Policy) of
        enabled ->
            case has_device_binding(Certificate) of
                true -> [];
                false -> [<<"no device binding">>]
            end;
        _ ->
            []
    end.

certificate_has_security_policy(Certificate) ->
    case source_profile_exists(Certificate) of
        true -> true;
        false -> linked_security_policy(Certificate) =/= not_found
    end.

source_profile_exists(Certificate) ->
    ProfileId = maps:get(profile_id, Certificate, maps:get(profile, Certificate, undefined)),
    case ias_security_profile:profile(ProfileId) of
        {ok, _Profile} -> true;
        not_found -> false
    end.

linked_security_policy(Certificate) ->
    CertificateId = maps:get(id, Certificate, undefined),
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_demo_store:relationships(),
             maps:get(relation_type, Relationship, undefined) =:= uses_security_policy,
             maps:get(source_kind, Relationship, undefined) =:= certificate,
             maps:get(source_id, Relationship, undefined) =:= CertificateId,
             maps:get(target_kind, Relationship, undefined) =:= security_policy] of
        [PolicyId | _] -> PolicyId;
        [] -> not_found
    end.

has_device_binding(Certificate) ->
    linked_device(Certificate) =/= not_found.

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

current_certificate(Device) ->
    maps:get(current_certificate, ias_certificate_role:device_status(Device), not_found).

linked_device(Certificate) ->
    CertificateId = maps:get(id, Certificate, undefined),
    case [Device || Relationship <- ias_demo_store:relationships(),
                    maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
                    maps:get(source_kind, Relationship, undefined) =:= device,
                    maps:get(target_kind, Relationship, undefined) =:= certificate,
                    maps:get(target_id, Relationship, undefined) =:= CertificateId,
                    {ok, Device} <- [ias_demo_store:get(maps:get(source_id, Relationship, undefined))],
                    maps:get(kind, Device, undefined) =:= device] of
        [Device | _] ->
            Device;
        [] ->
            same_import_device(Certificate)
    end.

same_import_device(Certificate) ->
    ImportId = maps:get(import_id, Certificate, undefined),
    case [Device || Device <- ias_demo_store:devices(),
                    maps:get(import_id, Device, undefined) =:= ImportId] of
        [Device | _] -> Device;
        [] -> not_found
    end.

linked_ca_certificate(not_found) ->
    not_found;
linked_ca_certificate(Service) ->
    ServiceId = maps:get(id, Service, undefined),
    case [Certificate || Relationship <- ias_demo_store:relationships(),
                         maps:get(relation_type, Relationship, undefined) =:= uses_ca_certificate,
                         maps:get(source_kind, Relationship, undefined) =:= vpn_service,
                         maps:get(source_id, Relationship, undefined) =:= ServiceId,
                         maps:get(target_kind, Relationship, undefined) =:= certificate,
                         {ok, Certificate} <- [ias_demo_store:get(maps:get(target_id, Relationship, undefined))],
                         maps:get(kind, Certificate, undefined) =:= certificate] of
        [Certificate | _] -> Certificate;
        [] -> same_import_ca_certificate(Service)
    end.

same_import_ca_certificate(Service) ->
    ImportId = maps:get(import_id, Service, undefined),
    case [Certificate || Certificate <- ias_demo_store:certificates(),
                         maps:get(import_id, Certificate, undefined) =:= ImportId,
                         certificate_ca_like(Certificate)] of
        [Certificate | _] -> Certificate;
        [] -> not_found
    end.

certificate_ca_like(Certificate) ->
    Source = maps:get(source, Certificate, undefined),
    Issuer = ias_html:text(maps:get(issuer, Certificate, maps:get(issuer_cn, Certificate, undefined))),
    Subject = ias_html:text(maps:get(subject, Certificate, maps:get(subject_cn, Certificate, undefined))),
    Source =:= ca_demo orelse
        Source =:= ca_certificate orelse
        contains(Issuer, <<"CN=CA">>) orelse
        contains(Subject, <<"CN=CA">>).

contains(Value, Pattern) when is_binary(Value) ->
    binary:match(Value, Pattern) =/= nomatch;
contains(_Value, _Pattern) ->
    false.

linked_service(not_found) ->
    not_found;
linked_service(Device) ->
    DeviceId = maps:get(id, Device, undefined),
    case [Service || Relationship <- ias_demo_store:relationships(),
                    maps:get(source_kind, Relationship, undefined) =:= device,
                    maps:get(source_id, Relationship, undefined) =:= DeviceId,
                    maps:get(target_kind, Relationship, undefined) =:= vpn_service,
                    service_relation(maps:get(relation_type, Relationship, undefined)),
                    {ok, Service} <- [ias_demo_store:get(maps:get(target_id, Relationship, undefined))],
                    maps:get(kind, Service, undefined) =:= vpn_service] of
        [Service | _] ->
            Service;
        [] ->
            same_import_service(Device)
    end.

same_import_service(Device) ->
    ImportId = maps:get(import_id, Device, undefined),
    case [Service || Service <- ias_demo_store:services(),
                     maps:get(import_id, Service, undefined) =:= ImportId] of
        [Service | _] -> Service;
        [] -> not_found
    end.

service_relation(uses_service) ->
    true;
service_relation(uses_vpn_service) ->
    true;
service_relation(_RelationType) ->
    false.

remote_endpoint(not_found) ->
    {<<"not found">>, <<"not found">>};
remote_endpoint(Service) ->
    Remote = maps:get(remote, Service, maps:get(endpoint, Service, <<"not found">>)),
    split_remote(ias_html:text(Remote)).

split_remote(<<"not found">>) ->
    {<<"not found">>, <<"not found">>};
split_remote(Remote) ->
    case binary:split(Remote, <<":">>, [global]) of
        [Host, Port] ->
            {Host, Port};
        [Host] ->
            {Host, <<"not found">>};
        Parts ->
            [Port | RevHostParts] = lists:reverse(Parts),
            {ias_html:join(lists:join(<<":">>, lists:reverse(RevHostParts))), Port}
    end.

protocol(not_found) ->
    <<"udp">>;
protocol(Service) ->
    case maps:get(protocol, Service, udp) of
        not_found -> <<"udp">>;
        Protocol -> ias_html:text(Protocol)
    end.

ca_certificate_status(not_found) ->
    missing;
ca_certificate_status(Certificate) ->
    certificate_status(Certificate).

certificate_status(not_found) ->
    unknown;
certificate_status(Certificate) ->
    maps:get(trust,
             ias_trust_status:effective_certificate_status(maps:get(id, Certificate, undefined)),
             unknown).

policy_device_lock(Policy) ->
    case maps:get(device_lock, Policy, disabled) of
        enabled -> enabled;
        disabled -> disabled;
        Value -> Value
    end.

policy_two_factor(Policy) ->
    case maps:get(two_factor, Policy, optional) of
        required -> required;
        optional -> optional;
        disabled -> disabled;
        Value -> Value
    end.

object_id(not_found) ->
    not_found;
object_id(Object) ->
    maps:get(id, Object, not_found).

ovpn_skeleton(RemoteHost, RemotePort, Protocol) ->
    ias_html:join([
        <<"client\n">>,
        <<"dev tun\n">>,
        <<"proto ">>, Protocol, <<"\n\n">>,
        <<"remote ">>, RemoteHost, <<" ">>, RemotePort, <<"\n\n">>,
        <<"remote-cert-tls server\n\n">>,
        <<"<ca>\n">>,
        <<"...\n">>,
        <<"</ca>\n\n">>,
        <<"<cert>\n">>,
        <<"...\n">>,
        <<"</cert>\n\n">>,
        <<"<key>\n">>,
        <<"# device-owned private key\n">>,
        <<"# not exported by IAS\n">>,
        <<"</key>\n">>
    ]).
