%%%-------------------------------------------------------------------
%% @doc Read-only IAS-to-VPN durable state reconciliation.
%%
%% Stage 8B.2A intentionally reports drift without replaying commands or
%% mutating either authority. IAS durable authority is compared with the VPN
%% provisioning projection and safe peer registry snapshots. Automatic repair
%% belongs to a later stage.
%%%-------------------------------------------------------------------
-module(ias_vpn_reconciliation).

-export([device/1,
         report/0,
         status/0]).

-define(DEFAULT_TIMEOUT, 5000).

-spec device(term()) -> {ok, map()} | not_found | {error, term()}.
device(DeviceId0) ->
    DeviceId = normalize_id(DeviceId0),
    case ias_vpn_authority:get(DeviceId) of
        {ok, Authority} ->
            case vpn_snapshot() of
                {ok, Snapshot} ->
                    {ok, reconcile_authority(Authority, Snapshot)};
                {error, _} = Error ->
                    Error
            end;
        not_found ->
            not_found;
        {error, Reason} ->
            {error, {vpn_authority_read_failed, Reason}}
    end.

-spec report() -> {ok, map()} | {error, term()}.
report() ->
    case ias_vpn_authority:all() of
        {ok, Authorities} ->
            case vpn_snapshot() of
                {ok, Snapshot} ->
                    Entries0 = [reconcile_authority(Authority, Snapshot)
                                || Authority <- Authorities],
                    AuthorityIds = maps:from_list(
                                     [{maps:get(device_id, Authority), true}
                                      || Authority <- Authorities]),
                    Orphans = orphan_entries(AuthorityIds, Snapshot),
                    Entries = sort_entries(Entries0 ++ Orphans),
                    Counts = status_counts(Entries),
                    Drift = length([Entry || Entry <- Entries,
                                             maps:get(status, Entry) =/= synchronized]),
                    {ok,
                     #{state => case Drift of
                                   0 -> synchronized;
                                   _ -> drift_detected
                               end,
                       read_only => true,
                       automatic_action => none,
                       generated_at => erlang:system_time(second),
                       authority_records => length(Authorities),
                       orphan_records => length(Orphans),
                       drift_records => Drift,
                       counts => Counts,
                       entries => Entries}};
                {error, _} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, {vpn_authority_read_failed, Reason}}
    end.

status() ->
    report().

vpn_snapshot() ->
    case transport() of
        disabled ->
            {error, vpn_transport_disabled};
        erlang_rpc ->
            fetch_vpn_snapshot();
        Other ->
            {error, {unsupported_vpn_transport, Other}}
    end.

fetch_vpn_snapshot() ->
    case call_rpc(vpn_provisioning, recovery_heads, []) of
        {ok, Heads} when is_map(Heads) ->
            case valid_heads(Heads) of
                true -> fetch_registry_snapshot(Heads);
                false -> {error, invalid_vpn_provisioning_heads}
            end;
        {error, Reason} ->
            {error, {vpn_provisioning_snapshot_failed, sanitize_reason(Reason)}};
        {badrpc, Reason} ->
            {error, {vpn_snapshot_rpc_failed, sanitize_reason(Reason)}};
        Other ->
            {error, {unexpected_vpn_provisioning_snapshot,
                     sanitize_reason(Other)}}
    end.

fetch_registry_snapshot(Heads) ->
    case call_rpc(vpn_peer_registry, list, []) of
        Entries when is_list(Entries) ->
            case valid_registry_entries(Entries) of
                true ->
                    {ok, #{heads => Heads,
                           registry => registry_index(Entries)}};
                false ->
                    {error, invalid_vpn_peer_registry_snapshot}
            end;
        {badrpc, Reason} ->
            {error, {vpn_snapshot_rpc_failed, sanitize_reason(Reason)}};
        Other ->
            {error, {unexpected_vpn_peer_registry_snapshot,
                     sanitize_reason(Other)}}
    end.

reconcile_authority(Authority, Snapshot) ->
    DeviceId = maps:get(device_id, Authority),
    Command = maps:get(canonical_command, Authority, #{}),
    Revision = maps:get(revision, Authority, 0),
    PeerId = authority_peer_id(Authority),
    Heads = maps:get(heads, Snapshot),
    Registry = maps:get(registry, Snapshot),
    Head = lookup(PeerId, Heads),
    ExpectedRegistryIds = expected_registry_ids(Authority, PeerId),
    RegistryEntries = [maps:get(Id, Registry, undefined)
                       || Id <- ExpectedRegistryIds],
    ExpectedDigest = expected_vpn_digest(Command),
    {Status, Reason, DigestMatch} =
        classify(Authority,
                 PeerId,
                 Head,
                 RegistryEntries,
                 ExpectedDigest),
    #{device_id => DeviceId,
      status => Status,
      reason => Reason,
      read_only => true,
      automatic_action => none,
      replay_performed => false,
      ias => #{revision => Revision,
               lifecycle_state => maps:get(lifecycle_state,
                                           Authority,
                                           undefined),
               command_digest => maps:get(command_digest,
                                          Authority,
                                          undefined),
               expected_vpn_digest => ExpectedDigest,
               command => command_summary(Command),
               peer_id => PeerId,
               expected_registry_peer_ids => ExpectedRegistryIds,
               updated_at => maps:get(updated_at, Authority, undefined)},
      vpn => #{head => head_summary(Head),
               registry => compact_registry(RegistryEntries)},
      digest_match => DigestMatch}.

classify(Authority, _PeerId, _Head, _RegistryEntries, undefined) ->
    case maps:get(revision, Authority, 0) of
        0 -> {authority_only, no_canonical_command, undefined};
        _ -> {divergence, invalid_canonical_command, undefined}
    end;
classify(_Authority, undefined, _Head, _RegistryEntries, _ExpectedDigest) ->
    {divergence, authority_peer_id_missing, undefined};
classify(_Authority, _PeerId, undefined, _RegistryEntries, _ExpectedDigest) ->
    {missing_in_vpn, provisioning_head_missing, undefined};
classify(Authority, _PeerId, Head, RegistryEntries, ExpectedDigest) ->
    IasRevision = maps:get(revision, Authority),
    VpnRevision = maps:get(revision, Head, undefined),
    DigestMatch = maps:get(digest, Head, undefined) =:= ExpectedDigest,
    case valid_head_identity(Authority, Head) of
        false ->
            {divergence, vpn_device_identity_mismatch, DigestMatch};
        true when not is_integer(VpnRevision) ->
            {divergence, invalid_vpn_revision, DigestMatch};
        true when IasRevision > VpnRevision ->
            {vpn_behind, vpn_revision_behind, DigestMatch};
        true when IasRevision < VpnRevision ->
            {divergence, vpn_revision_ahead, DigestMatch};
        true ->
            classify_equal_revision(Authority,
                                    Head,
                                    RegistryEntries,
                                    DigestMatch)
    end.

classify_equal_revision(_Authority, #{phase := pending}, _RegistryEntries, true) ->
    {vpn_behind, vpn_command_pending, true};
classify_equal_revision(_Authority, _Head, _RegistryEntries, false) ->
    {divergence, command_digest_mismatch, false};
classify_equal_revision(Authority, _Head, RegistryEntries, true) ->
    case expected_registry_presence(Authority) of
        present ->
            case lists:any(fun(Entry) -> Entry =:= undefined end,
                           RegistryEntries) of
                true -> {missing_in_vpn, runtime_registry_missing, true};
                false -> {synchronized, in_sync, true}
            end;
        absent ->
            case lists:any(fun(Entry) -> Entry =/= undefined end,
                           RegistryEntries) of
                true -> {divergence, runtime_registry_should_be_absent, true};
                false -> {synchronized, in_sync, true}
            end
    end.

valid_head_identity(Authority, Head) ->
    DeviceId = maps:get(device_id, Authority),
    case head_device_id(Head) of
        undefined -> true;
        HeadDeviceId -> normalize_id(HeadDeviceId) =:= DeviceId
    end.

head_device_id(Head) ->
    Desired = maps:get(desired_state, Head, #{}),
    first_present([maps:get(dynamic_device_id, Head, undefined),
                   maps:get(device_id, Desired, undefined)]).

expected_registry_presence(Authority) ->
    Command = maps:get(canonical_command, Authority, #{}),
    Lifecycle = maps:get(lifecycle_state, Authority, undefined),
    case {maps:get(operation, Command, undefined), Lifecycle} of
        {remove, _} -> absent;
        {_, removed} -> absent;
        {_, decommissioned} -> absent;
        _ -> present
    end.

expected_registry_ids(Authority, PeerId) ->
    Binding = maps:get(binding, Authority, #{}),
    GatewayId = maps:get(vpn_gateway_peer_id, Binding, undefined),
    unique_present([PeerId, GatewayId]).

authority_peer_id(Authority) ->
    Command = maps:get(canonical_command, Authority, #{}),
    Binding = maps:get(binding, Authority, #{}),
    first_present([maps:get(peer_id, Command, undefined),
                   maps:get(vpn_client_peer_id, Binding, undefined),
                   maps:get(runtime_peer_id, Binding, undefined),
                   maps:get(vpn_peer, Binding, undefined)]).

expected_vpn_digest(Command) when is_map(Command), map_size(Command) > 0 ->
    crypto:hash(sha256,
                term_to_binary(maps:remove(dynamic_device_id, Command),
                               [deterministic]));
expected_vpn_digest(_Command) ->
    undefined.

orphan_entries(AuthorityIds, Snapshot) ->
    Candidates0 = orphan_heads(maps:get(heads, Snapshot), AuthorityIds, #{}),
    Candidates = orphan_registry(maps:get(registry, Snapshot),
                                 AuthorityIds,
                                 Candidates0),
    [orphan_entry(DeviceId, Candidate)
     || {DeviceId, Candidate} <- maps:to_list(Candidates)].

orphan_heads(Heads, AuthorityIds, Acc0) ->
    maps:fold(
      fun(PeerId, Head, Acc) ->
          case {ias_managed_head(Head), head_device_id(Head)} of
              {true, DeviceId0} when DeviceId0 =/= undefined ->
                  DeviceId = normalize_id(DeviceId0),
                  case maps:is_key(DeviceId, AuthorityIds) of
                      true -> Acc;
                      false -> add_orphan_head(DeviceId, PeerId, Head, Acc)
                  end;
              _ ->
                  Acc
          end
      end,
      Acc0,
      Heads).

orphan_registry(Registry, AuthorityIds, Acc0) ->
    maps:fold(
      fun(PeerId, Entry, Acc) ->
          case {ias_managed_registry(Entry),
                maps:get(device_id, Entry, undefined)} of
              {true, DeviceId0} when DeviceId0 =/= undefined ->
                  DeviceId = normalize_id(DeviceId0),
                  case maps:is_key(DeviceId, AuthorityIds) of
                      true -> Acc;
                      false -> add_orphan_registry(DeviceId, PeerId, Entry, Acc)
                  end;
              _ ->
                  Acc
          end
      end,
      Acc0,
      Registry).

add_orphan_head(DeviceId, PeerId, Head, Acc) ->
    Candidate0 = maps:get(DeviceId, Acc, #{heads => [], registry => []}),
    Candidate = Candidate0#{heads => [{PeerId, Head}
                                     | maps:get(heads, Candidate0)]},
    Acc#{DeviceId => Candidate}.

add_orphan_registry(DeviceId, PeerId, Entry, Acc) ->
    Candidate0 = maps:get(DeviceId, Acc, #{heads => [], registry => []}),
    Candidate = Candidate0#{registry => [{PeerId, Entry}
                                         | maps:get(registry, Candidate0)]},
    Acc#{DeviceId => Candidate}.

orphan_entry(DeviceId, Candidate) ->
    Heads = [#{peer_id => PeerId, head => head_summary(Head)}
             || {PeerId, Head} <- lists:reverse(maps:get(heads, Candidate))],
    Registry = [registry_summary(Entry)
                || {_PeerId, Entry} <- lists:reverse(
                                          maps:get(registry, Candidate))],
    #{device_id => DeviceId,
      status => orphan,
      reason => vpn_device_without_ias_authority,
      read_only => true,
      automatic_action => none,
      replay_performed => false,
      ias => undefined,
      vpn => #{heads => Heads, registry => Registry},
      digest_match => undefined}.

ias_managed_head(Head) ->
    is_ias_source(maps:get(source, Head, undefined)).

ias_managed_registry(Entry) ->
    is_ias_source(maps:get(provisioning_source, Entry, undefined)).

is_ias_source(ias) -> true;
is_ias_source(<<"ias">>) -> true;
is_ias_source("ias") -> true;
is_ias_source(_) -> false.

valid_heads(Heads) ->
    lists:all(
      fun({PeerId, Head}) ->
          valid_peer_id(PeerId) andalso is_map(Head) andalso
          is_integer(maps:get(revision, Head, -1)) andalso
          maps:get(revision, Head, -1) >= 0 andalso
          lists:member(maps:get(phase, Head, applied), [pending, applied]) andalso
          is_map(maps:get(desired_state, Head, #{})) andalso
          valid_optional_digest(maps:get(digest, Head, undefined))
      end,
      maps:to_list(Heads)).

valid_registry_entries(Entries) ->
    lists:all(
      fun(Entry) ->
          is_map(Entry) andalso valid_peer_id(maps:get(id, Entry, undefined))
      end,
      Entries).

valid_peer_id(Value) when is_atom(Value) -> Value =/= undefined;
valid_peer_id(Value) when is_binary(Value) -> byte_size(Value) > 0;
valid_peer_id(_) -> false.

valid_optional_digest(undefined) -> true;
valid_optional_digest(Digest) when is_binary(Digest) -> byte_size(Digest) =:= 32;
valid_optional_digest(_) -> false.

registry_index(Entries) ->
    maps:from_list([{maps:get(id, Entry), registry_summary(Entry)}
                    || Entry <- Entries]).

registry_summary(Entry) when is_map(Entry) ->
    maps:with([id,
               enabled,
               provisioning_source,
               device_id,
               allocation_id,
               allocator_instance_id,
               allocation_slot,
               allocation_generation,
               allocation_role,
               profile_id,
               authorization_mode,
               authorized,
               authorization_reason,
               certificate_fingerprint,
               revision,
               revoked,
               last_provisioning_operation,
               updated_at],
              Entry);
registry_summary(_Entry) ->
    undefined.

head_summary(undefined) ->
    undefined;
head_summary(Head) when is_map(Head) ->
    Desired = maps:get(desired_state, Head, #{}),
    Base = maps:with([revision,
                      digest,
                      phase,
                      operation,
                      source,
                      lifecycle_state,
                      dynamic_device_id,
                      updated_at,
                      durable],
                     Head),
    Base#{desired_state => maps:with([device_id,
                                      profile_id,
                                      authorization_mode,
                                      authorized,
                                      authorization_reason,
                                      certificate_fingerprint,
                                      enabled,
                                      revoked,
                                      allocation_id,
                                      allocator_instance_id,
                                      allocation_slot,
                                      allocation_generation,
                                      allocation_role,
                                      remote_peer_id],
                                     Desired)}.

command_summary(Command) when is_map(Command), map_size(Command) > 0 ->
    ias_vpn_provisioning_command:summary(Command);
command_summary(_Command) ->
    #{}.

compact_registry(Entries) ->
    [Entry || Entry <- Entries, Entry =/= undefined].

lookup(undefined, _Map) ->
    undefined;
lookup(Key, Map) ->
    maps:get(Key, Map, undefined).

status_counts(Entries) ->
    lists:foldl(
      fun(Entry, Acc) ->
          Status = maps:get(status, Entry),
          Acc#{Status => maps:get(Status, Acc, 0) + 1}
      end,
      #{synchronized => 0,
        vpn_behind => 0,
        divergence => 0,
        missing_in_vpn => 0,
        orphan => 0,
        authority_only => 0},
      Entries).

sort_entries(Entries) ->
    lists:sort(
      fun(A, B) ->
          maps:get(device_id, A) =< maps:get(device_id, B)
      end,
      Entries).

call_rpc(Module, Function, Args) ->
    case rpc_fun() of
        Fun when is_function(Fun, 5) ->
            Fun(vpn_node(), Module, Function, Args, rpc_timeout());
        undefined ->
            rpc:call(vpn_node(), Module, Function, Args, rpc_timeout())
    end.

transport() ->
    case application:get_env(ias, vpn_provisioning_transport, disabled) of
        disabled -> disabled;
        erlang_rpc -> erlang_rpc;
        <<"disabled">> -> disabled;
        <<"erlang_rpc">> -> erlang_rpc;
        Value -> Value
    end.

vpn_node() ->
    application:get_env(ias, vpn_provisioning_vpn_node, 'vpn@127.0.0.1').

rpc_timeout() ->
    application:get_env(ias, vpn_provisioning_rpc_timeout, ?DEFAULT_TIMEOUT).

rpc_fun() ->
    case application:get_env(ias, vpn_provisioning_rpc_fun) of
        {ok, Fun} when is_function(Fun, 5) -> Fun;
        _ -> undefined
    end.

sanitize_reason(Value) when is_atom(Value); is_binary(Value); is_integer(Value);
                            is_boolean(Value) ->
    Value;
sanitize_reason(Value) when is_tuple(Value) ->
    list_to_tuple([sanitize_reason(Item) || Item <- tuple_to_list(Value)]);
sanitize_reason(Value) when is_list(Value) ->
    [sanitize_reason(Item) || Item <- Value];
sanitize_reason(_Value) ->
    unsupported_detail.

unique_present(Values) ->
    lists:usort([Value || Value <- Values, present(Value)]).

present(undefined) -> false;
present(<<>>) -> false;
present([]) -> false;
present(_Value) -> true.

first_present([Value | Rest]) ->
    case present(Value) of
        true -> Value;
        false -> first_present(Rest)
    end;
first_present([]) ->
    undefined.

normalize_id(Id) when is_binary(Id) -> Id;
normalize_id(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
normalize_id(Id) -> ias_html:text(Id).
