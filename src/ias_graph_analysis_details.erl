-module(ias_graph_analysis_details).
-export([warning_blocks/1]).
-include_lib("nitro/include/nitro.hrl").

warning_blocks(Analysis) ->
    [readiness_block(maps:get(device_operational_readiness, Analysis,
                              #{ready => [], incomplete => []}))
     | [warning_block(Spec) || Spec <- warning_specs(Analysis)]].

readiness_block(Readiness) ->
    Ready = maps:get(ready, Readiness, []),
    Incomplete = maps:get(incomplete, Readiness, []),
    #panel{class = <<"ias-analysis-warning">>, body = [
        #h3{body = ias_html:text("DEVICE OPERATIONAL READINESS")},
        #panel{class = <<"ias-analysis-details">>, body = [
            #p{style = <<"font-weight:600;">>,
               body = ias_html:join([<<"Ready Devices (">>, length(Ready), <<")">>])},
            readiness_list(Ready, ready),
            #p{style = <<"font-weight:600;">>,
               body = ias_html:join([<<"Incomplete Devices (">>, length(Incomplete), <<")">>])},
            readiness_list(Incomplete, incomplete)
        ]}
    ]}.

readiness_list([], _Status) ->
    #p{body = ias_html:text("none")};
readiness_list(Devices, Status) ->
    #ul{body = [readiness_detail(Device, Status) || Device <- Devices]}.

readiness_detail(Readiness, Status) ->
    #li{body = [
        object_link(device, maps:get(device_id, Readiness, undefined)),
        #ul{body = readiness_rows(Readiness, Status)}
    ]}.

readiness_rows(Readiness, ready) ->
    [#li{body = ias_html:text("Status: READY")},
     #li{body = [ias_html:text("VPN Service: "),
                 object_or_value(vpn_service, maps:get(vpn_service_id, Readiness, not_found))]},
     #li{body = [ias_html:text("Security Policy: "),
                 object_or_value(security_policy, maps:get(security_policy_id, Readiness, not_found))]},
     #li{body = [ias_html:text("Current Certificate: "),
                 object_or_value(certificate, maps:get(current_certificate_id, Readiness, not_found))]},
     #li{body = ias_html:text("Certificate Verification: verified")},
     #li{body = ias_html:text("Certificate Revocation: active")}];
readiness_rows(Readiness, incomplete) ->
    [#li{body = ias_html:text("Status: INCOMPLETE")},
     #li{body = [ias_html:text("VPN Service: "),
                 object_or_value(vpn_service, maps:get(vpn_service_id, Readiness, not_found))]},
     #li{body = [ias_html:text("Security Policy: "),
                 object_or_value(security_policy, maps:get(security_policy_id, Readiness, not_found))]},
     #li{body = [ias_html:text("Current Certificate: "),
                 object_or_value(certificate, maps:get(current_certificate_id, Readiness, not_found))]},
     #li{body = ias_html:join([<<"Certificate Verification: ">>,
                               maps:get(certificate_verification, Readiness, not_verified)])},
     #li{body = ias_html:join([<<"Certificate Revocation: ">>,
                               maps:get(certificate_revocation, Readiness, active)])},
     #li{body = [ias_html:text("Missing:"),
                 bullet_list(maps:get(missing, Readiness, []), <<"none">>)]},
     #li{body = [ias_html:text("Suggested Actions:"),
                 readiness_action_list(Readiness)]}].

object_or_value(_Kind, not_found) ->
    ias_html:text("not linked yet");
object_or_value(Kind, Id) ->
    object_link(Kind, Id).

bullet_list([], Empty) ->
    #ul{body = [#li{body = ias_html:text(Empty)}]};
bullet_list(Items, _Empty) ->
    #ul{body = [#li{body = ias_html:text(Item)} || Item <- Items]}.

readiness_action_list(#{suggested_actions := []}) ->
    #ul{body = [#li{body = ias_html:text("none")}]};
readiness_action_list(Readiness) ->
    Actions = maps:get(suggested_actions, Readiness, []),
    #ul{body = [#li{body = readiness_action_body(Action, Readiness)}
                || Action <- Actions]}.

readiness_action_body(Action, Readiness) ->
    Target = readiness_action_target(Action, Readiness),
    [ias_html:text(Action), ias_html:text(" "), readiness_action_link(Target)].

readiness_action_target(<<"Link Certificate Security Policy">>, Readiness) ->
    {certificate, maps:get(current_certificate_id, Readiness, not_found),
     <<"Open Current Certificate">>};
readiness_action_target(<<"Verify Current Certificate">>, Readiness) ->
    {certificate, maps:get(current_certificate_id, Readiness, not_found),
     <<"Open Current Certificate">>};
readiness_action_target(_Action, Readiness) ->
    {device, maps:get(device_id, Readiness, not_found), <<"Open Device">>}.

readiness_action_link({_Kind, not_found, Label}) ->
    #span{style = <<"color:#6b7280;font-size:12px;">>, body = ias_html:text(Label)};
readiness_action_link({Kind, Id, Label}) ->
    #link{class = [button, sgreen],
          url = object_url(Kind, Id),
          body = ias_html:text(Label)}.

warning_specs(Analysis) ->
    [
        {<<"Policy mismatches">>,
         maps:get(policy_mismatches, Analysis, []),
         <<"Policy mismatches">>,
         fun policy_mismatch_detail/1},
        {<<"Unique Verified Certificates">>,
         maps:get(unique_verified_certificates, Analysis, []),
         <<"Unique Verified Certificates">>,
         fun unique_verified_certificate_detail/1},
        {<<"Total Verification Records">>,
         maps:get(total_verification_records, Analysis, []),
         <<"Total Verification Records">>,
         fun object_list_detail/1},
        {<<"Failed verifications">>,
         maps:get(failed_verifications, Analysis, []),
         <<"Failed verifications">>,
         fun failed_verification_detail/1},
        {<<"Certificates never verified">>,
         maps:get(certificates_never_verified, Analysis, []),
         <<"Certificates never verified">>,
         fun object_list_detail/1},
        {<<"Revoked Certificates">>,
         maps:get(revoked_certificates, Analysis, []),
         <<"Revoked Certificates">>,
         fun revoked_certificate_detail/1},
        {<<"Certificates using revoked current certificate">>,
         maps:get(certificates_using_revoked_current_certificate, Analysis, []),
         <<"Certificates using revoked current certificate">>,
         fun object_list_detail/1},
        {<<"Devices with revoked current certificate">>,
         maps:get(devices_with_revoked_current_certificate, Analysis, []),
         <<"Devices with revoked current certificate">>,
         fun revoked_device_detail/1},
        {<<"Verifications without security policy">>,
         maps:get(verifications_without_security_policy, Analysis, []),
         <<"Verifications without security policy">>,
         fun object_list_detail/1},
        {<<"Devices without security policy">>,
         maps:get(devices_without_security_policy, Analysis, []),
         <<"Devices without security policy">>,
         fun object_list_detail/1},
        {<<"Certificates without security policy">>,
         maps:get(certificates_without_security_policy, Analysis, []),
         <<"Certificates without security policy">>,
         fun object_list_detail/1},
        {<<"Devices without VPN service">>,
         maps:get(devices_without_vpn_service, Analysis, []),
         <<"Devices without VPN service">>,
         fun object_list_detail/1},
        {<<"Enrollment certificates without issued certificate">>,
         maps:get(enrollment_certificates_without_issued_certificate, Analysis, []),
         <<"Pending enrollment certificates">>,
         fun object_list_detail/1},
        {<<"Certificates linked to multiple devices">>,
         maps:get(certificates_linked_to_multiple_devices, Analysis, []),
         <<"Certificate linked to multiple devices">>,
         fun multiple_device_detail/1},
        {<<"Devices with replacement available">>,
         maps:get(devices_with_replacement_available, Analysis, []),
         <<"Device with replacement available">>,
         fun replacement_detail/1}
    ].

warning_block({Label, Warnings, DetailTitle, DetailFun}) ->
    #panel{class = <<"ias-analysis-warning">>, body = [
        #h3{body = ias_html:text(Label)},
        key_value_table([
            {"Count", length(Warnings)}
        ]),
        details(DetailTitle, Warnings, DetailFun)
    ]}.

details(_DetailTitle, [], _DetailFun) ->
    #p{body = ias_html:text("none")};
details(DetailTitle, Warnings, DetailFun) ->
    #panel{class = <<"ias-analysis-details">>, body = [
        #p{style = <<"font-weight:600;">>, body = ias_html:text(DetailTitle)},
        #ul{body = [DetailFun(Warning) || Warning <- Warnings]}
    ]}.

policy_mismatch_detail(Warning) ->
    #li{body = [
        ias_html:text("Policy mismatch:"),
        #ul{body = [
            #li{body = [object_link(device, maps:get(device_id, Warning, undefined))]},
            #li{body = [object_link(certificate, maps:get(certificate_id, Warning, undefined))]},
            #li{body = ias_html:join([<<"Device Policy: ">>,
                                      maps:get(device_policy, Warning, not_found)])},
            #li{body = ias_html:join([<<"Certificate Policy: ">>,
                                      maps:get(certificate_policy, Warning, not_found)])}
        ]}
    ]}.

object_list_detail(Warning) ->
    #li{body = [object_link(maps:get(kind, Warning, undefined),
                            maps:get(id, Warning, undefined))]}.

unique_verified_certificate_detail(Warning) ->
    #li{body = [
        object_link(certificate, maps:get(certificate_id, Warning, undefined)),
        #ul{body = [
            #li{body = [
                ias_html:text("Verifications:"),
                #ul{body = [#li{body = [object_link(verification, VerificationId)]}
                            || VerificationId <- maps:get(verification_ids, Warning, [])]}
            ]}
        ]}
    ]}.

failed_verification_detail(Warning) ->
    #li{body = [
        object_link(verification, maps:get(id, Warning, undefined)),
        #ul{body = [
            #li{body = [ias_html:text("Certificate: "),
                        object_link(certificate, maps:get(certificate_id, Warning, undefined))]},
            #li{body = ias_html:join([<<"Status: ">>,
                                      maps:get(verification_status, Warning, undefined)])},
            #li{body = ias_html:join([<<"Service Authorization Result: ">>,
                                      maps:get(authorization_status, Warning, undefined)])}
        ]}
    ]}.

revoked_certificate_detail(Warning) ->
    #li{body = [
        object_link(certificate, maps:get(id, Warning, undefined)),
        #ul{body = [
            #li{body = [ias_html:text("Revocation Record: "),
                        object_or_value(certificate_revocation,
                                        maps:get(revocation_id, Warning, not_found))]}
        ]}
    ]}.

revoked_device_detail(Warning) ->
    #li{body = [
        object_link(device, maps:get(device_id, Warning, undefined)),
        #ul{body = [
            #li{body = [ias_html:text("Current Certificate: "),
                        object_or_value(certificate, maps:get(certificate_id, Warning, not_found))]},
            #li{body = [ias_html:text("Revocation Record: "),
                        object_or_value(certificate_revocation,
                                        maps:get(revocation_id, Warning, not_found))]}
        ]}
    ]}.

multiple_device_detail(Warning) ->
    #li{body = [
        object_link(certificate, maps:get(certificate_id, Warning, undefined)),
        #br{},
        ias_html:text("Devices:"),
        #ul{body = [#li{body = [object_link(device, DeviceId)]}
                    || DeviceId <- maps:get(device_ids, Warning, [])]}
    ]}.

replacement_detail(Warning) ->
    #li{body = [
        object_link(device, maps:get(device_id, Warning, undefined)),
        #ul{body = [
            #li{body = [ias_html:text("Current Certificate: "),
                        object_link(certificate, maps:get(current_certificate_id, Warning, not_found))]},
            #li{body = [ias_html:text("Candidate Certificate: "),
                        object_link(certificate, maps:get(candidate_certificate_id, Warning, not_found))]},
            #li{body = [ias_html:text("Action: "),
                        replacement_action(Warning)]}
        ]}
    ]}.

object_link(Kind, Id) ->
    case ias_demo_store:get(Id) of
        {ok, #{kind := Kind}} ->
            #link{url = object_url(Kind, Id),
                  body = ias_html:join([object_label(Kind), <<" #">>, Id])};
        _ ->
            ias_html:join([<<"missing object: ">>, Id])
    end.

object_url(user, Id) ->
    ias_html:join([<<"/app/user.htm?id=">>, ias_html:text(Id)]);
object_url(security_profile, Id) ->
    ias_html:join([<<"/app/profile.htm?id=">>, ias_html:text(Id)]);
object_url(_Kind, Id) ->
    ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(Id)]).

object_label(device) ->
    <<"Device">>;
object_label(certificate) ->
    <<"Certificate">>;
object_label(vpn_service) ->
    <<"VPN Service">>;
object_label(security_policy) ->
    <<"Security Policy">>;
object_label(verification) ->
    <<"Verification">>;
object_label(user) ->
    <<"User">>;
object_label(security_profile) ->
    <<"Security Profile">>;
object_label(cmp_enrollment_result) ->
    <<"Certificate Enrollment">>;
object_label(certificate_replacement) ->
    <<"Certificate Replacement">>;
object_label(certificate_revocation) ->
    <<"Certificate Revocation">>;
object_label(Kind) ->
    ias_html:text(Kind).

replacement_action(Warning) ->
    DeviceId = maps:get(device_id, Warning, undefined),
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} ->
            replacement_action_for_device(Device);
        _ ->
            ias_html:text("missing object")
    end.

replacement_action_for_device(Device) ->
    case ias_certificate_replacement:action_state(Device) of
        replace ->
            #link{class = [button, sgreen],
                  body = ias_html:text("Replace"),
                  postback = {replace_certificate, maps:get(id, Device, undefined)}};
        {blocked, Reason} ->
            ias_html:join([<<"Replacement blocked: ">>, Reason]);
        not_available ->
            ias_html:text("not available")
    end.

key_value_table(Rows) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [key_value_row(Label, Value) || {Label, Value} <- Rows]}}
    ]}.

key_value_row(Label, Value) ->
    #tr{cells = [
        #th{body = ias_html:text(Label)},
        #td{body = ias_html:text(Value)}
    ]}.
