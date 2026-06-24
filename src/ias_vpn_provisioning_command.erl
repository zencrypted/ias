-module(ias_vpn_provisioning_command).
-export([build/1,
         build/2,
         summary/1]).

build(DeviceId) ->
    case device(DeviceId) of
        {ok, Device} ->
            Operation = inferred_operation(Device),
            build_for_device(Device, Operation);
        not_found ->
            {error, not_found}
    end.

build(DeviceId, Operation) ->
    case valid_operation(Operation) of
        false -> {error, invalid_operation};
        true ->
            case device(DeviceId) of
                {ok, Device} -> build_for_device(Device, Operation);
                not_found -> {error, not_found}
            end
    end.

summary(Command) when is_map(Command) ->
    Desired = maps:get(desired_state, Command, #{}),
    #{peer_id => maps:get(peer_id, Command, undefined),
      revision => maps:get(revision, Command, undefined),
      operation => maps:get(operation, Command, undefined),
      source => maps:get(source, Command, undefined),
      device_id => maps:get(device_id, Desired, undefined),
      enabled => maps:get(enabled, Desired, undefined),
      authorized => maps:get(authorized, Desired, undefined),
      authorization_mode => maps:get(authorization_mode, Desired, undefined),
      authorization_reason => maps:get(authorization_reason, Desired, undefined),
      profile_id => maps:get(profile_id, Desired, undefined),
      certificate_fingerprint => maps:get(certificate_fingerprint, Desired, undefined)};
summary(_) ->
    #{}.

build_for_device(Device, Operation) ->
    DeviceId = maps:get(id, Device),
    Decision = ias_authorization_decision:device_decision(DeviceId, access_vpn),
    Certificate = linked_certificate(DeviceId),
    Command0 = #{peer_id => peer_id(Device),
                 operation => Operation,
                 source => ias,
                 desired_state => desired_state(Device, Certificate, Decision, Operation)},
    case ias_vpn_provisioning_state:prepare(DeviceId, Command0) of
        {ok, Command, _Change} -> {ok, Command};
        Error -> Error
    end.

inferred_operation(Device) ->
    DeviceId = maps:get(id, Device),
    case linked_certificate(DeviceId) of
        {ok, Certificate} ->
            case ias_certificate_revocation:revoked(Certificate) of
                true -> revoke;
                false -> decision_operation(DeviceId)
            end;
        not_found ->
            decision_operation(DeviceId)
    end.

decision_operation(DeviceId) ->
    case maps:get(decision,
                  ias_authorization_decision:device_decision(DeviceId, access_vpn),
                  deny) of
        allow -> upsert;
        _ -> disable
    end.

desired_state(Device, CertificateResult, Decision, Operation) ->
    Authorized0 = maps:get(decision, Decision, deny) =:= allow,
    Authorized = case Operation of
                     revoke -> false;
                     remove -> false;
                     _ -> Authorized0
                 end,
    Enabled = Authorized andalso (Operation =:= upsert orelse Operation =:= enable),
    Desired0 = #{device_id => maps:get(id, Device),
                 enabled => Enabled,
                 authorized => Authorized,
                 authorization_mode => policy,
                 authorization_reason => authorization_reason(Decision, Operation),
                 certificate_fingerprint => certificate_fingerprint(CertificateResult)},
    maybe_put(profile_id, linked_profile_id(Device, CertificateResult), Desired0).


linked_profile_id(Device, CertificateResult) ->
    DeviceId = maps:get(id, Device),
    first_present([linked_device_profile_id(DeviceId),
                   maps:get(profile_id, Device, maps:get(profile, Device, undefined)),
                   certificate_profile_id(CertificateResult)]).

linked_device_profile_id(DeviceId) ->
    case [maps:get(target_id, Relationship, undefined)
          || Relationship <- ias_demo_store:relationships(),
             maps:get(relation_type, Relationship, undefined) =:= uses_security_profile,
             maps:get(source_kind, Relationship, undefined) =:= device,
             same_id(maps:get(source_id, Relationship, undefined), DeviceId),
             maps:get(target_kind, Relationship, undefined) =:= security_profile] of
        [ProfileId | _] -> ProfileId;
        [] -> undefined
    end.

certificate_profile_id({ok, Certificate}) ->
    maps:get(profile_id, Certificate, maps:get(profile, Certificate, undefined));
certificate_profile_id(not_found) ->
    undefined.

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(_Key, <<>>, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

authorization_reason(_Decision, revoke) -> certificate_revoked;
authorization_reason(_Decision, remove) -> device_decommissioned;
authorization_reason(Decision, _Operation) ->
    case {maps:get(decision, Decision, deny), maps:get(reasons, Decision, [])} of
        {allow, []} -> profile_allows_vpn;
        {allow, [Reason | _]} -> normalize_reason(Reason);
        {deny, []} -> authorization_denied;
        {deny, [Reason | _]} -> normalize_reason(Reason)
    end.

normalize_reason(Reason) when is_atom(Reason) -> Reason;
normalize_reason(Reason) ->
    Text = ias_html:text(Reason),
    Lowercase = unicode:characters_to_binary(
                  string:lowercase(unicode:characters_to_list(Text))),
    binary:replace(Lowercase, <<" ">>, <<"_">>, [global]).

certificate_fingerprint({ok, Certificate}) ->
    first_present([maps:get(fingerprint_sha256, Certificate, undefined),
                   maps:get(certificate_fingerprint, Certificate, undefined),
                   maps:get(public_key_fingerprint, Certificate, undefined),
                   maps:get(certificate_public_key_fingerprint, Certificate, undefined)]);
certificate_fingerprint(not_found) ->
    undefined.

linked_certificate(DeviceId) ->
    case [Certificate || Relationship <- ias_demo_store:relationships(),
                         maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
                         maps:get(source_kind, Relationship, undefined) =:= device,
                         same_id(maps:get(source_id, Relationship, undefined), DeviceId),
                         maps:get(target_kind, Relationship, undefined) =:= certificate,
                         {ok, Certificate} <- [ias_demo_store:get(maps:get(target_id, Relationship, undefined))],
                         maps:get(kind, Certificate, undefined) =:= certificate] of
        [Certificate | _] -> {ok, Certificate};
        [] -> not_found
    end.

peer_id(Device) ->
    first_present([maps:get(peer_id, Device, undefined),
                   maps:get(runtime_peer_id, Device, undefined),
                   maps:get(id, Device)]).

device(DeviceId) ->
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} -> {ok, Device};
        _ -> not_found
    end.

valid_operation(upsert) -> true;
valid_operation(enable) -> true;
valid_operation(disable) -> true;
valid_operation(revoke) -> true;
valid_operation(remove) -> true;
valid_operation(_) -> false.

first_present([undefined | Rest]) -> first_present(Rest);
first_present([<<>> | Rest]) -> first_present(Rest);
first_present([Value | _]) -> Value;
first_present([]) -> undefined.

same_id(A, B) -> ias_html:text(A) =:= ias_html:text(B).
