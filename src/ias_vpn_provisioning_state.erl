-module(ias_vpn_provisioning_state).
-export([ensure/0,
         reset/0,
         prepare/2,
         current_revision/1,
         last_command/1,
         status/0]).

-define(TABLE, ias_vpn_provisioning_state).
-define(OWNER, ias_vpn_provisioning_state_owner).

ensure() ->
    case ets:info(?TABLE) of
        undefined -> ensure_owner();
        _ -> ok
    end.

reset() ->
    ensure(),
    ets:delete_all_objects(?TABLE),
    ok.

prepare(DeviceId, Command0) when is_map(Command0) ->
    ensure(),
    Key = normalize_id(DeviceId),
    Fingerprint = command_fingerprint(Command0),
    case ets:lookup(?TABLE, Key) of
        [{Key, #{revision := _Revision, fingerprint := Fingerprint, command := Command}}] ->
            {ok, Command, unchanged};
        [{Key, #{revision := Revision}}] ->
            store(Key, Revision + 1, Fingerprint, Command0);
        [] ->
            store(Key, 1, Fingerprint, Command0)
    end.

current_revision(DeviceId) ->
    ensure(),
    Key = normalize_id(DeviceId),
    case ets:lookup(?TABLE, Key) of
        [{Key, #{revision := Revision}}] -> Revision;
        [] -> 0
    end.

last_command(DeviceId) ->
    ensure(),
    Key = normalize_id(DeviceId),
    case ets:lookup(?TABLE, Key) of
        [{Key, #{command := Command}}] -> {ok, Command};
        [] -> not_found
    end.

status() ->
    ensure(),
    Entries = [State || {_Key, State} <- ets:tab2list(?TABLE)],
    #{devices => length(Entries),
      revisions => maps:from_list([{maps:get(device_id, State), maps:get(revision, State)}
                                   || State <- Entries])}.

store(Key, Revision, Fingerprint, Command0) ->
    Command = Command0#{revision => Revision},
    State = #{device_id => Key,
              revision => Revision,
              fingerprint => Fingerprint,
              command => Command,
              updated_at => erlang:system_time(second)},
    true = ets:insert(?TABLE, {Key, State}),
    {ok, Command, changed}.

command_fingerprint(Command) ->
    crypto:hash(sha256, term_to_binary(maps:remove(revision, Command), [deterministic])).

ensure_owner() ->
    case whereis(?OWNER) of
        undefined ->
            Parent = self(),
            Pid = spawn(fun() -> owner(Parent) end),
            receive
                {Pid, ready} -> ok
            after 5000 ->
                exit({vpn_provisioning_state_start_timeout, Pid})
            end;
        _Pid ->
            wait_for_table(50)
    end.

owner(Parent) ->
    case catch register(?OWNER, self()) of
        true ->
            _ = ets:new(?TABLE, [named_table, public, set,
                                 {read_concurrency, true},
                                 {write_concurrency, true}]),
            Parent ! {self(), ready},
            owner_loop();
        _ ->
            Parent ! {self(), ready}
    end.

owner_loop() ->
    receive
        stop -> ok;
        _ -> owner_loop()
    end.

wait_for_table(0) -> ok;
wait_for_table(Attempts) ->
    case ets:info(?TABLE) of
        undefined -> timer:sleep(10), wait_for_table(Attempts - 1);
        _ -> ok
    end.

normalize_id(Id) ->
    ias_html:text(Id).
