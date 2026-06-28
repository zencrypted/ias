-module(ias_relationship_candidate_layout_tests).
-include_lib("eunit/include/eunit.hrl").

long_certificate_id_uses_anywhere_wrapping_test() ->
    ias_demo_store:clear(),
    Device = device(<<"layout_long_device">>),
    LongId = <<"layout_certificate_with_a_very_long_identifier_that_should_not_turn_vertical_0123456789">>,
    _Certificate = client_certificate(LongId),

    Html = render(Device),

    ?assertEqual(nomatch, binary:match(Html, <<"word-break:break-all">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"overflow-wrap:anywhere">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"word-break:normal">>)),
    ?assertMatch({_, _}, binary:match(Html, LongId)).

occupied_certificate_slot_shows_one_compact_notice_test() ->
    ias_demo_store:clear(),
    Device = device(<<"layout_cert_slot_device">>),
    Active = client_certificate(<<"layout_active_certificate">>),
    _Candidate = client_certificate(<<"layout_second_certificate">>),
    {ok, _} = ias_relationship_link:create(uses_certificate, id(Device), id(Active)),

    Html = render(Device),

    ?assertEqual(1, occurrences(Html, <<"Another certificate cannot be linked">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Active Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Unlink">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"layout_second_certificate">>)).

occupied_vpn_service_slot_shows_one_compact_notice_test() ->
    ias_demo_store:clear(),
    Device = device(<<"layout_service_slot_device">>),
    Active = service(<<"layout_active_service">>),
    _Candidate = service(<<"layout_second_service">>),
    {ok, _} = ias_relationship_link:create(uses_service, id(Device), id(Active)),

    Html = render(Device),

    ?assertEqual(1, occurrences(Html, <<"Another VPN service cannot be linked">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Active VPN Service">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Unlink">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"layout_second_service">>)).

occupied_ca_certificate_slot_shows_one_compact_notice_test() ->
    ias_demo_store:clear(),
    Service = service(<<"layout_ca_slot_service">>),
    Active = ca_certificate(<<"layout_active_ca_certificate">>),
    _Candidate = ca_certificate(<<"layout_second_ca_certificate">>),
    {ok, _} = ias_relationship_link:create(uses_ca_certificate, id(Service), id(Active)),

    Html = render(Service),

    ?assertEqual(1, occurrences(Html, <<"Another CA certificate cannot be linked">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Active CA Certificate">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Unlink">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"layout_second_ca_certificate">>)).

free_slot_still_shows_candidates_test() ->
    ias_demo_store:clear(),
    Device = device(<<"layout_free_device">>),
    Certificate = client_certificate(<<"layout_free_certificate">>),
    Service = service(<<"layout_free_service">>),

    Html = render(Device),

    ?assertMatch({_, _}, binary:match(Html, id(Certificate))),
    ?assertMatch({_, _}, binary:match(Html, id(Service))),
    ?assertMatch({_, _}, binary:match(Html, <<"Link">>)).

unclassified_warning_is_compact_test() ->
    ias_demo_store:clear(),
    Device = device(<<"layout_unknown_device">>),
    _Certificate = unknown_certificate(<<"layout_unknown_certificate">>),

    Html = render(Device),

    ?assertMatch({_, _}, binary:match(Html, <<"Unclassified role">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"certificate role is unclassified">>)).

blocked_reason_is_rendered_only_in_action_test() ->
    ias_demo_store:clear(),
    Device = device(<<"layout_blocked_role_device">>),
    _Ca = ca_certificate(<<"layout_blocked_role_ca">>),

    Html = render(Device),

    ?assertEqual(1, occurrences(Html, <<"CA certificate cannot be linked as a device client certificate">>)).

ca_candidate_labels_are_short_test() ->
    ias_demo_store:clear(),
    Service = service_no_flow(<<"layout_ca_label_service">>),
    _Ca = ca_certificate(<<"layout_ca_label_certificate">>),
    _Unknown = unknown_certificate(<<"layout_ca_label_unknown_certificate">>),

    Html = render(Service),

    ?assertMatch({_, _}, binary:match(Html, <<"Suggested CA">>)),
    ?assertMatch({_, _}, binary:match(Html, <<"Available CA">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Suggested CA Certificates">>)),
    ?assertEqual(nomatch, binary:match(Html, <<"Available CA Certificates">>)).

render(Object) ->
    iolist_to_binary(nitro:render(ias_demo:relationship_preview(Object))).

device(Id) ->
    ias_demo_store:add_device(#{id => Id,
                                source => manual_device,
                                type => <<"vpn-client">>,
                                endpoint => <<"vpn.example.com:1194">>}).

service(Id) ->
    ias_demo_store:add_service(#{id => Id,
                                 source => manual_vpn_service,
                                 service => openvpn,
                                 remote => <<"vpn.example.com:1194">>,
                                 protocol => udp}).

service_no_flow(Id) ->
    ias_demo_store:put_runtime_object(#{id => Id,
                                        kind => vpn_service,
                                        service => openvpn,
                                        remote => <<"vpn.example.com:1194">>,
                                        protocol => udp}).

client_certificate(Id) ->
    ias_demo_store:add_certificate(#{id => Id,
                                     source => certificate_issue_demo,
                                     profile_id => default_user,
                                     profile => default_user,
                                     private_key_stored => false,
                                     certificate_body_stored => false}).

ca_certificate(Id) ->
    ias_demo_store:add_certificate(#{id => Id,
                                     source => ca_certificate,
                                     subject => <<"CN=CA">>}).

unknown_certificate(Id) ->
    ias_demo_store:put_runtime_object(#{id => Id,
                                        kind => certificate,
                                        private_key_stored => false,
                                        certificate_body_stored => false}).

id(Object) ->
    maps:get(id, Object).

occurrences(Haystack, Needle) ->
    occurrences(Haystack, Needle, 0).

occurrences(Haystack, Needle, Count) ->
    case binary:match(Haystack, Needle) of
        nomatch ->
            Count;
        {Pos, Len} ->
            RestStart = Pos + Len,
            RestLen = byte_size(Haystack) - RestStart,
            occurrences(binary:part(Haystack, RestStart, RestLen), Needle, Count + 1)
    end.
