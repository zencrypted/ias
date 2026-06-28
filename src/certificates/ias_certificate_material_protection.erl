-module(ias_certificate_material_protection).

-export([ensure/0,
         protect/2,
         unprotect/2,
         mode/0]).

ensure() ->
    call(ensure, []).

protect(StorageKey, Pem) ->
    call(protect, [StorageKey, Pem]).

unprotect(StorageKey, Envelope) ->
    call_provider(envelope_provider(Envelope),
                  unprotect,
                  [StorageKey, Envelope]).

mode() ->
    case call(mode, []) of
        {error, _} -> unavailable;
        Value -> Value
    end.

call(Function, Args) ->
    call_provider(provider(), Function, Args).

call_provider(Provider, Function, Args) ->
    try apply(Provider, Function, Args) of
        Value -> Value
    catch
        Class:Reason:Stacktrace ->
            {error,
             {certificate_material_protection_failed,
              Provider,
              Function,
              {Class, Reason, Stacktrace}}}
    end.

provider() ->
    application:get_env(
      ias,
      certificate_material_protection_provider,
      ias_certificate_material_protection_public).

envelope_provider(#{algorithm := public_integrity_sha256}) ->
    ias_certificate_material_protection_public;
envelope_provider(#{algorithm := aes_256_gcm}) ->
    ias_certificate_material_protection_aes_gcm;
envelope_provider(_Envelope) ->
    provider().
