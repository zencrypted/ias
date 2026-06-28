-module(ias_graph_analysis_tests).
-include_lib("eunit/include/eunit.hrl").

policy_mismatch_warning_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"analysis_device">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"analysis_certificate">>}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, Device),
                                           maps:get(id, Certificate)),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                           maps:get(id, Device),
                                           <<"high_security">>),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                           maps:get(id, Certificate),
                                           <<"standard">>),

    Report = ias_graph_analysis:report(),
    [Warning] = maps:get(policy_mismatches, Report),

    ?assertEqual(maps:get(id, Device), maps:get(device_id, Warning)),
    ?assertEqual(maps:get(id, Certificate), maps:get(certificate_id, Warning)),
    ?assertEqual(<<"high_security">>, maps:get(device_policy, Warning)),
    ?assertEqual(<<"standard">>, maps:get(certificate_policy, Warning)).

missing_policy_and_service_warnings_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"analysis_unsecured_device">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"analysis_unsecured_certificate">>}),

    Report = ias_graph_analysis:report(),

    ?assert(lists:any(has_id(maps:get(id, Device)),
                      maps:get(devices_without_security_policy, Report))),
    ?assert(lists:any(has_id(maps:get(id, Certificate)),
                      maps:get(certificates_without_security_policy, Report))),
    ?assert(lists:any(has_id(maps:get(id, Device)),
                      maps:get(devices_without_vpn_service, Report))).

enrollment_certificate_without_issued_certificate_warning_test() ->
    ias_demo_store:clear(),
    EnrollmentCertificate =
        ias_demo_store:add_certificate(#{id => <<"analysis_enrollment_certificate">>,
                                         source => cmp_demo_enrollment}),

    Report = ias_graph_analysis:report(),

    ?assert(lists:any(has_id(maps:get(id, EnrollmentCertificate)),
                      maps:get(enrollment_certificates_without_issued_certificate, Report))).

certificate_linked_to_multiple_devices_warning_test() ->
    ias_demo_store:clear(),
    DeviceA = ias_demo_store:add_device(#{id => <<"analysis_device_a">>}),
    DeviceB = ias_demo_store:add_device(#{id => <<"analysis_device_b">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"analysis_shared_certificate">>}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, DeviceA),
                                           maps:get(id, Certificate)),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, DeviceB),
                                           maps:get(id, Certificate)),

    Report = ias_graph_analysis:report(),
    [Warning] = maps:get(certificates_linked_to_multiple_devices, Report),

    ?assertEqual(maps:get(id, Certificate), maps:get(certificate_id, Warning)),
    ?assert(lists:member(maps:get(id, DeviceA), maps:get(device_ids, Warning))),
    ?assert(lists:member(maps:get(id, DeviceB), maps:get(device_ids, Warning))).

device_with_replacement_available_warning_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"analysis_replace_device">>,
                                         import_id => <<"analysis_replace">>,
                                         type => <<"router-1">>}),
    Current = ias_demo_store:add_certificate(#{id => <<"analysis_current_certificate">>,
                                               import_id => <<"analysis_replace">>,
                                               source => ovpn_demo_import}),
    Candidate = ias_demo_store:add_certificate(#{id => <<"analysis_candidate_certificate">>,
                                                 source => cmp_demo_enrollment,
                                                 requested_cn => <<"router-1">>,
                                                 enrollment_cn => <<"router-1-20260615">>}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, Device),
                                           maps:get(id, Current)),

    Report = ias_graph_analysis:report(),
    [Warning] = maps:get(devices_with_replacement_available, Report),

    ?assertEqual(maps:get(id, Device), maps:get(device_id, Warning)),
    ?assertEqual(maps:get(id, Current), maps:get(current_certificate_id, Warning)),
    ?assertEqual(maps:get(id, Candidate), maps:get(candidate_certificate_id, Warning)).

graph_analysis_pending_enrollment_details_test() ->
    ias_demo_store:clear(),
    _Certificate =
        ias_demo_store:add_certificate(#{id => <<"analysis_pending_enrollment_certificate">>,
                                         source => cmp_demo_enrollment}),

    Html = rendered_details(),

    ?assertMatch({_, _}, binary:match(Html, <<"Pending enrollment certificates">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Certificate #analysis_pending_enrollment_certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"/app/demo.htm?id=analysis_pending_enrollment_certificate">>)).

graph_analysis_policy_mismatch_details_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"analysis_mismatch_device">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"analysis_mismatch_certificate">>}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, Device),
                                           maps:get(id, Certificate)),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                           maps:get(id, Device),
                                           <<"standard">>),
    {ok, _} = ias_relationship_link:create(uses_security_policy,
                                           maps:get(id, Certificate),
                                           <<"high_security">>),

    Html = rendered_details(),

    ?assertMatch({_, _}, binary:match(Html, <<"Policy mismatch">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Device #analysis_mismatch_device">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Certificate #analysis_mismatch_certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Device Policy: standard">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Certificate Policy: high_security">>)).

graph_analysis_multiple_devices_details_test() ->
    ias_demo_store:clear(),
    DeviceA = ias_demo_store:add_device(#{id => <<"analysis_multi_device_a">>}),
    DeviceB = ias_demo_store:add_device(#{id => <<"analysis_multi_device_b">>}),
    Certificate = ias_demo_store:add_certificate(#{id => <<"analysis_multi_certificate">>}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, DeviceA),
                                           maps:get(id, Certificate)),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, DeviceB),
                                           maps:get(id, Certificate)),

    Html = rendered_details(),

    ?assertMatch({_, _}, binary:match(Html, <<"Certificate linked to multiple devices">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Certificate #analysis_multi_certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Device #analysis_multi_device_a">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Device #analysis_multi_device_b">>)).

graph_analysis_replacement_details_test() ->
    ias_demo_store:clear(),
    Device = ias_demo_store:add_device(#{id => <<"analysis_detail_replace_device">>,
                                         import_id => <<"analysis_detail_replace">>,
                                         type => <<"router-1">>}),
    Current = ias_demo_store:add_certificate(#{id => <<"analysis_detail_current_certificate">>,
                                               import_id => <<"analysis_detail_replace">>,
                                               source => ovpn_demo_import}),
    _Candidate = ias_demo_store:add_certificate(#{id => <<"analysis_detail_candidate_certificate">>,
                                                  source => cmp_demo_enrollment,
                                                  requested_cn => <<"router-1">>,
                                                  enrollment_cn => <<"router-1-20260615">>}),
    {ok, _} = ias_relationship_link:create(uses_certificate,
                                           maps:get(id, Device),
                                           maps:get(id, Current)),

    Html = rendered_details(),

    ?assertMatch({_, _}, binary:match(Html, <<"Device with replacement available">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Device #analysis_detail_replace_device">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Current Certificate:">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Certificate #analysis_detail_current_certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Candidate Certificate:">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Certificate #analysis_detail_candidate_certificate">>)).

rendered_details() ->
    iolist_to_binary(nitro:render(ias_graph_analysis_details:warning_blocks(ias_graph_analysis:report()))).

has_id(Id) ->
    fun(Warning) -> maps:get(id, Warning, undefined) =:= Id end.
