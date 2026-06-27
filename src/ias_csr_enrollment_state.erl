-module(ias_csr_enrollment_state).
-compile({no_auto_import, [get/1]}).
-export([ensure/0,
         rehydrate/0,
         projection_count/0,
         get/1,
         all/0,
         submitted/1,
         public_key_available/2,
         mark_submitted/2,
         mark_issued/2,
         mark_failed/3,
         clear/0]).

-define(TABLE, ias_csr_enrollment_state).

ensure() ->
    case ets:whereis(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]),
            ok;
        _Tid ->
            ok
    end.

rehydrate() ->
    ensure(),
    case ias_csr_enrollment_store:all() of
        {ok, Records} ->
            true = ets:delete_all_objects(?TABLE),
            true = ets:insert(?TABLE,
                              [{maps:get(csr_fingerprint, Record), Record}
                               || Record <- Records]),
            {ok, length(Records)};
        {error, _} = Error ->
            Error
    end.

projection_count() ->
    ensure(),
    ets:info(?TABLE, size).

get(Fingerprint0) ->
    ensure(),
    Fingerprint = ias_html:text(Fingerprint0),
    case ets:lookup(?TABLE, Fingerprint) of
        [{Fingerprint, Record}] -> {ok, Record};
        [] -> not_found
    end.

all() ->
    ensure(),
    Records = [Record || {_Fingerprint, Record} <- ets:tab2list(?TABLE)],
    lists:sort(fun compare_records/2, Records).

submitted(Fingerprint0) ->
    Fingerprint = ias_html:text(Fingerprint0),
    case get(Fingerprint) of
        not_found ->
            ok;
        {ok, #{status := failed, retryable := true}} ->
            ok;
        {ok, Record} ->
            {error, {duplicate_csr, Record}}
    end.

public_key_available(DeviceId0, PublicKeyFingerprint0) ->
    DeviceId = ias_html:text(DeviceId0),
    PublicKeyFingerprint = ias_html:text(PublicKeyFingerprint0),
    case [Record || Record <- all(),
                    ias_html:text(maps:get(device_id, Record, undefined)) =:= DeviceId,
                    ias_html:text(maps:get(public_key_fingerprint, Record, undefined)) =:= PublicKeyFingerprint,
                    reusable_public_key_record(Record) =:= false] of
        [] -> ok;
        [Record | _] -> {error, {reused_public_key, Record}}
    end.

mark_submitted(Fingerprint0, Metadata0) ->
    Fingerprint = ias_html:text(Fingerprint0),
    Now = created_at(),
    case durable_existing(Fingerprint) of
        {ok, Existing0} ->
            Existing = maps:without([status, retryable, updated_at], Existing0),
            persist(maps:merge(Existing,
                               (metadata(Metadata0))#{
                                 csr_fingerprint => Fingerprint,
                                 status => submitted,
                                 retryable => false,
                                 updated_at => Now}));
        not_found ->
            persist((metadata(Metadata0))#{
                      csr_fingerprint => Fingerprint,
                      status => submitted,
                      retryable => false,
                      created_at => Now,
                      updated_at => Now});
        {error, _} = Error ->
            Error
    end.

mark_issued(Fingerprint0, Metadata0) ->
    update(Fingerprint0, issued, false, Metadata0).

mark_failed(Fingerprint0, Reason, Retryable) ->
    update(Fingerprint0, failed, Retryable,
           #{failure_reason => ias_html:text(Reason)}).

clear() ->
    ensure(),
    case ias_csr_enrollment_store:reset() of
        ok ->
            true = ets:delete_all_objects(?TABLE),
            ok;
        {error, _} = Error -> Error
    end.

update(Fingerprint0, Status, Retryable, Metadata0) ->
    Fingerprint = ias_html:text(Fingerprint0),
    Now = created_at(),
    case durable_existing(Fingerprint) of
        {ok, Existing} ->
            persist(maps:merge(Existing,
                               (metadata(Metadata0))#{
                                 csr_fingerprint => Fingerprint,
                                 status => Status,
                                 retryable => Retryable,
                                 updated_at => Now}));
        not_found ->
            persist((metadata(Metadata0))#{
                      csr_fingerprint => Fingerprint,
                      status => Status,
                      retryable => Retryable,
                      created_at => Now,
                      updated_at => Now});
        {error, _} = Error ->
            Error
    end.

persist(State) ->
    case ias_csr_enrollment_store:put(State) of
        {ok, Stored, _Change} ->
            ensure(),
            Fingerprint = maps:get(csr_fingerprint, Stored),
            true = ets:insert(?TABLE, {Fingerprint, Stored}),
            {ok, Stored};
        {error, _} = Error ->
            Error
    end.

durable_existing(Fingerprint) ->
    ias_csr_enrollment_store:get(Fingerprint).

metadata(Metadata) when is_map(Metadata) -> Metadata;
metadata(_Metadata) -> #{}.

reusable_public_key_record(#{status := failed, retryable := true}) -> true;
reusable_public_key_record(_) -> false.

compare_records(A, B) ->
    maps:get(csr_fingerprint, A, <<>>) =<
        maps:get(csr_fingerprint, B, <<>>).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
