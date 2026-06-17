-module(ias_ovpn_export).
-export([certificate_preview/1,
         device_preview/1]).

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
            case linked_device(Certificate) of
                not_found ->
                    Policy = ias_certificate_detail:security_policy(Certificate),
                    build_preview(not_found, Certificate, not_found, Policy,
                                  denied_enforcement(<<"no device binding">>));
                Device ->
                    Service = linked_service(Device),
                    Policy = ias_certificate_detail:security_policy(Certificate),
                    Enforcement = ias_authorization_enforcement:device_enforcement(
                                    maps:get(id, Device, undefined)),
                    build_preview(Device, Certificate, Service, Policy, Enforcement)
            end;
        _ ->
            denied_preview(<<"certificate not found">>)
    end.

build_preview(Device, Certificate, Service, Policy, Enforcement) ->
    {RemoteHost, RemotePort} = remote_endpoint(Service),
    Protocol = protocol(Service),
    CertificateStatus = certificate_status(Certificate),
    Authorization = maps:get(result, Enforcement, deny),
    #{authorization => Authorization,
      authorization_reason => maps:get(reason, Enforcement, <<"authorization denied">>),
      device_id => object_id(Device),
      certificate_id => object_id(Certificate),
      vpn_service_id => object_id(Service),
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

denied_enforcement(Reason) ->
    #{result => deny,
      reason => ias_html:text(Reason)}.

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
