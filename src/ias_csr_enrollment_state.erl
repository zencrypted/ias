-module(ias_csr_enrollment_state).
-compile({no_auto_import, [get/1]}).
-export([ensure/0,
         get/1,
         submitted/1,
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

get(Fingerprint0) ->
    ensure(),
    Fingerprint = ias_html:text(Fingerprint0),
    case ets:lookup(?TABLE, Fingerprint) of
        [{Fingerprint, Record}] -> {ok, Record};
        [] -> not_found
    end.

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

mark_submitted(Fingerprint0, Metadata0) ->
    ensure(),
    Fingerprint = ias_html:text(Fingerprint0),
    Now = created_at(),
    Existing = case get(Fingerprint) of
        {ok, ExistingRecord} -> maps:without([status, retryable, updated_at], ExistingRecord);
        not_found -> #{created_at => Now}
    end,
    Metadata = safe_metadata(Metadata0),
    NewRecord = maps:merge(Existing, Metadata#{
        csr_fingerprint => Fingerprint,
        status => submitted,
        retryable => false,
        updated_at => Now
    }),
    true = ets:insert(?TABLE, {Fingerprint, NewRecord}),
    {ok, NewRecord}.

mark_issued(Fingerprint0, Metadata0) ->
    update(Fingerprint0, issued, false, Metadata0).

mark_failed(Fingerprint0, Reason, Retryable) ->
    update(Fingerprint0, failed, Retryable,
           #{failure_reason => ias_html:text(Reason)}).

clear() ->
    ensure(),
    ets:delete_all_objects(?TABLE),
    ok.

update(Fingerprint0, Status, Retryable, Metadata0) ->
    ensure(),
    Fingerprint = ias_html:text(Fingerprint0),
    Now = created_at(),
    Existing = case get(Fingerprint) of
        {ok, ExistingRecord} -> ExistingRecord;
        not_found -> #{csr_fingerprint => Fingerprint, created_at => Now}
    end,
    Metadata = safe_metadata(Metadata0),
    NewRecord = maps:merge(Existing, Metadata#{
        status => Status,
        retryable => Retryable,
        updated_at => Now
    }),
    true = ets:insert(?TABLE, {Fingerprint, NewRecord}),
    {ok, NewRecord}.

safe_metadata(Metadata) when is_map(Metadata) ->
    maps:without([csr_pem, csr_body, private_key, private_key_pem,
                  private_key_body, key_pem], Metadata);
safe_metadata(_Metadata) ->
    #{}.

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
