-module(ias_relationship_preview_tests).
-include_lib("eunit/include/eunit.hrl").

device_relationship_preview_test() ->
    {Device, Certificate, Service} = ovpn_objects(),
    Preview = ias_relationship_preview:preview(Device),

    ?assertEqual(not_linked, maps:get(related_certificate, Preview)),
    ?assertEqual(not_linked, maps:get(related_vpn_service, Preview)),
    ?assertEqual([maps:get(id, Certificate)], ids(maps:get(suggested_certificates, Preview))),
    ?assertEqual([maps:get(id, Service)], ids(maps:get(suggested_services, Preview))).

certificate_relationship_preview_test() ->
    {Device, Certificate, _Service} = ovpn_objects(),
    Preview = ias_relationship_preview:preview(Certificate),

    ?assertEqual(not_linked, maps:get(used_by_device, Preview)),
    ?assertEqual([maps:get(id, Device)], ids(maps:get(suggested_devices, Preview))).

vpn_service_relationship_preview_test() ->
    {Device, _Certificate, Service} = ovpn_objects(),
    Preview = ias_relationship_preview:preview(Service),

    ?assertEqual(not_linked, maps:get(used_by_device, Preview)),
    ?assertEqual([maps:get(id, Device)], ids(maps:get(suggested_devices, Preview))).

relationship_preview_creates_no_relationship_records_test() ->
    {Device, Certificate, Service} = ovpn_objects(),
    _ = ias_relationship_preview:preview(Device),
    _ = ias_relationship_preview:preview(Certificate),
    _ = ias_relationship_preview:preview(Service),

    RelationshipRecords = [Object || Object <- ias_demo_store:all(),
                                     maps:get(kind, Object, undefined) =:= relationship],
    ?assertEqual([], RelationshipRecords).

ovpn_objects() ->
    ias_demo_store:clear(),
    {ok, OVPN} = file:read_file("test/fixtures/example.ovpn"),
    Preview = ias_ovpn_preview:analyze(OVPN),
    _ImportId = ias_demo_store:add_import(ias_ovpn_import:import_map(Preview)),
    [Device] = ias_demo_store:devices(),
    [Certificate] = ias_demo_store:certificates(),
    [Service] = ias_demo_store:services(),
    {Device, Certificate, Service}.

ids(Objects) ->
    [maps:get(id, Object) || Object <- Objects].
