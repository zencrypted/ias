%%%-------------------------------------------------------------------
%% @doc Builds and validates the secret-free metadata capsule retained by VPN
%% so an IAS orphan can later be previewed and recovered without guessing.
%%%-------------------------------------------------------------------
-module(ias_vpn_recovery_manifest).

-export([build/1,
         build/2,
         validate/1,
         preview/1]).

-define(SCHEMA_VERSION, 1).

build(DeviceId) ->
    build(DeviceId, #{}).

build(DeviceId0, Context) when is_map(Context) ->
    DeviceId = normalize_id(DeviceId0),
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} ->
            Relationships = recovery_relationships(DeviceId),
            Objects = recovery_objects(Device, Relationships),
            case required_objects(DeviceId, Objects, Relationships) of
                {ok, Certificate, Service} ->
                    Manifest0 = #{schema_version => ?SCHEMA_VERSION,
                                  device => descriptor(Device),
                                  certificate => descriptor(Certificate),
                                  vpn_service => descriptor(Service),
                                  objects => [descriptor(Object) || Object <- Objects],
                                  relationships => [relationship_descriptor(Relationship)
                                                    || Relationship <- Relationships]},
                    Manifest = maybe_context(Context, Manifest0),
                    case validate(Manifest) of
                        ok -> {ok, Manifest};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        _ ->
            {error, recovery_device_not_found}
    end;
build(_DeviceId, _Context) ->
    {error, invalid_recovery_manifest_context}.

validate(#{schema_version := ?SCHEMA_VERSION,
           device := #{kind := device, id := DeviceId},
           certificate := #{kind := certificate, id := CertificateId},
           vpn_service := #{kind := vpn_service, id := ServiceId},
           objects := Objects,
           relationships := Relationships} = Manifest)
  when is_list(Objects), is_list(Relationships) ->
    Device = maps:get(device, Manifest),
    Certificate = maps:get(certificate, Manifest),
    Service = maps:get(vpn_service, Manifest),
    Valid = usable_id(DeviceId) andalso usable_id(CertificateId)
        andalso usable_id(ServiceId)
        andalso valid_descriptor(Device)
        andalso valid_descriptor(Certificate)
        andalso valid_certificate_descriptor(Certificate)
        andalso valid_descriptor(Service)
        andalso lists:all(fun valid_descriptor/1, Objects)
        andalso unique_object_identities(Objects)
        andalso lists:member(Device, Objects)
        andalso lists:member(Certificate, Objects)
        andalso lists:member(Service, Objects)
        andalso lists:all(fun valid_relationship/1, Relationships)
        andalso relationship_endpoints_present(Relationships, Objects)
        andalso required_relationship(DeviceId, CertificateId,
                                       certificate, Relationships)
        andalso required_relationship(DeviceId, ServiceId,
                                       vpn_service, Relationships)
        andalso no_forbidden_material(Manifest),
    case Valid of
        true -> ok;
        false -> {error, invalid_recovery_manifest}
    end;
validate(#{schema_version := Version}) ->
    {error, {unsupported_recovery_manifest_schema_version, Version}};
validate(_) ->
    {error, invalid_recovery_manifest}.

preview(Manifest) ->
    case validate(Manifest) of
        ok ->
            Objects = maps:get(objects, Manifest, []),
            Relationships = maps:get(relationships, Manifest, []),
            Certificate = maps:get(certificate, Manifest),
            Base = #{schema_version => ?SCHEMA_VERSION,
                     provisioning_transaction_id =>
                         maps:get(provisioning_transaction_id,
                                  Manifest,
                                  undefined),
                     wizard_id => maps:get(wizard_id, Manifest, undefined),
                     device_id => maps:get(id, maps:get(device, Manifest)),
                     object_count => length(Objects),
                     relationship_count => length(Relationships),
                     objects => Objects,
                     relationships => Relationships},
            case certificate_material_status(Certificate) of
                {ok, Mode} -> Base#{recoverable => true, mode => Mode};
                {error, Reason} -> Base#{recoverable => false,
                                         reason => Reason}
            end;
        {error, Reason} ->
            #{recoverable => false, reason => Reason}
    end.

required_objects(DeviceId, Objects, Relationships) ->
    CertificateIds = target_ids(Relationships, device, DeviceId,
                                uses_certificate, certificate),
    ServiceIds = target_ids(Relationships, device, DeviceId,
                            service_relation, vpn_service),
    case {first_object(certificate, CertificateIds, Objects),
          first_object(vpn_service, ServiceIds, Objects)} of
        {{ok, Certificate}, {ok, Service}} -> {ok, Certificate, Service};
        {not_found, _} -> {error, recovery_certificate_not_found};
        {_, not_found} -> {error, recovery_vpn_service_not_found}
    end.

target_ids(Relationships, SourceKind, SourceId, RelationSelector, TargetKind) ->
    [maps:get(target_id, Relationship)
     || Relationship <- Relationships,
        maps:get(source_kind, Relationship, undefined) =:= SourceKind,
        same_id(maps:get(source_id, Relationship, undefined), SourceId),
        relation_matches(RelationSelector,
                         maps:get(relation_type, Relationship, undefined)),
        maps:get(target_kind, Relationship, undefined) =:= TargetKind].

relation_matches(service_relation, uses_service) -> true;
relation_matches(service_relation, uses_vpn_service) -> true;
relation_matches(Expected, Actual) -> Expected =:= Actual.

first_object(Kind, Ids, Objects) ->
    case [Object || Object <- Objects,
                    maps:get(kind, Object, undefined) =:= Kind,
                    lists:any(fun(Id) -> same_id(maps:get(id, Object, undefined), Id) end,
                              Ids)] of
        [Object | _] -> {ok, Object};
        [] -> not_found
    end.

recovery_relationships(DeviceId) ->
    All = ias_demo_store:relationships(),
    First = [Relationship || Relationship <- All,
                            touches_id(Relationship, DeviceId)],
    FirstIds = relationship_ids(First),
    Second = [Relationship || Relationship <- All,
                             lists:any(fun(Id) -> touches_id(Relationship, Id) end,
                                       FirstIds)],
    [Relationship || Relationship <- lists:usort(First ++ Second),
                     recoverable_kind(maps:get(source_kind,
                                               Relationship,
                                               undefined)),
                     recoverable_kind(maps:get(target_kind,
                                               Relationship,
                                               undefined))].

recovery_objects(Device, Relationships) ->
    Ids = lists:usort([maps:get(id, Device) | relationship_ids(Relationships)]),
    Objects = [Object || Id <- Ids,
                         {ok, Object} <- [ias_demo_store:get(Id)],
                         recoverable_kind(maps:get(kind, Object, undefined))],
    unique_objects([Device | Objects]).

unique_objects(Objects) ->
    Indexed = lists:foldl(fun(Object, Acc) ->
                                  Key = {maps:get(kind, Object, undefined),
                                         normalize_id(maps:get(id, Object, undefined))},
                                  Acc#{Key => Object}
                          end,
                          #{},
                          Objects),
    [maps:get(Key, Indexed) || Key <- lists:sort(maps:keys(Indexed))].

relationship_ids(Relationships) ->
    lists:usort(
      [Id || Relationship <- Relationships,
             Id <- [maps:get(source_id, Relationship, undefined),
                    maps:get(target_id, Relationship, undefined)],
             usable_id(Id)]).

touches_id(Relationship, Id) ->
    same_id(maps:get(source_id, Relationship, undefined), Id) orelse
    same_id(maps:get(target_id, Relationship, undefined), Id).

recoverable_kind(device) -> true;
recoverable_kind(certificate) -> true;
recoverable_kind(vpn_service) -> true;
recoverable_kind(security_profile) -> true;
recoverable_kind(security_policy) -> true;
recoverable_kind(user) -> true;
recoverable_kind(_) -> false.

descriptor(#{kind := Kind} = Object) ->
    maps:with(common_fields() ++ kind_fields(Kind), Object).

common_fields() ->
    [id, kind, source, name, description, created_at, updated_at].

kind_fields(device) ->
    [owner, user_id, type, endpoint, remote_host, common_name, device_name,
     hostname, service_name, transport, tunnel_device, profile_id,
     security_profile_id, security_policy_id, certificate_status,
     device_status, status, serial, manufacturer, model, peer_id,
     public_key_fingerprint, vpn_allocation_id, vpn_allocator_instance_id,
     vpn_client_peer_id, vpn_gateway_peer_id,
     vpn_allocation_slot, vpn_allocation_generation];
kind_fields(certificate) ->
    [user, user_id, user_name, profile_id, subject, subject_cn, issuer,
     issuer_cn, serial, not_before, not_after, fingerprint_sha256,
     requested_cn, enrollment_cn, public_key_fingerprint, csr_fingerprint,
     csr_public_key_fingerprint, certificate_public_key_fingerprint, role,
     trust_level, device_lock, two_factor, trusted, key_match, material_type,
     certificate_role, certificate_status, status, security_policy_id,
     owner, device_id, enrollment_id, issued_via];
kind_fields(vpn_service) ->
    [service, remote, remote_host, remote_port, protocol, cipher, compression,
     routes, endpoint, port, transport, ca_certificate_id,
     security_profile_id, security_policy_id, service_name, owners];
kind_fields(security_profile) ->
    [profile_id, role, certificate_role, services, attributes, trust_level,
     device_lock, two_factor, policies, enforcement_mode, status];
kind_fields(security_policy) ->
    [policy_id, profile_id, decision, rules, requirements, services,
     attributes, trust_level, device_lock, two_factor, enforcement_mode,
     status];
kind_fields(user) ->
    [username, display_name, email, role, profile_id, status, attributes];
kind_fields(_) -> [].

relationship_descriptor(Relationship) ->
    maps:with([id, kind, relation_type, source_kind, source_id,
               target_kind, target_id, score, warnings], Relationship).

maybe_context(Context, Manifest0) ->
    Manifest1 = maybe_put(provisioning_transaction_id,
                          maps:get(provisioning_transaction_id,
                                   Context,
                                   undefined),
                          Manifest0),
    maybe_put(wizard_id, maps:get(wizard_id, Context, undefined), Manifest1).

valid_descriptor(#{id := Id, kind := Kind} = Descriptor) ->
    usable_id(Id) andalso recoverable_kind(Kind)
        andalso no_forbidden_material(Descriptor);
valid_descriptor(_) -> false.

valid_certificate_descriptor(Certificate) ->
    usable_id(maps:get(fingerprint_sha256, Certificate, undefined)).

valid_relationship(#{relation_type := RelationType,
                     source_kind := SourceKind,
                     source_id := SourceId,
                     target_kind := TargetKind,
                     target_id := TargetId} = Relationship) ->
    RelationType =/= undefined andalso recoverable_kind(SourceKind)
        andalso recoverable_kind(TargetKind) andalso usable_id(SourceId)
        andalso usable_id(TargetId) andalso no_forbidden_material(Relationship);
valid_relationship(_) -> false.

unique_object_identities(Objects) ->
    Identities = [{maps:get(kind, Object), normalize_id(maps:get(id, Object))}
                  || Object <- Objects],
    length(Identities) =:= length(lists:usort(Identities)).

relationship_endpoints_present(Relationships, Objects) ->
    lists:all(
      fun(Relationship) ->
          object_identity_present(maps:get(source_kind, Relationship),
                                  maps:get(source_id, Relationship),
                                  Objects)
              andalso
          object_identity_present(maps:get(target_kind, Relationship),
                                  maps:get(target_id, Relationship),
                                  Objects)
      end,
      Relationships).

object_identity_present(Kind, Id, Objects) ->
    lists:any(fun(Object) ->
                      maps:get(kind, Object) =:= Kind andalso
                      same_id(maps:get(id, Object), Id)
              end,
              Objects).

required_relationship(DeviceId, TargetId, TargetKind, Relationships) ->
    lists:any(
      fun(Relationship) ->
          maps:get(source_kind, Relationship) =:= device andalso
          same_id(maps:get(source_id, Relationship), DeviceId) andalso
          maps:get(target_kind, Relationship) =:= TargetKind andalso
          same_id(maps:get(target_id, Relationship), TargetId) andalso
          required_relation_type(TargetKind,
                                 maps:get(relation_type, Relationship))
      end,
      Relationships).

required_relation_type(certificate, uses_certificate) -> true;
required_relation_type(vpn_service, uses_service) -> true;
required_relation_type(vpn_service, uses_vpn_service) -> true;
required_relation_type(_, _) -> false.

no_forbidden_material(Term) ->
    forbidden_path(Term) =:= none.

forbidden_path(Map) when is_map(Map) ->
    forbidden_pairs(maps:to_list(Map));
forbidden_path(List) when is_list(List) ->
    forbidden_values(List);
forbidden_path(Tuple) when is_tuple(Tuple) ->
    forbidden_values(tuple_to_list(Tuple));
forbidden_path(Binary) when is_binary(Binary) ->
    case binary:match(Binary, <<"-----BEGIN ">>) of
        nomatch -> none;
        _ -> pem_material
    end;
forbidden_path(Value) when is_pid(Value); is_port(Value); is_reference(Value);
                           is_function(Value) ->
    unsafe_term;
forbidden_path(_) -> none.

forbidden_pairs([]) -> none;
forbidden_pairs([{Key, Value} | Rest]) ->
    case forbidden_key(Key) of
        true -> Key;
        false ->
            case forbidden_path(Value) of
                none -> forbidden_pairs(Rest);
                Found -> Found
            end
    end.

forbidden_values([]) -> none;
forbidden_values([Value | Rest]) ->
    case forbidden_path(Value) of
        none -> forbidden_values(Rest);
        Found -> Found
    end.

forbidden_key(Key) ->
    Text = string:lowercase(binary_to_list(ias_html:text(Key))),
    lists:any(fun(Fragment) -> string:find(Text, Fragment) =/= nomatch end,
              ["private_key", "privatekey", "key_pem", "pem_body",
               "certificate_body", "certificate_pem", "certificate_der",
               "cert_pem", "ca_body", "ca_pem", "csr_body", "csr_pem",
               "cmp_body", "raw_cmp", "ovpn", "password", "passphrase",
               "shared_secret", "session_key", "psk", "tls_auth"]).

certificate_material_status(Certificate) ->
    CertificateId = maps:get(id, Certificate),
    ExpectedFingerprint = ias_html:text(
                            maps:get(fingerprint_sha256, Certificate)),
    case ias_certificate_material:status(CertificateId) of
        {ok, Status} ->
            ActualFingerprint = ias_html:text(
                                  maps:get(fingerprint_sha256,
                                           Status,
                                           undefined)),
            case ActualFingerprint =:= ExpectedFingerprint of
                true -> {ok, full};
                false -> {error, certificate_material_fingerprint_mismatch}
            end;
        not_found -> {ok, metadata_only};
        {error, _} -> {ok, metadata_only}
    end.

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(_Key, <<>>, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => normalize_id(Value)}.

same_id(A, B) -> normalize_id(A) =:= normalize_id(B).

usable_id(Value) when is_binary(Value) -> byte_size(Value) > 0;
usable_id(Value) when is_atom(Value) -> Value =/= undefined;
usable_id(_) -> false.

normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_atom(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) -> ias_html:text(Id).
