-module(ias_device_bound_ovpn).
-export([assemble/1, download_response/1, safe_filename/1]).

assemble(ProvisioningId) ->
    case ias_ovpn_provisioning:get(ProvisioningId) of
        {ok, Transaction} ->
            assemble_transaction(Transaction);
        not_found ->
            {error, <<"provisioning transaction not found">>}
    end.

download_response(ProvisioningId) ->
    case assemble(ProvisioningId) of
        {ok, Artifact} ->
            Filename = maps:get(filename, Artifact),
            {ok, Artifact#{content_type => <<"application/x-openvpn-profile">>,
                           content_disposition => content_disposition(Filename),
                           body => maps:get(body, Artifact)}};
        {error, Reason} ->
            {error, Reason}
    end.

assemble_transaction(#{mode := device_bound} = Transaction) ->
    case preflight(Transaction) of
        ok ->
            build_artifact(Transaction);
        {error, Reason} ->
            {error, Reason}
    end;
assemble_transaction(_Transaction) ->
    {error, <<"only device-bound provisioning can be assembled">>}.

preflight(Transaction) ->
    Checks = [fun() -> authorization_check(Transaction) end,
              fun() -> relationship_check(Transaction) end,
              fun() -> assembly_check(Transaction) end],
    first_error(Checks).

first_error([]) ->
    ok;
first_error([Check | Rest]) ->
    case Check() of
        ok -> first_error(Rest);
        {error, Reason} -> {error, Reason}
    end.

authorization_check(Transaction) ->
    case maps:get(authorization, Transaction, deny) of
        allow -> ok;
        _ -> {error, maps:get(authorization_reason, Transaction,
                              <<"authorization denied">>)}
    end.

relationship_check(Transaction) ->
    DeviceId = maps:get(device_id, Transaction, not_found),
    case ias_ovpn_provisioning:preview(device_bound, device, DeviceId) of
        #{authorization := allow} = Preview ->
            Required = [{certificate_id, certificate_id},
                        {vpn_service_id, vpn_service_id},
                        {ca_certificate_id, ca_certificate_id}],
            case references_match(Required, Transaction, Preview) of
                true -> ok;
                false -> {error, <<"stale or missing provisioning relationship">>}
            end;
        Preview ->
            {error, maps:get(authorization_reason, Preview,
                             <<"authorization denied">>)}
    end.

references_match([], _Transaction, _Preview) ->
    true;
references_match([{TransactionKey, PreviewKey} | Rest], Transaction, Preview) ->
    same_id(maps:get(TransactionKey, Transaction, not_found),
            maps:get(PreviewKey, Preview, not_found)) andalso
        references_match(Rest, Transaction, Preview).

assembly_check(Transaction) ->
    Refreshed = ias_ovpn_provisioning:refresh(Transaction),
    case maps:get(assembly_status, Refreshed, blocked) of
        public_bundle_ready -> ok;
        ready_for_device_assembly -> ok;
        _ ->
            {error, maps:get(assembly_reason, Refreshed,
                             <<"device-bound OVPN assembly is blocked">>)}
    end.

build_artifact(Transaction) ->
    with_object(device, maps:get(device_id, Transaction, not_found),
      fun(Device) ->
        with_object(vpn_service, maps:get(vpn_service_id, Transaction, not_found),
          fun(Service) ->
            with_material(maps:get(ca_certificate_id, Transaction, not_found),
                          ca_certificate,
              fun(CaPem) ->
                with_material(maps:get(certificate_id, Transaction, not_found),
                              client_certificate,
                  fun(ClientPem) ->
                    with_key_reference(Device,
                      fun(KeyRef) ->
                        CertificateId = maps:get(certificate_id, Transaction, not_found),
                        case assembly_validation(Transaction, Device, Service, CertificateId,
                                                 KeyRef, CaPem, ClientPem) of
                            {ok, Validation} ->
                                {ok, Host, Port, Protocol} = endpoint(Service),
                                Body = ovpn_body(Device, Host, Port, Protocol,
                                                 CaPem, ClientPem, KeyRef),
                                Filename = safe_filename(maps:get(id, Device, <<"device">>)),
                                {ok, #{filename => Filename,
                                       body => Body,
                                       sha256 => sha256(Body),
                                       private_key_provider => <<"device_file">>,
                                       private_key_ref => KeyRef,
                                       certificate_validation_mode =>
                                           maps:get(mode, Validation, strict),
                                       certificate_validation_bypass =>
                                           maps:get(development_bypass, Validation, false)}};
                            {error, Reason} ->
                                {error, Reason}
                        end
                      end)
                  end)
              end)
          end)
      end).

with_object(Kind, Id, Fun) ->
    case ias_demo_store:get(Id) of
        {ok, #{kind := Kind} = Object} -> Fun(Object);
        _ -> {error, missing_object_reason(Kind)}
    end.

missing_object_reason(device) -> <<"device object is missing">>;
missing_object_reason(vpn_service) -> <<"VPN service object is missing">>;
missing_object_reason(_) -> <<"required object is missing">>.

with_material(CertificateId, ExpectedType, Fun) ->
    case ias_certificate_material:get(CertificateId) of
        {ok, #{material_type := ExpectedType, body := Pem}} ->
            Fun(Pem);
        {ok, _OtherMaterial} ->
            {error, <<"conflicting certificate roles">>};
        not_found ->
            {error, missing_material_reason(ExpectedType)}
    end.

missing_material_reason(ca_certificate) ->
    <<"CA certificate PEM is unavailable">>;
missing_material_reason(client_certificate) ->
    <<"client certificate PEM is unavailable">>;
missing_material_reason(_Type) ->
    <<"certificate PEM is unavailable">>.

with_key_reference(Device, Fun) ->
    case ias_device_key_ref:status(Device) of
        {ok, #{private_key_provider := <<"device_file">>,
               private_key_ref := Ref}} ->
            Fun(Ref);
        {ok, _Safe} ->
            {error, <<"Device-owned private key provider is unsupported.">>};
        {error, missing_private_key_ref} ->
            {error, <<"Device-owned private key reference is missing.">>};
        {error, <<"Private Key Provider must be device_file">>} ->
            {error, <<"Device-owned private key provider is unsupported.">>};
        {error, <<"Private Key Provider is required">>} ->
            {error, <<"Device-owned private key provider is unsupported.">>};
        {error, _Reason} ->
            {error, <<"Device-owned private key reference is invalid.">>}
    end.

assembly_validation(Transaction, Device, Service, CertificateId, KeyRef, CaPem, ClientPem) ->
    case ias_x509_validation:validate_pair(CaPem, ClientPem) of
        {ok, Validation} ->
            case ias_x509_validation:validate_ovpn_inputs(Device, Service, KeyRef) of
                ok ->
                    case certificate_lineage_check(Transaction, CertificateId, Device, KeyRef) of
                        ok -> {ok, Validation};
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

certificate_lineage_check(_Transaction, CertificateId, Device, KeyRef) ->
    case ias_demo_store:get(CertificateId) of
        {ok, #{kind := certificate} = Certificate} ->
            DeviceId = maps:get(id, Device, undefined),
            Checks = [
                {same_id(maps:get(device_id, Certificate, undefined), DeviceId),
                 <<"selected certificate was not issued for the selected Device">>},
                {present(maps:get(csr_fingerprint, Certificate, undefined)),
                 <<"selected certificate has no CSR lineage">>},
                {present(maps:get(csr_public_key_fingerprint, Certificate, undefined)),
                 <<"selected certificate has no CSR public-key lineage">>},
                {same_id(maps:get(certificate_public_key_fingerprint, Certificate, undefined),
                         maps:get(csr_public_key_fingerprint, Certificate, undefined)),
                 <<"selected certificate public key does not match enrollment CSR">>},
                {same_id(maps:get(private_key_reference, Certificate, undefined), KeyRef),
                 <<"Device private key reference does not match certificate enrollment lineage">>}
            ],
            first_failed_lineage_check(Checks);
        _ ->
            {error, <<"selected client certificate is missing">>}
    end.

first_failed_lineage_check([]) ->
    ok;
first_failed_lineage_check([{true, _Reason} | Rest]) ->
    first_failed_lineage_check(Rest);
first_failed_lineage_check([{false, Reason} | _Rest]) ->
    {error, Reason}.

endpoint(Service) ->
    Host = first_present([maps:get(remote_host, Service, undefined),
                          endpoint_host(Service)]),
    Port = first_present([maps:get(remote_port, Service, undefined),
                          endpoint_port(Service)]),
    Protocol = ias_html:text(maps:get(protocol, Service, <<"udp">>)),
    case {present(Host), present(Port)} of
        {true, true} -> {ok, ias_html:text(Host), ias_html:text(Port), Protocol};
        _ -> {error, <<"missing VPN endpoint">>}
    end.

endpoint_host(Service) ->
    {Host, _Port} = split_endpoint(maps:get(remote, Service,
                                            maps:get(endpoint, Service, <<"">>))),
    Host.

endpoint_port(Service) ->
    {_Host, Port} = split_endpoint(maps:get(remote, Service,
                                            maps:get(endpoint, Service, <<"">>))),
    Port.

split_endpoint(Value0) ->
    Value = ias_html:text(Value0),
    case binary:split(Value, <<":">>, [global]) of
        [Host, Port] -> {Host, Port};
        [Host] -> {Host, undefined};
        Parts ->
            [Port | RevHostParts] = lists:reverse(Parts),
            {ias_html:join(lists:join(<<":">>, lists:reverse(RevHostParts))), Port}
    end.

first_present([]) ->
    undefined;
first_present([Value | Rest]) ->
    case present(Value) of
        true -> Value;
        false -> first_present(Rest)
    end.

present(undefined) -> false;
present(not_found) -> false;
present(<<>>) -> false;
present(Value) -> ias_html:text(Value) =/= <<"not found">>.

ovpn_body(Device, Host, Port, Protocol, CaPem, ClientPem, KeyRef) ->
    Tunnel = ias_html:text(maps:get(tunnel_device, Device, <<"tun">>)),
    ias_html:join([
        <<"client\n">>,
        <<"dev ">>, Tunnel, <<"\n">>,
        <<"proto ">>, Protocol, <<"\n">>,
        <<"remote ">>, Host, <<" ">>, Port, <<"\n">>,
        <<"nobind\n">>,
        <<"persist-key\n">>,
        <<"persist-tun\n">>,
        <<"remote-cert-tls server\n\n">>,
        <<"<ca>\n">>, ensure_newline(CaPem), <<"</ca>\n\n">>,
        <<"<cert>\n">>, ensure_newline(ClientPem), <<"</cert>\n\n">>,
        <<"# Private key remains on the approved device.\n">>,
        <<"key ">>, KeyRef, <<"\n">>
    ]).

ensure_newline(Pem) ->
    Text = ias_html:text(Pem),
    case Text of
        <<>> -> <<>>;
        _ ->
            case binary:last(Text) of
                $\n -> Text;
                _ -> <<Text/binary, "\n">>
            end
    end.

safe_filename(SubjectId) ->
    ias_ovpn_provisioning:artifact_filename(SubjectId).

content_disposition(Filename) ->
    ias_html:join([<<"attachment; filename=\"">>, Filename, <<"\"">>]).

sha256(Body) ->
    Hash = crypto:hash(sha256, Body),
    ias_html:text(string:uppercase(binary_to_list(binary:encode_hex(Hash)))).

same_id(Left, Right) ->
    ias_html:text(Left) =:= ias_html:text(Right).
