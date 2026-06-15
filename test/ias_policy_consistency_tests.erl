-module(ias_policy_consistency_tests).
-include_lib("eunit/include/eunit.hrl").

policy_match_test() ->
    ias_demo_store:clear(),
    {Device, Certificate} = linked_device_certificate(<<"device_policy_match">>,
                                                      <<"cert_policy_match">>),
    {ok, _DevicePolicy} = ias_relationship_link:create(uses_security_policy,
                                                       maps:get(id, Device),
                                                       <<"high_security">>),
    {ok, _CertificatePolicy} = ias_relationship_link:create(uses_security_policy,
                                                            maps:get(id, Certificate),
                                                            <<"high_security">>),

    Result = ias_policy_consistency:evaluate_policy_consistency(maps:get(id, Device),
                                                                maps:get(id, Certificate)),

    ?assertEqual(true, maps:get(match, Result)),
    ?assertEqual(<<"high_security">>, maps:get(device_policy, Result)),
    ?assertEqual(<<"high_security">>, maps:get(certificate_policy, Result)).

policy_mismatch_test() ->
    ias_demo_store:clear(),
    {Device, Certificate} = linked_device_certificate(<<"device_policy_mismatch">>,
                                                      <<"cert_policy_mismatch">>),
    {ok, _DevicePolicy} = ias_relationship_link:create(uses_security_policy,
                                                       maps:get(id, Device),
                                                       <<"high_security">>),
    {ok, _CertificatePolicy} = ias_relationship_link:create(uses_security_policy,
                                                            maps:get(id, Certificate),
                                                            <<"standard">>),

    Result = ias_policy_consistency:evaluate_policy_consistency(maps:get(id, Device),
                                                                maps:get(id, Certificate)),

    ?assertEqual(false, maps:get(match, Result)),
    ?assertEqual(<<"high_security">>, maps:get(device_policy, Result)),
    ?assertEqual(<<"standard">>, maps:get(certificate_policy, Result)),
    ?assertEqual(<<"device requires high_security; certificate provides standard">>,
                 maps:get(reason, Result)).

no_policy_on_one_side_test() ->
    ias_demo_store:clear(),
    {Device, Certificate} = linked_device_certificate(<<"device_policy_missing">>,
                                                      <<"cert_policy_missing">>),
    {ok, _DevicePolicy} = ias_relationship_link:create(uses_security_policy,
                                                       maps:get(id, Device),
                                                       <<"high_security">>),

    Result = ias_policy_consistency:evaluate_policy_consistency(maps:get(id, Device),
                                                                maps:get(id, Certificate)),

    ?assertEqual(false, maps:get(match, Result)),
    ?assertEqual(<<"high_security">>, maps:get(device_policy, Result)),
    ?assertEqual(not_found, maps:get(certificate_policy, Result)),
    ?assertEqual(<<"no policy available">>, maps:get(reason, Result)).

linked_device_certificate(DeviceId, CertificateId) ->
    Device = ias_demo_store:add_device(#{id => DeviceId}),
    Certificate = ias_demo_store:add_certificate(#{id => CertificateId}),
    {ok, _Relationship} = ias_relationship_link:create(uses_certificate,
                                                       maps:get(id, Device),
                                                       maps:get(id, Certificate)),
    {Device, Certificate}.
