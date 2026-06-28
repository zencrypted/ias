-module(ias_certificate_detail).
-export([metadata/1, security_policy/1, certificate_class/1, certificate_class_note/1]).

certificate_class(#{kind := certificate} = Certificate) ->
    Id = maps:get(id, Certificate, <<>>),
    case certificate_class_from_role(Certificate) of
        unknown ->
            case certificate_class_from_material(Certificate) of
                unknown ->
                    case certificate_class_from_source(Certificate) of
                        unknown -> certificate_class_from_id(Id);
                        Class -> Class
                    end;
                Class ->
                    Class
            end;
        Class ->
            Class
    end;
certificate_class(_Certificate) ->
    <<"Unknown Certificate">>.

certificate_class_note(#{kind := certificate} = Certificate) ->
    case certificate_class(Certificate) of
        <<"Issued Identity Certificate">> ->
            <<"IAS-managed certificate issued to a user/security profile; role authorization applies">>;
        <<"Enrollment Certificate">> ->
            <<"CA/CMP enrollment artifact; issue it to a user/security profile before role authorization applies">>;
        <<"Imported OVPN Certificate">> ->
            <<"Imported OpenVPN artifact used for migration, onboarding, and endpoint discovery">>;
        <<"CA Certificate">> ->
            <<"Operator-registered CA trust anchor used by VPN services. Public certificate material is stored separately from Demo State metadata.">>;
        _ ->
            <<"Certificate class could not be resolved from source metadata">>
    end;
certificate_class_note(_Certificate) ->
    <<"Certificate class could not be resolved from source metadata">>.

certificate_class_from_role(#{certificate_role := ca_certificate}) ->
    <<"CA Certificate">>;
certificate_class_from_role(_Certificate) ->
    unknown.

certificate_class_from_material(#{material_type := ca_certificate}) ->
    <<"CA Certificate">>;
certificate_class_from_material(_Certificate) ->
    unknown.

certificate_class_from_source(#{source := certificate_issue_demo}) ->
    <<"Issued Identity Certificate">>;
certificate_class_from_source(#{source := cmp_demo_enrollment}) ->
    <<"Enrollment Certificate">>;
certificate_class_from_source(#{source := ovpn_demo_import}) ->
    <<"Imported OVPN Certificate">>;
certificate_class_from_source(#{source := ca_certificate}) ->
    <<"CA Certificate">>;
certificate_class_from_source(_Certificate) ->
    unknown.

certificate_class_from_id(Id) when is_binary(Id) ->
    case has_prefix(Id, <<"issued_certificate_">>) of
        true -> <<"Issued Identity Certificate">>;
        false ->
            case has_prefix(Id, <<"cmp_enrollment_">>) of
                true -> <<"Enrollment Certificate">>;
                false ->
                    case has_prefix(Id, <<"ovpn_import_">>) of
                        true -> <<"Imported OVPN Certificate">>;
                        false ->
                            case has_prefix(Id, <<"manual_ca_certificate_">>) of
                                true -> <<"CA Certificate">>;
                                false -> <<"Unknown Certificate">>
                            end
                    end
            end
    end;
certificate_class_from_id(_Id) ->
    <<"Unknown Certificate">>.

has_prefix(Bin, Prefix) when is_binary(Bin), is_binary(Prefix) ->
    Size = byte_size(Prefix),
    byte_size(Bin) >= Size andalso binary:part(Bin, 0, Size) =:= Prefix.

metadata(#{kind := certificate} = Certificate) ->
    #{issued_user_id => maps:get(user, Certificate, undefined),
      issued_user => maps:get(user_name, Certificate, maps:get(user, Certificate, undefined)),
      source_security_profile => source_profile_id(Certificate),
      role => maps:get(role, Certificate, undefined),
      services => maps:get(services, Certificate, []),
      attributes => maps:get(attributes, Certificate, []),
      trust_level => maps:get(trust_level, Certificate, undefined),
      device_lock => maps:get(device_lock, Certificate, undefined),
      two_factor => maps:get(two_factor, Certificate, undefined)};
metadata(_Certificate) ->
    #{}.

security_policy(#{kind := certificate} = Certificate) ->
    case source_profile_policy(Certificate) of
        not_found -> ias_security_profile:applied_policy(Certificate);
        Policy -> Policy
    end;
security_policy(Object) ->
    ias_security_profile:applied_policy(Object).

source_profile_policy(Certificate) ->
    ProfileId = source_profile_id(Certificate),
    case ias_security_profile:profile(ProfileId) of
        {ok, Profile} ->
            #{id => ProfileId,
              profile => ProfileId,
              kind => security_profile_policy,
              source => certificate_issue_demo,
              device_lock => ias_policy:device_lock(Profile),
              two_factor => ias_policy:two_factor(Profile),
              enforcement_mode => preview_only};
        not_found ->
            not_found
    end.

source_profile_id(Certificate) ->
    maps:get(profile_id, Certificate, maps:get(profile, Certificate, undefined)).
