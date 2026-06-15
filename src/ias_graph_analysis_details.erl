-module(ias_graph_analysis_details).
-export([warning_blocks/1]).
-include_lib("nitro/include/nitro.hrl").

warning_blocks(Analysis) ->
    [warning_block(Spec) || Spec <- warning_specs(Analysis)].

warning_specs(Analysis) ->
    [
        {<<"Policy mismatches">>,
         maps:get(policy_mismatches, Analysis, []),
         <<"Policy mismatches">>,
         fun policy_mismatch_detail/1},
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
                        object_link(certificate, maps:get(candidate_certificate_id, Warning, not_found))]}
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
object_label(user) ->
    <<"User">>;
object_label(security_profile) ->
    <<"Security Profile">>;
object_label(cmp_enrollment_result) ->
    <<"Certificate Enrollment">>;
object_label(Kind) ->
    ias_html:text(Kind).

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
