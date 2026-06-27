-module(ias_certificate_material_protection_aes_gcm).

-export([ensure/0,
         protect/2,
         unprotect/2,
         mode/0]).

ensure() ->
    case encryption_key() of
        {ok, _Key} -> ok;
        {error, _} = Error -> Error
    end.

protect(StorageKey, Pem) when is_binary(Pem) ->
    case encryption_key() of
        {ok, Key} ->
            Nonce = crypto:strong_rand_bytes(12),
            Aad = term_to_binary(StorageKey),
            try crypto:crypto_one_time_aead(aes_256_gcm,
                                            Key,
                                            Nonce,
                                            Pem,
                                            Aad,
                                            16,
                                            true) of
                {Ciphertext, Tag} ->
                    {ok, #{algorithm => aes_256_gcm,
                           nonce => Nonce,
                           ciphertext => Ciphertext,
                           tag => Tag}}
            catch
                Class:Reason ->
                    {error, {certificate_material_encryption_failed,
                             {Class, Reason}}}
            end;
        {error, _} = Error -> Error
    end;
protect(_StorageKey, _Pem) ->
    {error, invalid_public_certificate_body}.

unprotect(StorageKey,
          #{algorithm := aes_256_gcm,
            nonce := Nonce,
            ciphertext := Ciphertext,
            tag := Tag})
  when is_binary(Nonce), is_binary(Ciphertext), is_binary(Tag) ->
    case encryption_key() of
        {ok, Key} ->
            Aad = term_to_binary(StorageKey),
            try crypto:crypto_one_time_aead(aes_256_gcm,
                                            Key,
                                            Nonce,
                                            Ciphertext,
                                            Aad,
                                            Tag,
                                            false) of
                Plaintext when is_binary(Plaintext) -> {ok, Plaintext};
                error -> {error, certificate_material_decryption_failed}
            catch
                _:_ -> {error, certificate_material_decryption_failed}
            end;
        {error, _} = Error -> Error
    end;
unprotect(_StorageKey, _Envelope) ->
    {error, invalid_certificate_material_envelope}.

mode() ->
    aes_256_gcm.

encryption_key() ->
    case application:get_env(ias, certificate_material_encryption_key) of
        {ok, Key} when is_binary(Key), byte_size(Key) =:= 32 ->
            {ok, Key};
        {ok, Encoded} ->
            decode_key(ias_html:text(Encoded));
        undefined ->
            {error, certificate_material_encryption_key_missing}
    end.

decode_key(Encoded) ->
    try base64:decode(Encoded) of
        Key when byte_size(Key) =:= 32 -> {ok, Key};
        _ -> {error, invalid_certificate_material_encryption_key}
    catch
        _:_ -> {error, invalid_certificate_material_encryption_key}
    end.
