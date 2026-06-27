-module(ias_certificate_material_protection_public).

-export([ensure/0,
         protect/2,
         unprotect/2,
         mode/0]).

ensure() ->
    ok.

protect(_StorageKey, Pem) when is_binary(Pem) ->
    {ok, #{algorithm => public_integrity_sha256,
           body => Pem,
           digest_sha256 => crypto:hash(sha256, Pem)}};
protect(_StorageKey, _Pem) ->
    {error, invalid_public_certificate_body}.

unprotect(_StorageKey,
          #{algorithm := public_integrity_sha256,
            body := Pem,
            digest_sha256 := Digest})
  when is_binary(Pem), is_binary(Digest) ->
    case crypto:hash(sha256, Pem) =:= Digest of
        true -> {ok, Pem};
        false -> {error, certificate_material_integrity_mismatch}
    end;
unprotect(_StorageKey, _Envelope) ->
    {error, invalid_certificate_material_envelope}.

mode() ->
    public_integrity_sha256.
