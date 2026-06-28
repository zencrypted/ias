%%%-------------------------------------------------------------------
%% @doc Stage 7C recovery planner and atomic local commit.
%%
%% VPN remains read-only. The durable head digest is verified, existing IAS
%% records are reused only when the recovery descriptor is compatible, and the
%% graph, VPN authority and recovery ledger transition commit together.
%%%-------------------------------------------------------------------
-module(ias_vpn_orphan_recovery).

-export([plan/1,
         validate_plan/1,
         validate_current/2,
         commit/3]).

-define(SCHEMA_VERSION, 1).

plan(#{device_id := DeviceId0,
       status := orphan,
       recoverable := true,
       vpn := #{heads := HeadWrappers,
                registry := Registry,
                recovery_manifest := Manifest}} = Entry)
  when is_list(HeadWrappers), is_list(Registry), is_map(Manifest) ->
    DeviceId = normalize_id(DeviceId0),
    case ias_vpn_recovery_manifest:validate(Manifest) of
        ok ->
            case build_commands(HeadWrappers, []) of
                {ok, Commands} ->
                    case commands_match_manifest(DeviceId, Manifest, Commands) of
                        ok ->
                            case primary_command(Manifest, Commands) of
                                {ok, Command} ->
                                    Objects = maps:get(objects, Manifest, []),
                                    Relationships =
                                        [normalize_relationship(Relationship)
                                         || Relationship <-
                                                maps:get(relationships,
                                                         Manifest,
                                                         [])],
                                    case classify_records(Objects, Relationships) of
                                        {ok, Classification} ->
                                            Preview =
                                                ias_vpn_recovery_manifest:preview(
                                                  Manifest),
                                            Plan0 =
                                                #{schema_version => ?SCHEMA_VERSION,
                                                  device_id => DeviceId,
                                                  manifest => Manifest,
                                                  command => Command,
                                                  binding =>
                                                      recovery_binding(Manifest,
                                                                       Command),
                                                  objects => Objects,
                                                  relationships => Relationships,
                                                  create_objects =>
                                                      maps:get(create_objects,
                                                               Classification),
                                                  reuse_objects =>
                                                      maps:get(reuse_objects,
                                                               Classification),
                                                  create_relationships =>
                                                      maps:get(
                                                        create_relationships,
                                                        Classification),
                                                  reuse_relationships =>
                                                      maps:get(
                                                        reuse_relationships,
                                                        Classification),
                                                  recovery_mode =>
                                                      maps:get(mode,
                                                               Preview,
                                                               metadata_only),
                                                  vpn_identity =>
                                                      entry_identity(Entry)},
                                            Plan = Plan0#{plan_id => plan_id(Plan0)},
                                            case validate_plan(Plan) of
                                                ok -> {ok, Plan};
                                                {error, _} = Error -> Error
                                            end;
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, Reason} -> {error, {invalid_recovery_manifest, Reason}}
    end;
plan(#{status := orphan, recoverable := false, recovery := Recovery}) ->
    {error, {vpn_orphan_recovery_unavailable,
             maps:get(reason, Recovery, recovery_manifest_unavailable)}};
plan(_Entry) ->
    {error, invalid_vpn_orphan_recovery_snapshot}.

validate_plan(#{schema_version := ?SCHEMA_VERSION,
                plan_id := PlanId,
                device_id := DeviceId,
                manifest := Manifest,
                command := Command,
                binding := Binding,
                objects := Objects,
                relationships := Relationships,
                create_objects := CreateObjects,
                reuse_objects := ReuseObjects,
                create_relationships := CreateRelationships,
                reuse_relationships := ReuseRelationships,
                recovery_mode := Mode,
                vpn_identity := Identity} = Plan)
  when is_map(Manifest), is_map(Command), is_map(Binding),
       is_list(Objects), is_list(Relationships),
       is_list(CreateObjects), is_list(ReuseObjects),
       is_list(CreateRelationships), is_list(ReuseRelationships),
       is_map(Identity) ->
    PlanWithoutId = maps:remove(plan_id, Plan),
    Valid = is_binary(PlanId) andalso byte_size(PlanId) =:= 32
        andalso PlanId =:= plan_id(PlanWithoutId)
        andalso valid_id(DeviceId)
        andalso ias_vpn_recovery_manifest:validate(Manifest) =:= ok
        andalso normalize_id(maps:get(id, maps:get(device, Manifest))) =:= DeviceId
        andalso valid_recovered_command(DeviceId, Command)
        andalso recovered_command_matches_manifest(Manifest, Command)
        andalso Binding =:= recovery_binding(Manifest, Command)
        andalso Objects =:= maps:get(objects, Manifest, [])
        andalso Relationships =:= normalized_manifest_relationships(Manifest)
        andalso lists:member(Mode, [full, metadata_only])
        andalso lists:all(fun valid_object/1, Objects)
        andalso lists:all(fun valid_relationship/1, Relationships)
        andalso valid_classification(Objects,
                                     CreateObjects,
                                     ReuseObjects)
        andalso valid_classification(Relationships,
                                     CreateRelationships,
                                     ReuseRelationships)
        andalso valid_vpn_identity(Identity)
        andalso safe_term(Plan),
    case Valid of true -> ok; false -> {error, invalid_vpn_orphan_recovery_plan} end;
validate_plan(#{schema_version := Version}) ->
    {error, {unsupported_vpn_orphan_recovery_schema_version, Version}};
validate_plan(_) ->
    {error, invalid_vpn_orphan_recovery_plan}.

validate_current(Plan, Entry) ->
    case validate_plan(Plan) of
        ok ->
            case Entry of
                #{status := orphan, recoverable := true} ->
                    case maps:get(vpn_identity, Plan) =:= entry_identity(Entry) of
                        true -> ok;
                        false -> {error, orphan_snapshot_conflict}
                    end;
                #{status := Status} ->
                    {error, {vpn_orphan_recovery_blocked, Status}};
                _ -> {error, vpn_incident_snapshot_missing}
            end;
        {error, _} = Error -> Error
    end.

commit(DeviceId0, Token, Plan) ->
    DeviceId = normalize_id(DeviceId0),
    case validate_plan(Plan) of
        {error, _} = Error -> Error;
        ok ->
            case ensure_dependencies() of
                ok ->
                    case ias_kvs_transaction:run(
                           fun() -> commit_in_transaction(DeviceId, Token, Plan) end) of
                        {ok, #{records := Records} = Result} ->
                            case ias_demo_store:project_committed_records(
                                   Records,
                                   #{persist_device_authority => false}) of
                                {ok, _Projection} -> {ok, maps:remove(records, Result)};
                                {error, Reason} ->
                                    {error, {vpn_orphan_recovery_projection_failed,
                                             Reason}}
                            end;
                        {error, Reason} ->
                            {error, {vpn_orphan_recovery_commit_failed, Reason}}
                    end;
                {error, _} = Error -> Error
            end
    end.

commit_in_transaction(DeviceId, Token, Plan) ->
    case maps:get(device_id, Plan) =:= DeviceId of
        false -> ias_kvs_transaction:abort(recovery_device_mismatch);
        true ->
            Records = commit_domain_records(maps:get(objects, Plan),
                                            maps:get(relationships, Plan)),
            {Authority, AuthorityChange} =
                ias_vpn_authority:recover_in_transaction(
                  DeviceId,
                  maps:get(command, Plan),
                  maps:get(binding, Plan)),
            Summary = #{plan_id => maps:get(plan_id, Plan),
                        recovery_mode => maps:get(recovery_mode, Plan),
                        domain_record_count => length(Records),
                        authority_change => AuthorityChange,
                        revision => maps:get(revision, Authority)},
            Operation =
                ias_vpn_orphan_recovery_store:mark_graph_committed_in_transaction(
                  DeviceId, Token, Summary),
            #{records => Records,
              authority => Authority,
              operation => Operation,
              commit_summary => Summary}
    end.

ensure_dependencies() ->
    Steps = [fun ias_domain_store:ensure/0,
             fun ias_vpn_authority:ensure/0,
             fun ias_vpn_orphan_recovery_store:ensure/0],
    ensure_dependencies(Steps).

ensure_dependencies([]) -> ok;
ensure_dependencies([Fun | Rest]) ->
    case Fun() of
        ok -> ensure_dependencies(Rest);
        {error, _} = Error -> Error;
        Other -> {error, {unexpected_recovery_dependency_result, Other}}
    end.

commit_domain_records(Objects, Relationships) ->
    DomainObjects = [Object || Object <- Objects,
                               not catalog_kind(maps:get(kind, Object))],
    ObjectRecords = [ensure_domain_record(Object) || Object <- DomainObjects],
    RelationshipRecords = [ensure_domain_record(Relationship)
                           || Relationship <- Relationships],
    ObjectRecords ++ RelationshipRecords.

ensure_domain_record(#{kind := Kind, id := Id} = Expected) ->
    case ias_domain_store:get(Kind, Id) of
        not_found ->
            {Record, _Change} = ias_domain_store:put_in_transaction(Expected),
            Record;
        {ok, Record} ->
            Existing = maps:get(payload, Record),
            case compatible(Expected, Existing) of
                true -> Record;
                false ->
                    ias_kvs_transaction:abort(
                      {vpn_orphan_recovery_object_conflict, Kind, Id})
            end;
        {error, Reason} -> ias_kvs_transaction:abort(Reason)
    end.

classify_records(Objects, Relationships) ->
    case classify_objects(Objects, [], []) of
        {ok, CreateObjects, ReuseObjects} ->
            case classify_relationships(Relationships, [], []) of
                {ok, CreateRelationships, ReuseRelationships} ->
                    {ok, #{create_objects => lists:reverse(CreateObjects),
                           reuse_objects => lists:reverse(ReuseObjects),
                           create_relationships =>
                               lists:reverse(CreateRelationships),
                           reuse_relationships =>
                               lists:reverse(ReuseRelationships)}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

classify_objects([], Create, Reuse) -> {ok, Create, Reuse};
classify_objects([#{kind := Kind, id := Id} = Object | Rest], Create, Reuse) ->
    case lookup_existing(Kind, Id) of
        not_found ->
            case catalog_kind(Kind) of
                true ->
                    {error, {vpn_orphan_recovery_catalog_missing, Kind, Id}};
                false ->
                    classify_objects(Rest, [identity(Object) | Create], Reuse)
            end;
        {ok, Existing} ->
            case compatible(Object, Existing) of
                true -> classify_objects(Rest, Create, [identity(Object) | Reuse]);
                false -> {error, {vpn_orphan_recovery_object_conflict, Kind, Id}}
            end;
        {error, _} = Error -> Error
    end.

classify_relationships([], Create, Reuse) -> {ok, Create, Reuse};
classify_relationships([#{kind := relationship, id := Id} = Relationship | Rest],
                       Create, Reuse) ->
    case lookup_existing(relationship, Id) of
        not_found ->
            classify_relationships(Rest, [identity(Relationship) | Create], Reuse);
        {ok, Existing} ->
            case compatible(Relationship, Existing) of
                true -> classify_relationships(Rest, Create,
                                               [identity(Relationship) | Reuse]);
                false ->
                    {error, {vpn_orphan_recovery_object_conflict,
                             relationship, Id}}
            end;
        {error, _} = Error -> Error
    end.

lookup_existing(Kind, Id) when Kind =:= user;
                                Kind =:= security_profile;
                                Kind =:= security_policy ->
    case ias_demo_store:get(Id) of
        {ok, #{kind := Kind} = Object} -> {ok, Object};
        {ok, Other} -> {error, {vpn_orphan_recovery_identity_conflict,
                               Kind, Id, maps:get(kind, Other, undefined)}};
        not_found -> not_found
    end;
lookup_existing(Kind, Id) ->
    case ias_domain_store:get(Kind, Id) of
        {ok, Record} -> {ok, maps:get(payload, Record)};
        not_found -> not_found;
        {error, _} = Error -> Error
    end.

build_commands([], Acc) when Acc =/= [] -> {ok, lists:reverse(Acc)};
build_commands([], []) -> {error, recovery_head_missing};
build_commands([#{peer_id := PeerId, head := Head} | Rest], Acc)
  when is_map(Head) ->
    Command0 = #{peer_id => PeerId,
                 revision => maps:get(revision, Head, undefined),
                 operation => maps:get(operation, Head, undefined),
                 source => maps:get(source, Head, undefined),
                 desired_state => maps:get(desired_state, Head, #{})},
    Command = case maps:get(dynamic_device_id, Head, undefined) of
                  undefined -> Command0;
                  DynamicDeviceId ->
                      Command0#{dynamic_device_id => DynamicDeviceId}
              end,
    Digest = maps:get(digest, Head, undefined),
    Phase = maps:get(phase, Head, undefined),
    case {Phase, valid_head_command(Command, Digest)} of
        {applied, true} ->
            build_commands(Rest, [{PeerId, Command, Digest} | Acc]);
        {pending, true} ->
            {error, vpn_orphan_recovery_head_pending};
        {_OtherPhase, true} ->
            {error, invalid_recovery_head_phase};
        {_Phase, false} ->
            {error, recovery_command_digest_mismatch}
    end;
build_commands(_Heads, _Acc) -> {error, invalid_recovery_head_snapshot}.

commands_match_manifest(DeviceId, Manifest, Commands) ->
    Matches = lists:all(
                fun({_PeerId, Command, _Digest}) ->
                    Desired = maps:get(desired_state, Command, #{}),
                    normalize_id(maps:get(device_id, Desired, undefined)) =:=
                        DeviceId
                        andalso maps:get(recovery_manifest,
                                         Desired,
                                         undefined) =:= Manifest
                end,
                Commands),
    case Matches of
        true -> ok;
        false -> {error, recovery_head_manifest_mismatch}
    end.

primary_command(Manifest, Commands) ->
    Device = maps:get(device, Manifest),
    Preferred = maps:get(vpn_client_peer_id, Device, undefined),
    case Preferred of
        undefined ->
            case Commands of
                [{_PeerId, Command, _Digest} | _] -> {ok, Command};
                [] -> {error, recovery_head_missing}
            end;
        _ ->
            case [Command || {PeerId, Command, _Digest} <- Commands,
                             same_id(PeerId, Preferred)] of
                [Command | _] -> {ok, Command};
                [] -> {error, recovery_client_head_missing}
            end
    end.

valid_head_command(#{peer_id := PeerId,
                     revision := Revision,
                     operation := Operation,
                     source := Source,
                     desired_state := Desired} = Command,
                   Digest) ->
    valid_peer_id(PeerId)
        andalso is_integer(Revision) andalso Revision > 0
        andalso lists:member(Operation, [upsert, enable, disable, revoke, remove])
        andalso is_ias_source(Source)
        andalso is_map(Desired)
        andalso is_binary(Digest) andalso byte_size(Digest) =:= 32
        andalso Digest =:= vpn_digest(Command);
valid_head_command(_Command, _Digest) -> false.

valid_recovered_command(DeviceId, Command) ->
    Desired = maps:get(desired_state, Command, #{}),
    valid_head_command(Command, vpn_digest(Command))
        andalso normalize_id(maps:get(device_id, Desired, undefined)) =:= DeviceId.

recovered_command_matches_manifest(Manifest, Command) ->
    Desired = maps:get(desired_state, Command, #{}),
    Device = maps:get(device, Manifest, #{}),
    PreferredPeerId = maps:get(vpn_client_peer_id, Device, undefined),
    PeerMatches = case PreferredPeerId of
                      undefined -> true;
                      _ -> same_id(maps:get(peer_id, Command, undefined),
                                   PreferredPeerId)
                  end,
    maps:get(recovery_manifest, Desired, undefined) =:= Manifest
        andalso desired_certificate_matches_manifest(Desired, Manifest)
        andalso PeerMatches.

desired_certificate_matches_manifest(Desired, Manifest) ->
    Certificate = maps:get(certificate, Manifest, #{}),
    same_id(maps:get(certificate_fingerprint, Desired, undefined),
            maps:get(fingerprint_sha256, Certificate, undefined)).

normalized_manifest_relationships(Manifest) ->
    [normalize_relationship(Relationship)
     || Relationship <- maps:get(relationships, Manifest, [])].

valid_classification(Items, Create, Reuse) ->
    Expected = lists:sort([identity(Item) || Item <- Items]),
    Classified = Create ++ Reuse,
    Expected =:= lists:sort(Classified)
        andalso length(Classified) =:= length(lists:usort(Classified)).

valid_vpn_identity(#{heads := Heads, registry := Registry})
  when is_list(Heads), is_list(Registry) ->
    HeadIds = [maps:get(peer_id, Head, undefined) || Head <- Heads],
    RegistryIds = [maps:get(id, Item, undefined) || Item <- Registry],
    Heads =/= []
        andalso lists:all(fun valid_vpn_identity_head/1, Heads)
        andalso length(HeadIds) =:= length(lists:usort(HeadIds))
        andalso lists:all(fun valid_vpn_identity_registry/1, Registry)
        andalso length(RegistryIds) =:= length(lists:usort(RegistryIds));
valid_vpn_identity(_) -> false.

valid_vpn_identity_registry(#{id := PeerId,
                              provisioning_source := Source} = Item) ->
    valid_peer_id(PeerId) andalso is_ias_source(Source) andalso safe_term(Item);
valid_vpn_identity_registry(_Item) -> false.

valid_vpn_identity_head(#{peer_id := PeerId,
                          revision := Revision,
                          digest := Digest,
                          phase := Phase,
                          operation := Operation,
                          source := Source}) ->
    valid_peer_id(PeerId)
        andalso is_integer(Revision) andalso Revision > 0
        andalso is_binary(Digest) andalso byte_size(Digest) =:= 32
        andalso Phase =:= applied
        andalso lists:member(Operation, [upsert, enable, disable, revoke, remove])
        andalso is_ias_source(Source);
valid_vpn_identity_head(_) -> false.

entry_identity(Entry) ->
    Vpn = maps:get(vpn, Entry, #{}),
    Heads = [#{peer_id => maps:get(peer_id, Wrapper),
               revision => maps:get(revision, maps:get(head, Wrapper), undefined),
               digest => maps:get(digest, maps:get(head, Wrapper), undefined),
               phase => maps:get(phase, maps:get(head, Wrapper), applied),
               operation => maps:get(operation, maps:get(head, Wrapper), undefined),
               source => maps:get(source, maps:get(head, Wrapper), undefined),
               dynamic_device_id =>
                   maps:get(dynamic_device_id,
                            maps:get(head, Wrapper),
                            undefined)}
             || Wrapper <- maps:get(heads, Vpn, [])],
    Registry = [maps:with([id,
                           device_id,
                           provisioning_source,
                           allocation_id,
                           allocator_instance_id,
                           allocation_slot,
                           allocation_generation,
                           allocation_role,
                           revision,
                           enabled,
                           revoked],
                          Entry0)
                || Entry0 <- maps:get(registry, Vpn, [])],
    #{heads => lists:sort(Heads), registry => lists:sort(Registry)}.

recovery_binding(Manifest, Command) ->
    Device = maps:get(device, Manifest),
    ClientPeerId = maps:get(peer_id, Command),
    Base = maps:with([vpn_allocation_id,
                      vpn_allocator_instance_id,
                      vpn_client_peer_id,
                      vpn_gateway_peer_id,
                      vpn_allocation_slot,
                      vpn_allocation_generation],
                     Device),
    Base#{runtime_peer_id => ClientPeerId,
          vpn_peer => ClientPeerId,
          vpn_allocation_state => recovered,
          vpn_allocation_persistence => durable}.

normalize_relationship(Relationship) ->
    WithKind = Relationship#{kind => relationship},
    case maps:get(id, WithKind, undefined) of
        undefined -> WithKind#{id => recovered_relationship_id(WithKind)};
        <<>> -> WithKind#{id => recovered_relationship_id(WithKind)};
        _ -> WithKind
    end.

recovered_relationship_id(Relationship) ->
    Identity = maps:with([relation_type, source_kind, source_id,
                          target_kind, target_id], Relationship),
    Digest = crypto:hash(sha256, term_to_binary(Identity, [deterministic])),
    Hex = iolist_to_binary([io_lib:format("~2.16.0b", [Byte])
                            || <<Byte>> <= Digest]),
    <<"recovered_relationship_", Hex/binary>>.

compatible(Expected, Existing) when is_map(Expected), is_map(Existing) ->
    maps:with(maps:keys(Expected), Existing) =:= Expected;
compatible(_Expected, _Existing) -> false.

identity(Object) ->
    #{kind => maps:get(kind, Object), id => maps:get(id, Object)}.

valid_object(#{kind := Kind, id := Id} = Object) ->
    recoverable_kind(Kind) andalso valid_any_id(Id) andalso safe_term(Object);
valid_object(_) -> false.

valid_relationship(#{kind := relationship,
                     id := Id,
                     relation_type := RelationType,
                     source_kind := SourceKind,
                     source_id := SourceId,
                     target_kind := TargetKind,
                     target_id := TargetId} = Relationship) ->
    valid_any_id(Id) andalso RelationType =/= undefined
        andalso recoverable_kind(SourceKind)
        andalso recoverable_kind(TargetKind)
        andalso valid_any_id(SourceId) andalso valid_any_id(TargetId)
        andalso safe_term(Relationship);
valid_relationship(_) -> false.

catalog_kind(user) -> true;
catalog_kind(security_profile) -> true;
catalog_kind(security_policy) -> true;
catalog_kind(_) -> false.

recoverable_kind(device) -> true;
recoverable_kind(certificate) -> true;
recoverable_kind(vpn_service) -> true;
recoverable_kind(user) -> true;
recoverable_kind(security_profile) -> true;
recoverable_kind(security_policy) -> true;
recoverable_kind(relationship) -> true;
recoverable_kind(_) -> false.

vpn_digest(Command) ->
    ias_vpn_provisioning_command_digest:digest(Command).

plan_id(Plan) ->
    crypto:hash(sha256, term_to_binary(Plan, [deterministic])).

safe_term(Map) when is_map(Map) ->
    lists:all(fun({Key, Value}) -> not forbidden_key(Key) andalso safe_term(Value) end,
              maps:to_list(Map));
safe_term(List) when is_list(List) -> lists:all(fun safe_term/1, List);
safe_term(Tuple) when is_tuple(Tuple) -> safe_term(tuple_to_list(Tuple));
safe_term(Value) when is_pid(Value); is_port(Value); is_reference(Value);
                           is_function(Value) -> false;
safe_term(Binary) when is_binary(Binary) ->
    binary:match(Binary, <<"-----BEGIN ">>) =:= nomatch;
safe_term(_Value) -> true.

forbidden_key(Key) ->
    Text = string:lowercase(binary_to_list(normalize_id(Key))),
    lists:any(fun(Fragment) -> string:find(Text, Fragment) =/= nomatch end,
              ["private_key", "privatekey", "key_pem", "certificate_pem",
               "certificate_body", "csr_pem", "csr_body", "ovpn_body",
               "ovpn_profile", "password", "passphrase", "secret",
               "shared_secret", "session_key", "psk", "tls_auth",
               "tls_crypt"]).

is_ias_source(ias) -> true;
is_ias_source(<<"ias">>) -> true;
is_ias_source("ias") -> true;
is_ias_source(_) -> false.

valid_peer_id(Value) when is_atom(Value) -> Value =/= undefined;
valid_peer_id(Value) when is_binary(Value) -> byte_size(Value) > 0;
valid_peer_id(_) -> false.

valid_id(Value) when is_binary(Value) -> byte_size(Value) > 0;
valid_id(_) -> false.

valid_any_id(undefined) -> false;
valid_any_id(<<>>) -> false;
valid_any_id([]) -> false;
valid_any_id(_Value) -> true.

same_id(undefined, _B) -> false;
same_id(_A, undefined) -> false;
same_id(A, B) -> normalize_id(A) =:= normalize_id(B).

normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
normalize_id(Id) -> ias_html:text(Id).
