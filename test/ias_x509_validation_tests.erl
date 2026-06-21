-module(ias_x509_validation_tests).
-include_lib("eunit/include/eunit.hrl").

valid_ca_certificate_test() ->
    strict(),
    ?assertMatch({ok, #{role := ca_certificate}},
                 ias_x509_validation:validate_certificate(ca_certificate, ca_pem())).

valid_client_certificate_test() ->
    strict(),
    ?assertMatch({ok, #{role := client_certificate}},
                 ias_x509_validation:validate_certificate(client_certificate, client_pem())).

client_certificate_is_rejected_as_ca_test() ->
    strict(),
    ?assertEqual({error, <<"CA certificate must have basicConstraints CA=TRUE">>},
                 ias_x509_validation:validate_certificate(ca_certificate, client_pem())).

ca_certificate_is_rejected_as_client_test() ->
    strict(),
    ?assertEqual({error, <<"client certificate must not have basicConstraints CA=TRUE">>},
                 ias_x509_validation:validate_certificate(client_certificate, ca_pem())).

expired_certificate_is_rejected_in_strict_mode_test() ->
    strict(),
    ?assertEqual({error, <<"certificate has expired">>},
                 ias_x509_validation:validate_certificate(client_certificate, expired_client_pem())).

expired_certificate_is_allowed_in_development_mode_test() ->
    development(),
    ?assertMatch({ok, #{validation_mode := development}},
                 ias_x509_validation:validate_certificate(client_certificate, expired_client_pem())),
    strict().

valid_chain_is_accepted_test() ->
    strict(),
    ?assertMatch({ok, #{mode := strict, development_bypass := false}},
                 ias_x509_validation:validate_pair(ca_pem(), client_pem())).

chain_mismatch_is_rejected_in_strict_mode_test() ->
    strict(),
    ?assertEqual({error, <<"client certificate does not verify against selected CA">>},
                 ias_x509_validation:validate_pair(other_ca_pem(), client_pem())).

chain_mismatch_is_allowed_in_development_mode_test() ->
    development(),
    ?assertMatch({ok, #{mode := development, development_bypass := true}},
                 ias_x509_validation:validate_pair(other_ca_pem(), client_pem())),
    strict().

identical_ca_and_client_certificates_are_rejected_in_development_mode_test() ->
    development(),
    ?assertEqual({error, <<"client certificate must not have basicConstraints CA=TRUE">>},
                 ias_x509_validation:validate_pair(ca_pem(), ca_pem())),
    strict().

private_key_pem_is_rejected_test() ->
    strict(),
    ?assertEqual({error, <<"private key material is not certificate material">>},
                 ias_x509_validation:validate_certificate(
                     client_certificate,
                     <<"-----BEGIN PRIVATE KEY-----\nforged\n-----END PRIVATE KEY-----\n">>)).

ovpn_protocol_injection_is_rejected_test() ->
    ?assertEqual({error, <<"OVPN protocol must be udp or tcp">>},
                 ias_x509_validation:validate_ovpn_inputs(
                     device(), service(#{protocol => <<"udp\nscript-security 2">>}),
                     <<"client.key">>)).

ovpn_endpoint_injection_is_rejected_test() ->
    ?assertEqual({error, <<"OVPN remote endpoint contains unsafe characters">>},
                 ias_x509_validation:validate_ovpn_inputs(
                     device(), service(#{remote_host => <<"vpn.example.com\nremote evil 1194">>}),
                     <<"client.key">>)).

ovpn_port_range_is_enforced_test() ->
    ?assertEqual({error, <<"OVPN remote port must be in 1..65535">>},
                 ias_x509_validation:validate_ovpn_inputs(
                     device(), service(#{remote_port => <<"70000">>}), <<"client.key">>)).

ovpn_tunnel_device_is_sanitized_test() ->
    ?assertEqual({error, <<"OVPN tunnel device contains unsafe characters">>},
                 ias_x509_validation:validate_ovpn_inputs(
                     device(#{tunnel_device => <<"tun\nup evil">>}), service(), <<"client.key">>)).

ovpn_key_reference_is_sanitized_test() ->
    ?assertEqual({error, <<"Device-owned private key reference is invalid.">>},
                 ias_x509_validation:validate_ovpn_inputs(
                     device(), service(), <<"../client.key">>)).

strict() ->
    application:set_env(ias, certificate_validation_mode, strict).

development() ->
    application:set_env(ias, certificate_validation_mode, development).

device() ->
    device(#{}).

device(Overrides) ->
    maps:merge(#{kind => device,
                 tunnel_device => <<"tun">>,
                 private_key_provider => <<"device_file">>,
                 private_key_ref => <<"client.key">>}, Overrides).

service() ->
    service(#{}).

service(Overrides) ->
    maps:merge(#{kind => vpn_service,
                 remote_host => <<"vpn.example.com">>,
                 remote_port => <<"1194">>,
                 protocol => <<"udp">>}, Overrides).

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

other_ca_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBpDCCAUqgAwIBAgIURWopEjxBWEnaN96gVY1c6eQ94BAwCgYIKoZIzj0EAwIw\n"
      "FzEVMBMGA1UEAwwMSUFTIE90aGVyIENBMB4XDTI2MDYyMTEyMTMwNFoXDTM2MDYx\n"
      "ODEyMTMwNFowFzEVMBMGA1UEAwwMSUFTIE90aGVyIENBMFkwEwYHKoZIzj0CAQYI\n"
      "KoZIzj0DAQcDQgAEhA1YGntgDsrg8mw+tDlKq4zR8au8OQp/XsnHYqjui77LYm9f\n"
      "VqFuHPlm/2ULsKt/fCs8eilHxnbLXbRb7BGW46N0MHIwHQYDVR0OBBYEFJcfJ21r\n"
      "TGXOFCwLwpLrzyKgvPaZMB8GA1UdIwQYMBaAFJcfJ21rTGXOFCwLwpLrzyKgvPaZ\n"
      "MA8GA1UdEwEB/wQFMAMBAf8wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC\n"
      "AQYwCgYIKoZIzj0EAwIDSAAwRQIgRT7I9+W19TBl086LDxktsIKM0EiScQ43UamZ\n"
      "AzHJ+PECIQCGJnudBPRT1ppYr6bzrKQnj1aiowupWBYVm/srkBqfug==\n"
      "-----END CERTIFICATE-----\n">>.

expired_client_pem() ->
    <<"-----BEGIN CERTIFICATE-----\n"
      "MIIBWjCCAQCgAwIBAgIUa1wxwBw2MaSaN2Zaqvu/4gWUgDQwCgYIKoZIzj0EAwIw\n"
      "FjEUMBIGA1UEAwwLSUFTIFRlc3QgQ0EwHhcNMjYwNjIxMTIxMzA0WhcNMjYwNjIx\n"
      "MTIxMzA0WjAdMRswGQYDVQQDDBJJQVMgRXhwaXJlZCBDbGllbnQwWTATBgcqhkjO\n"
      "PQIBBggqhkjOPQMBBwNCAASA/r2K6PhlJhArvMMcE6lG9evZ0Ozd9AR7mkiYqoDR\n"
      "d7x/s3IbjWCwxNK2gcw9hrpA/5QvgoYMz9unZ5c4MYYSoyUwIzAMBgNVHRMBAf8E\n"
      "AjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMCMAoGCCqGSM49BAMCA0gAMEUCIDd0EuN1\n"
      "CCpBR75iIwuuYVG0Z1DKve95CFH2FSwiebRNAiEAxqKTsoe6dMGMiSEYzW+Hgyof\n"
      "fJ+9sbzHGJbOLueidLU=\n"
      "-----END CERTIFICATE-----\n">>.
