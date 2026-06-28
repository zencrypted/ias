-module(ias_configured_ca_trust_anchor_tests).
-include_lib("eunit/include/eunit.hrl").

absolute_path_loads_ca_trust_anchor_test() ->
    with_temp_dir(fun(Dir) ->
        Path = filename:join(Dir, "ca.pem"),
        ok = file:write_file(Path, ca_pem()),
        with_config(Path, ".", fun() ->
            ias_demo_state:clear(),
            {ok, Certificate} = ias_configured_ca_trust_anchor:load(),
            ?assertEqual(ca_configuration, maps:get(source, Certificate)),
            ?assertEqual(ca_certificate, maps:get(material_type, Certificate)),
            ?assertEqual(ca_certificate, maps:get(certificate_role, Certificate)),
            ?assertMatch({ok, #{source := ca_configuration}},
                         ias_certificate_material:get(maps:get(id, Certificate)))
        end)
    end).

relative_path_is_resolved_against_base_dir_test() ->
    with_temp_dir(fun(Dir) ->
        Base = filename:join(Dir, "ias"),
        CaDir = filename:join([Dir, "ca", "synrc", "ecc", "secp384r1"]),
        ok = filelib:ensure_dir(filename:join(Base, "placeholder")),
        ok = filelib:ensure_dir(filename:join(CaDir, "ca.pem")),
        Path = filename:join(CaDir, "ca.pem"),
        ok = file:write_file(Path, ca_pem()),
        Rel = "../ca/synrc/ecc/secp384r1/ca.pem",
        ?assertEqual({ok, filename:absname(Path)},
                     ias_configured_ca_trust_anchor:resolve_path(Rel, Base))
    end).

custom_base_directory_is_used_test() ->
    with_temp_dir(fun(Dir) ->
        Base = filename:join(Dir, "custom"),
        Path = filename:join(Base, "trust.pem"),
        ok = filelib:ensure_dir(Path),
        ok = file:write_file(Path, ca_pem()),
        with_config("trust.pem", Base, fun() ->
            ias_demo_state:clear(),
            ?assertMatch({ok, #{source := ca_configuration}},
                         ias_configured_ca_trust_anchor:load())
        end)
    end).

missing_file_is_reported_test() ->
    with_temp_dir(fun(Dir) ->
        with_config(filename:join(Dir, "missing.pem"), ".", fun() ->
            ?assertEqual({error, file_not_found},
                         ias_configured_ca_trust_anchor:load())
        end)
    end).

unreadable_file_is_reported_test() ->
    with_temp_dir(fun(Dir) ->
        Path = filename:join(Dir, "unreadable.pem"),
        ok = file:write_file(Path, ca_pem()),
        ok = file:change_mode(Path, 8#000),
        try
            with_config(Path, ".", fun() ->
                ?assertEqual({error, permission_denied},
                             ias_configured_ca_trust_anchor:load())
            end)
        after
            file:change_mode(Path, 8#600)
        end
    end).

private_key_is_rejected_test() ->
    with_temp_dir(fun(Dir) ->
        Path = filename:join(Dir, "ca.key"),
        ok = file:write_file(Path, <<"-----BEGIN PRIVATE KEY-----\nZm9yZ2Vk\n-----END PRIVATE KEY-----\n">>),
        with_config(Path, ".", fun() ->
            ?assertEqual({error, private_key_supplied},
                         ias_configured_ca_trust_anchor:load())
        end)
    end).

non_ca_certificate_is_rejected_test() ->
    with_temp_dir(fun(Dir) ->
        Path = filename:join(Dir, "client.pem"),
        ok = file:write_file(Path, client_pem()),
        with_config(Path, ".", fun() ->
            ?assertEqual({error, certificate_is_not_ca},
                         ias_configured_ca_trust_anchor:load())
        end)
    end).

fingerprint_deduplicates_configured_ca_test() ->
    with_temp_dir(fun(Dir) ->
        Path = filename:join(Dir, "ca.pem"),
        ok = file:write_file(Path, ca_pem()),
        with_config(Path, ".", fun() ->
            ias_demo_state:clear(),
            {ok, First} = ias_configured_ca_trust_anchor:load(),
            {ok, Second} = ias_configured_ca_trust_anchor:load(),
            ?assertEqual(maps:get(id, First), maps:get(id, Second)),
            Fingerprint = maps:get(fingerprint_sha256, First),
            Matching = [Certificate || Certificate <- ias_demo_store:certificates(),
                                       maps:get(fingerprint_sha256, Certificate, undefined) =:= Fingerprint],
            ?assertEqual(1, length(Matching))
        end)
    end).

metadata_is_derived_from_x509_test() ->
    with_temp_dir(fun(Dir) ->
        Path = filename:join(Dir, "ca.pem"),
        ok = file:write_file(Path, ca_pem()),
        with_config(Path, ".", fun() ->
            ias_demo_state:clear(),
            {ok, Certificate} = ias_configured_ca_trust_anchor:load(),
            ?assertEqual(<<"CN=IAS Test CA">>, maps:get(subject, Certificate)),
            ?assertEqual(<<"CN=IAS Test CA">>, maps:get(issuer, Certificate)),
            ?assert(maps:is_key(serial, Certificate)),
            ?assert(maps:is_key(not_before, Certificate)),
            ?assert(maps:is_key(not_after, Certificate)),
            ?assertMatch(<<"configured_ca_trust_anchor_", _/binary>>,
                         maps:get(id, Certificate))
        end)
    end).

configured_ca_auto_selects_and_advances_wizard_test() ->
    with_temp_dir(fun(Dir) ->
        Path = filename:join(Dir, "ca.pem"),
        ok = file:write_file(Path, ca_pem()),
        with_config(Path, ".", fun() ->
            ias_demo_state:clear(),
            {ok, Draft0} = ias_provisioning_wizard_store:new(device_bound),
            {ok, CaStep} = ias_provisioning_wizard_store:update(
                maps:get(id, Draft0), #{current_step => ca_certificate}),
            {ok, Certificate} = ias_configured_ca_trust_anchor:load(),
            {ok, Advanced} = ias_provisioning_wizard_store:select_existing_ca_certificate(
                maps:get(id, CaStep), maps:get(id, Certificate)),
            ?assertEqual(maps:get(id, Certificate), maps:get(ca_certificate_id, Advanced)),
            ?assertEqual(client_certificate, maps:get(current_step, Advanced)),
            Html = iolist_to_binary(nitro:render(
                ias_provisioning_wizard:content_for({draft, Advanced}))),
            ?assertMatch({_, _}, binary:match(Html, <<"Request Certificate from CA using Device CSR">>)),
            ?assertEqual(nomatch, binary:match(Html, <<"Loading live device-bound provisioning wizard">>))
        end)
    end).

configured_path_is_absent_from_demo_state_test() ->
    with_temp_dir(fun(Dir) ->
        Path = filename:join(Dir, "ca.pem"),
        ok = file:write_file(Path, ca_pem()),
        with_config(Path, ".", fun() ->
            ias_demo_state:clear(),
            {ok, _Certificate} = ias_configured_ca_trust_anchor:load(),
            Snapshot = ias_demo_state:export(),
            ?assertEqual(nomatch, binary:match(Snapshot, ias_html:text(Path))),
            ?assertEqual(nomatch, binary:match(Snapshot, <<"ca.pem">>)),
            ?assertEqual(nomatch, binary:match(Snapshot, <<"BEGIN CERTIFICATE">>))
        end)
    end).

with_config(File, Base, Fun) ->
    PreviousFile = application:get_env(ias, ca_trust_anchor_file),
    PreviousBase = application:get_env(ias, ca_trust_anchor_base_dir),
    application:set_env(ias, ca_trust_anchor_file, File),
    application:set_env(ias, ca_trust_anchor_base_dir, Base),
    try Fun()
    after
        restore_env(ca_trust_anchor_file, PreviousFile),
        restore_env(ca_trust_anchor_base_dir, PreviousBase)
    end.

restore_env(Key, undefined) ->
    application:unset_env(ias, Key);
restore_env(Key, {ok, Value}) ->
    application:set_env(ias, Key, Value).

with_temp_dir(Fun) ->
    Dir = filename:join(["/tmp", "ias_configured_ca_" ++
                         integer_to_list(erlang:unique_integer([positive]))]),
    ok = file:make_dir(Dir),
    try Fun(Dir)
    after
        file:del_dir_r(Dir)
    end.

ca_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBojCCAUigAwIBAgIUAwOYI6HpKSa8g5wpOfhRv6uwqX4wCgYIKoZIzj0EAwIw\n"
      "FjEUMBIGA1UEAwwLSUFTIFRlc3QgQ0EwHhcNMjYwNjIxMTIxMzA0WhcNMzYwNjE4\n"
      "MTIxMzA0WjAWMRQwEgYDVQQDDAtJQVMgVGVzdCBDQTBZMBMGByqGSM49AgEGCCqG\n"
      "SM49AwEHA0IABJAU2K3M/RJxUbnRyRMn/q/pKUvxyeSNfEd3ObgqUTI6EuoV7zXi\n"
      "JwO7p523tuE4CYTi8cRXoASS+y/QyOJHCCWjdDByMB0GA1UdDgQWBBRBopAKdb8i\n"
      "UUq0Wq/3vCdgOotuHzAfBgNVHSMEGDAWgBRBopAKdb8iUUq0Wq/3vCdgOotuHzAP\n"
      "BgNVHRMBAf8EBTADAQH/MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEG\n"
      "MAoGCCqGSM49BAMCA0gAMEUCIQDhHUDdaai3Q1/XU503lYPjc7s5c9uKSapnHS8h\n"
      "/10rEAIgCOtblJiLMv40z/YBgZrBAli1wolz7X5FSYuG24LTCGk=\n"
      "-----END CERTIFICATE-----\n">>.

client_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBZDCCAQqgAwIBAgIUa1wxwBw2MaSaN2Zaqvu/4gWUgDMwCgYIKoZIzj0EAwIw\n"
      "FjEUMBIGA1UEAwwLSUFTIFRlc3QgQ0EwHhcNMjYwNjIxMTIxMzA0WhcNMzYwNjE4\n"
      "MTIxMzA0WjAaMRgwFgYDVQQDDA9JQVMgVGVzdCBDbGllbnQwWTATBgcqhkjOPQIB\n"
      "BggqhkjOPQMBBwNCAAT9brxfCaaU/6LLtCNKICvq1UwQDTH9hS9teBzUhEPuxGcA\n"
      "0wdjEO6F1kR64uUgAoUYOOlIqj31MWH5CcqBwuuxozIwMDAMBgNVHRMBAf8EAjAA\n"
      "MAsGA1UdDwQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAjAKBggqhkjOPQQDAgNI\n"
      "ADBFAiEA2ye4DSJJuQnZ43+peLW5YsQHGEdGx9r1zuCKHxNcY0kCICsBo8QieTgA\n"
      "Iq0sBJ/RxQ+E19tAL+EarYX6zvA00gz9\n"
      "-----END CERTIFICATE-----\n">>.
