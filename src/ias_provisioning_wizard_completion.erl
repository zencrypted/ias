-module(ias_provisioning_wizard_completion).

-export([commit/3]).

-include("ias_provisioning_wizard_draft.hrl").

commit(ExpectedDraft, CompletedDraft, Transaction)
  when is_map(ExpectedDraft), is_map(CompletedDraft), is_map(Transaction) ->
    case validate_completion(ExpectedDraft, CompletedDraft, Transaction) of
        ok ->
            case ensure_stores() of
                ok -> commit_transaction(ExpectedDraft, CompletedDraft, Transaction);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end;
commit(_ExpectedDraft, _CompletedDraft, _Transaction) ->
    {error, invalid_wizard_completion}.

ensure_stores() ->
    case ias_domain_store:ensure() of
        ok ->
            case ias_provisioning_wizard_draft_store:ensure() of
                ok ->
                    ias_demo_store:ensure();
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

commit_transaction(ExpectedDraft, CompletedDraft, Transaction) ->
    Fun = fun() ->
        {DomainRecord, DomainChange} =
            ias_domain_store:put_in_transaction(Transaction),
        {DraftRecord, DraftChange} =
            ias_provisioning_wizard_draft_store:replace_in_transaction(
              ExpectedDraft, CompletedDraft),
        {DomainRecord, DomainChange, DraftRecord, DraftChange}
    end,
    case mnesia:sync_transaction(Fun) of
        {atomic, {DomainRecord, DomainChange, DraftRecord, DraftChange}} ->
            project_after_commit(DomainRecord,
                                 DomainChange,
                                 DraftRecord,
                                 DraftChange);
        {aborted, Reason} ->
            {error, normalize_abort(Reason)}
    end.

project_after_commit(DomainRecord, DomainChange, DraftRecord, DraftChange) ->
    Draft = DraftRecord#ias_provisioning_wizard_draft.payload,
    Transaction = maps:get(payload, DomainRecord),
    case ias_demo_store:project_committed_records([DomainRecord]) of
        {ok, _Graph} ->
            case ias_provisioning_wizard_store:project_committed_draft(Draft) of
                {ok, StoredDraft} ->
                    {ok, StoredDraft, Transaction,
                     #{domain => DomainChange, draft => DraftChange}};
                {error, _} = Error ->
                    recover_projection(Draft, Transaction, Error)
            end;
        {error, _} = Error ->
            recover_projection(Draft, Transaction, Error)
    end.

recover_projection(Draft, Transaction, ProjectionError) ->
    DomainRecovery = ias_demo_store:rehydrate(),
    DraftRecovery = ias_provisioning_wizard_store:rehydrate(),
    case {DomainRecovery, DraftRecovery} of
        {{ok, _}, {ok, _}} ->
            {ok, Draft, Transaction,
             #{domain => recovered, draft => recovered}};
        _ ->
            {error,
             {wizard_completion_committed_projection_failed,
              ProjectionError,
              #{domain_recovery => DomainRecovery,
                draft_recovery => DraftRecovery}}}
    end.

validate_completion(ExpectedDraft, CompletedDraft, Transaction) ->
    ExpectedId = normalize_id(maps:get(id, ExpectedDraft, undefined)),
    CompletedId = normalize_id(maps:get(id, CompletedDraft, undefined)),
    TransactionId = normalize_id(maps:get(id, Transaction, undefined)),
    Checks = [ExpectedId =/= <<>>,
              ExpectedId =:= CompletedId,
              maps:get(kind, Transaction, undefined) =:= ovpn_provisioning,
              TransactionId =/= <<>>,
              normalize_id(maps:get(provisioning_id,
                                    CompletedDraft,
                                    undefined)) =:= TransactionId,
              maps:get(completed, CompletedDraft, false) =:= true,
              maps:get(current_step, CompletedDraft, undefined) =:= provisioning,
              completion_references_match(ExpectedDraft, Transaction)],
    case lists:all(fun(Check) -> Check =:= true end, Checks) of
        true -> ok;
        false -> {error, invalid_wizard_completion}
    end.

completion_references_match(Draft, Transaction) ->
    same_reference(maps:get(device_id, Draft, undefined),
                   maps:get(device_id, Transaction, undefined)) andalso
    same_reference(maps:get(vpn_service_id, Draft, undefined),
                   maps:get(vpn_service_id, Transaction, undefined)) andalso
    same_reference(maps:get(ca_certificate_id, Draft, undefined),
                   maps:get(ca_certificate_id, Transaction, undefined)) andalso
    same_reference(maps:get(client_certificate_id, Draft, undefined),
                   maps:get(certificate_id, Transaction, undefined)).

same_reference(Left, Right) ->
    normalize_id(Left) =:= normalize_id(Right).

normalize_abort({aborted, Reason}) -> Reason;
normalize_abort(Reason) -> Reason.

normalize_id(undefined) -> <<>>;
normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
normalize_id(Id) -> ias_html:text(Id).
