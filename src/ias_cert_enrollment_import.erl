-module(ias_cert_enrollment_import).
-export([import/1]).

import(EnrollmentId) ->
    case ias_demo_store:get_enrollment_result(EnrollmentId) of
        {ok, Enrollment} ->
            {ok, ias_demo_store:add_certificate(certificate_demo_object(Enrollment))};
        not_found ->
            not_found
    end.

certificate_demo_object(Enrollment) ->
    Subject = maps:get(subject, Enrollment, <<"not found">>),
    ImportId = demo_import_id(Subject),
    #{id => ias_html:join([ImportId, <<"_certificate">>]),
      source => cmp_demo_enrollment,
      import_id => ImportId,
      subject => Subject,
      issuer => maps:get(issuer, Enrollment, <<"not found">>),
      not_before => maps:get(not_before, Enrollment, <<"not found">>),
      not_after => maps:get(not_after, Enrollment, <<"not found">>),
      requested_cn => maps:get(requested_cn, Enrollment, <<"not found">>),
      enrollment_cn => maps:get(enrollment_cn, Enrollment, <<"not found">>),
      profile => maps:get(profile, Enrollment, <<"secp384r1">>),
      cmp_server => maps:get(cmp_server, Enrollment, <<"127.0.0.1:8829">>),
      private_key_stored => false,
      certificate_body_stored => false}.

demo_import_id(Subject) ->
    ias_html:join([<<"cmp_enrollment_">>,
                   ias_html:text(erlang:system_time(millisecond)), <<"_">>,
                   ias_html:text(erlang:unique_integer([positive])), <<"_">>,
                   file_stem(Subject)]).

file_stem(Value) ->
    file_stem(ias_html:text(Value), <<>>).

file_stem(<<>>, <<>>) ->
    <<"certificate">>;
file_stem(<<>>, Acc) ->
    Acc;
file_stem(<<Char/utf8, Rest/binary>>, Acc)
  when (Char >= $a andalso Char =< $z) orelse
       (Char >= $A andalso Char =< $Z) orelse
       (Char >= $0 andalso Char =< $9) orelse
       Char =:= $_ orelse
       Char =:= $- ->
    file_stem(Rest, <<Acc/binary, Char/utf8>>);
file_stem(<<_Char/utf8, Rest/binary>>, Acc) ->
    file_stem(Rest, <<Acc/binary, $_>>).
