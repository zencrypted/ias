-module(ias_relationship_ui).
-export([object_entry/2, object_entry/3, object_ref/2, action/1, status_text/1, status_badge/1]).
-include_lib("nitro/include/nitro.hrl").

object_entry(source, Relationship) ->
    object_entry(maps:get(source_kind, Relationship, undefined),
                 maps:get(source_id, Relationship, undefined),
                 Relationship);
object_entry(target, Relationship) ->
    object_entry(maps:get(target_kind, Relationship, undefined),
                 maps:get(target_id, Relationship, undefined),
                 Relationship).

action(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            unlink_link(maps:get(id, Relationship, undefined));
        false ->
            status_badge(Relationship)
    end.

object_entry(Kind, Id, Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            #panel{body = [
                object_ref(Kind, Id),
                ias_html:text(" "),
                unlink_link(maps:get(id, Relationship, undefined))
            ]};
        false ->
            #panel{body = [
                object_ref(Kind, Id),
                ias_html:text(" "),
                status_badge(Relationship)
            ]}
    end.

status_text(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            <<>>;
        false ->
            ias_html:join([<<" [">>, protection_label(Relationship), <<"]">>])
    end.

status_badge(Relationship) ->
    #span{style = <<"color:#6b7280;font-size:12px;margin-left:6px;">>,
           body = status_badge_text(Relationship)}.

status_badge_text(Relationship) ->
    case ias_relationship_link:unlinkable(Relationship) of
        true ->
            ias_html:text("Editable");
        false ->
            ias_html:join([<<"Protected: ">>, protection_label(Relationship)])
    end.

protection_label(#{relation_type := issues}) ->
    <<"lifecycle">>;
protection_label(#{relation_type := issued_certificate}) ->
    <<"lifecycle">>;
protection_label(#{relation_type := verified_by}) ->
    <<"audit">>;
protection_label(_Relationship) ->
    <<"protected">>.

unlink_link(RelationshipId) ->
    #link{id = unlink_id(RelationshipId),
          class = [button, sgreen],
          style = <<"display:inline-block;">>,
          body = ias_html:text("Unlink"),
          postback = {unlink_relationship, RelationshipId}}.

unlink_id(RelationshipId) ->
    Unique = erlang:unique_integer([positive, monotonic]),
    ias_html:join([<<"unlink_">>, safe_id(RelationshipId), <<"_">>, integer_to_binary(Unique)]).

safe_id(RelationshipId) when is_binary(RelationshipId) ->
    RelationshipId;
safe_id(RelationshipId) ->
    ias_html:text(RelationshipId).

object_ref(_Kind, undefined) ->
    <<"not found">>;
object_ref(user, Id) ->
    TextId = ias_html:text(Id),
    case ias_demo_store:get(Id) of
        {ok, #{kind := user}} ->
            #link{url = ias_html:join([<<"/app/user.htm?id=">>, TextId]),
                  body = ias_html:join([object_label(user), <<" #">>, TextId])};
        _ ->
            <<"not found">>
    end;
object_ref(security_profile, Id) ->
    TextId = ias_html:text(Id),
    case ias_demo_store:get(Id) of
        {ok, #{kind := security_profile}} ->
            #link{url = ias_html:join([<<"/app/profile.htm?id=">>, TextId]),
                  body = ias_html:join([object_label(security_profile), <<" #">>, TextId])};
        _ ->
            <<"not found">>
    end;
object_ref(Kind, Id) ->
    TextId = ias_html:text(Id),
    case ias_demo_store:get(Id) of
        {ok, #{kind := Kind}} ->
            #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
                  body = ias_html:join([object_label(Kind), <<" #">>, TextId])};
        _ ->
            <<"not found">>
    end.

object_label(device) ->
    <<"Device">>;
object_label(user) ->
    <<"User">>;
object_label(certificate) ->
    <<"Certificate">>;
object_label(vpn_service) ->
    <<"VPN Service">>;
object_label(security_profile) ->
    <<"Security Profile">>;
object_label(security_policy) ->
    <<"Security Policy">>;
object_label(relationship) ->
    <<"Relationship">>;
object_label(verification) ->
    <<"Verification">>;
object_label(cmp_enrollment_result) ->
    <<"Certificate Enrollment">>;
object_label(Kind) ->
    ias_html:text(Kind).
