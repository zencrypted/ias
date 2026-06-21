-module(ias_provisioning_wizard_authorization).
-export([derived_policy/1,
         derived_policy_id/1,
         verification_status/1,
         verify_client_certificate/1]).

derived_policy(Draft) when is_map(Draft) ->
    case ias_provisioning_wizard_store:selected_security_profile(Draft) of
        {ok, Profile} ->
            PolicyId = policy_id(Profile),
            case ias_security_profile:policy(PolicyId) of
                {ok, Policy} -> {ok, Policy};
                not_found -> {error, security_policy_not_found}
            end;
        not_selected ->
            {error, security_profile_required};
        {error, Reason} ->
            {error, Reason}
    end;
derived_policy(_Draft) ->
    {error, invalid_draft}.

derived_policy_id(Draft) ->
    case derived_policy(Draft) of
        {ok, Policy} -> maps:get(id, Policy, undefined);
        {error, _Reason} -> undefined
    end.

verification_status(Draft) when is_map(Draft) ->
    case ias_provisioning_wizard_store:selected_client_certificate(Draft) of
        {ok, Certificate} ->
            verification_history_status(
              ias_certificate_verification:verification_history(Certificate));
        not_selected -> not_selected;
        {error, _Reason} -> unavailable
    end;
verification_status(_Draft) ->
    unavailable.

verify_client_certificate(Draft) when is_map(Draft) ->
    case ias_provisioning_wizard_store:selected_client_certificate(Draft) of
        {ok, Certificate} ->
            CertificateId = maps:get(id, Certificate, undefined),
            case ias_verify_cert:verification_certificate(CertificateId) of
                not_found -> {error, certificate_not_found};
                VerificationInput -> ias_certificate_verification:verify(VerificationInput)
            end;
        not_selected ->
            {error, client_certificate_required};
        {error, Reason} ->
            {error, Reason}
    end;
verify_client_certificate(_Draft) ->
    {error, invalid_draft}.

policy_id(Profile) ->
    case maps:get(device_lock, Profile, disabled) of
        enabled -> <<"high_security">>;
        _ -> <<"standard">>
    end.

verification_history_status(History) ->
    case lists:any(fun successful_verification/1, History) of
        true -> verified;
        false ->
            case lists:any(fun failed_verification/1, History) of
                true -> failed;
                false -> not_verified
            end
    end.

successful_verification(Verification) ->
    maps:get(verification_status, Verification, undefined) =:= verified.

failed_verification(Verification) ->
    maps:get(verification_status, Verification, undefined) =:= failed.
