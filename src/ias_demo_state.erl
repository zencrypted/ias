-module(ias_demo_state).
-export([summary/0,
         clear/0,
         export/0,
         import/1]).

-define(FORMAT, ias_demo_state_v1).

summary() ->
    Objects = runtime_objects(),
    Relationships = [Object || Object <- Objects,
                              maps:get(kind, Object, undefined) =:= relationship],
    DomainObjects = [Object || Object <- Objects,
                              maps:get(kind, Object, undefined) =/= relationship],
    WizardDrafts = ias_provisioning_wizard_store:all(),
    #{objects => length(DomainObjects),
      relationships => length(Relationships),
      wizard_drafts => length(WizardDrafts),
      total_records => length(Objects)}.

clear() ->
    ok = ias_demo_store:clear(),
    ok = ias_provisioning_wizard_store:clear(),
    ias_certificate_material:clear().

export() ->
    Objects = runtime_objects(),
    Relationships = [Object || Object <- Objects,
                              maps:get(kind, Object, undefined) =:= relationship],
    DomainObjects = [Object || Object <- Objects,
                              maps:get(kind, Object, undefined) =/= relationship],
    Snapshot = #{
        format => ?FORMAT,
        exported_at => created_at(),
        objects => [sanitize_record(Object) || Object <- DomainObjects],
        relationships => [sanitize_record(Relationship) || Relationship <- Relationships],
        wizard_drafts => [sanitize_wizard_draft(Draft) || Draft <- ias_provisioning_wizard_store:all()]
    },
    iolist_to_binary(io_lib:format("~tp.~n", [Snapshot])).

import(TermText) ->
    case decode_snapshot(TermText) of
        {ok, Snapshot} ->
            restore_snapshot(Snapshot);
        {error, Reason} ->
            {error, Reason}
    end.

runtime_objects() ->
    ias_demo_store:runtime_objects().

decode_snapshot(TermText) ->
    try parse_snapshot(normalize_term_text(TermText)) of
        {ok, Snapshot} when is_map(Snapshot) ->
            validate_snapshot(Snapshot);
        {ok, _} ->
            {error, malformed_snapshot};
        {error, _} ->
            {error, malformed_snapshot}
    catch
        _:_ ->
            {error, malformed_snapshot}
    end.

normalize_term_text(Text) when is_binary(Text) ->
    binary_to_list(Text);
normalize_term_text(Text) when is_list(Text) ->
    Text;
normalize_term_text(Text) ->
    binary_to_list(ias_html:text(Text)).

parse_snapshot(Text) ->
    case erl_scan:string(Text) of
        {ok, Tokens, _EndLine} ->
            erl_parse:parse_term(Tokens);
        {error, _Info, _EndLine} = Error ->
            Error
    end.

validate_snapshot(#{format := ?FORMAT,
                    objects := Objects,
                    relationships := Relationships} = Snapshot)
  when is_list(Objects), is_list(Relationships) ->
    case maps:get(wizard_drafts, Snapshot, []) of
        WizardDrafts when is_list(WizardDrafts) -> {ok, Snapshot};
        _ -> {error, invalid_snapshot_format}
    end;
validate_snapshot(_) ->
    {error, invalid_snapshot_format}.

restore_snapshot(Snapshot) ->
    Objects = maps:get(objects, Snapshot, []),
    Relationships = maps:get(relationships, Snapshot, []),
    WizardDrafts = maps:get(wizard_drafts, Snapshot, []),
    ValidObjects = [Object || Object <- Objects, valid_object(Object)],
    ValidRelationships = [Relationship || Relationship <- Relationships,
                                          valid_relationship(Relationship)],
    ValidWizardDrafts = [Draft || Draft <- WizardDrafts, valid_wizard_draft(Draft)],
    Skipped = length(Objects) - length(ValidObjects) +
        length(Relationships) - length(ValidRelationships) +
        length(WizardDrafts) - length(ValidWizardDrafts),
    ias_demo_store:clear(),
    ias_provisioning_wizard_store:clear(),
    ias_certificate_material:clear(),
    [ias_demo_store:put_runtime_object(sanitize_record(Object)) || Object <- ValidObjects],
    UniqueRelationships = unique_relationships(ValidRelationships),
    [ias_demo_store:put_runtime_object(Relationship) || Relationship <- UniqueRelationships],
    ImportedWizardDrafts = restore_wizard_drafts(ValidWizardDrafts),
    #{imported_objects => length(ValidObjects),
      imported_relationships => length(UniqueRelationships),
      imported_wizard_drafts => ImportedWizardDrafts,
      skipped_invalid_records => Skipped + length(ValidRelationships) - length(UniqueRelationships) +
          length(ValidWizardDrafts) - ImportedWizardDrafts}.

valid_object(#{kind := Kind, id := Id}) when Kind =/= relationship ->
    is_supported_kind(Kind) andalso usable_id(Id);
valid_object(_) ->
    false.

valid_relationship(#{kind := relationship,
                     id := Id,
                     relation_type := RelationType,
                     source_kind := SourceKind,
                     source_id := SourceId,
                     target_kind := TargetKind,
                     target_id := TargetId}) ->
    usable_id(Id) andalso
        ias_relationship_graph:known_relationship_type(RelationType) andalso
        is_supported_kind(SourceKind) andalso
        is_supported_kind(TargetKind) andalso
        usable_id(SourceId) andalso
        usable_id(TargetId);
valid_relationship(_) ->
    false.

is_supported_kind(device) -> true;
is_supported_kind(certificate) -> true;
is_supported_kind(certificate_replacement) -> true;
is_supported_kind(certificate_revocation) -> true;
is_supported_kind(vpn_service) -> true;
is_supported_kind(verification) -> true;
is_supported_kind(security_policy) -> true;
is_supported_kind(relationship) -> true;
is_supported_kind(cmp_enrollment_result) -> true;
is_supported_kind(user) -> true;
is_supported_kind(security_profile) -> true;
is_supported_kind(ovpn_provisioning) -> true;
is_supported_kind(_) -> false.

usable_id(undefined) ->
    false;
usable_id(<<>>) ->
    false;
usable_id([]) ->
    false;
usable_id(_Id) ->
    true.

unique_relationships(Relationships) ->
    unique_relationships(Relationships, [], []).

unique_relationships([], _Seen, Acc) ->
    lists:reverse(Acc);
unique_relationships([Relationship | Rest], Seen, Acc) ->
    Key = relationship_key(Relationship),
    case lists:member(Key, Seen) of
        true -> unique_relationships(Rest, Seen, Acc);
        false -> unique_relationships(Rest, [Key | Seen], [Relationship | Acc])
    end.

relationship_key(Relationship) ->
    {maps:get(relation_type, Relationship, undefined),
     maps:get(source_kind, Relationship, undefined),
     maps:get(source_id, Relationship, undefined),
     maps:get(target_kind, Relationship, undefined),
     maps:get(target_id, Relationship, undefined)}.

valid_wizard_draft(#{id := Id, scenario := device_bound, current_step := Step}) ->
    usable_id(Id) andalso lists:member(Step, ias_provisioning_wizard_store:steps());
valid_wizard_draft(_) ->
    false.

restore_wizard_drafts(Drafts) ->
    lists:foldl(fun(Draft, Count) ->
        case ias_provisioning_wizard_store:restore(sanitize_wizard_draft(Draft)) of
            {ok, _} -> Count + 1;
            {error, _} -> Count
        end
    end, 0, Drafts).

sanitize_wizard_draft(Draft) ->
    maps:with([id, scenario, current_step, device_id, security_profile_id,
               vpn_service_id, ca_certificate_id, client_certificate_id,
               relationships_applied, provisioning_id, completed, completed_at,
               created_at, updated_at], Draft).

sanitize_record(Record) ->
    Sanitized = maps:without(secret_keys(), Record),
    Sanitized#{
        private_key_stored => false,
        certificate_body_stored => false,
        ca_body_stored => false
    }.

secret_keys() ->
    [private_key, private_key_body, private_key_pem, key_pem,
     certificate_body, certificate_pem, cert_pem,
     ca_body, ca_pem, ca_certificate_body, ca_certificate_pem,
     csr_body, csr_pem, tls_auth_body, tls_crypt_body, shared_secret].

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
