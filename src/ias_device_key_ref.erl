-module(ias_device_key_ref).
-export([defaults/0,
         validate/1,
         validate/2,
         status/1,
         update/2]).

defaults() ->
    #{private_key_provider => <<"device_file">>,
      private_key_ref => <<"client.key">>}.

validate(Fields) when is_map(Fields) ->
    validate(maps:get(private_key_provider, Fields, <<"device_file">>),
             maps:get(private_key_ref, Fields, <<>>)).

validate(Provider0, Ref0) ->
    Provider = trim(Provider0),
    Ref = trim(Ref0),
    case validate_provider(Provider) of
        ok ->
            case validate_ref(Ref) of
                ok -> {ok, #{private_key_provider => Provider,
                             private_key_ref => Ref}};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

status(DeviceId) when is_binary(DeviceId); is_list(DeviceId); is_atom(DeviceId) ->
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} -> status(Device);
        _ -> {error, device_not_found}
    end;
status(#{kind := device} = Device) ->
    case {maps:get(private_key_provider, Device, undefined),
          maps:get(private_key_ref, Device, undefined)} of
        {undefined, _} -> {error, missing_private_key_ref};
        {_, undefined} -> {error, missing_private_key_ref};
        {Provider, Ref} ->
            case validate(Provider, Ref) of
                {ok, Safe} -> {ok, Safe};
                {error, Reason} -> {error, Reason}
            end
    end;
status(_Device) ->
    {error, device_not_found}.

update(DeviceId, Fields) when is_map(Fields) ->
    case ias_demo_store:get(DeviceId) of
        {ok, #{kind := device} = Device} ->
            case validate(Fields) of
                {ok, Safe} ->
                    {ok, ias_demo_store:put_runtime_object(Device#{
                        private_key_provider => maps:get(private_key_provider, Safe),
                        private_key_ref => maps:get(private_key_ref, Safe),
                        updated_at => created_at()
                    })};
                {error, Reason} ->
                    {error, Reason}
            end;
        _ ->
            {error, device_not_found}
    end.

validate_provider(<<"device_file">>) ->
    ok;
validate_provider(<<>>) ->
    {error, <<"Private Key Provider is required">>};
validate_provider(_Provider) ->
    {error, <<"Private Key Provider must be device_file">>}.

validate_ref(<<>>) ->
    {error, <<"Private Key Reference is required">>};
validate_ref(Ref) when byte_size(Ref) > 180 ->
    {error, <<"Private Key Reference is too long">>};
validate_ref(Ref) ->
    Checks = [
        {fun absolute_path/1, <<"Private Key Reference must be relative">>},
        {fun windows_drive_path/1, <<"Private Key Reference must be relative">>},
        {fun has_backslash/1, <<"Private Key Reference must use forward slashes">>},
        {fun has_parent_traversal/1, <<"Private Key Reference must not contain ..">>},
        {fun has_control_char/1, <<"Private Key Reference must not contain control characters">>},
        {fun has_quote/1, <<"Private Key Reference must not contain quotes">>},
        {fun has_empty_segment/1, <<"Private Key Reference must not contain empty path segments">>},
        {fun trailing_slash/1, <<"Private Key Reference must point to a file">>}
    ],
    validate_ref_checks(Checks, Ref).

validate_ref_checks([], _Ref) ->
    ok;
validate_ref_checks([{Check, Reason} | Rest], Ref) ->
    case Check(Ref) of
        true -> {error, Reason};
        false -> validate_ref_checks(Rest, Ref)
    end.

absolute_path(<<"/", _/binary>>) -> true;
absolute_path(_) -> false.

windows_drive_path(<<Drive, $:, _/binary>>)
  when (Drive >= $a andalso Drive =< $z) orelse
       (Drive >= $A andalso Drive =< $Z) ->
    true;
windows_drive_path(_) ->
    false.

has_backslash(Ref) ->
    binary:match(Ref, <<"\\">>) =/= nomatch.

has_parent_traversal(Ref) ->
    binary:match(Ref, <<"..">>) =/= nomatch.

has_control_char(Ref) ->
    lists:any(fun(Char) -> Char < 32 orelse Char =:= 127 end,
              binary_to_list(Ref)).

has_quote(Ref) ->
    binary:match(Ref, <<"\"">>) =/= nomatch orelse
        binary:match(Ref, <<"'">>) =/= nomatch.

has_empty_segment(Ref) ->
    binary:match(Ref, <<"//">>) =/= nomatch.

trailing_slash(Ref) ->
    case Ref of
        <<_/binary>> ->
            binary:last(Ref) =:= $/;
        _ ->
            false
    end.

trim(Value) ->
    Text = ias_html:text(Value),
    re:replace(Text, <<"^\\s+|\\s+$">>, <<>>, [global, {return, binary}]).

created_at() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                     [{unit, second}])).
