-module(ias_relationship_preview).
-export([preview/1]).

preview(#{kind := device} = Object) ->
    #{kind => device,
      related_certificate => not_linked,
      related_vpn_service => not_linked,
      suggested_certificates => candidate_certificates(Object),
      suggested_services => candidate_services(Object)};
preview(#{kind := certificate} = Object) ->
    #{kind => certificate,
      used_by_device => not_linked,
      suggested_devices => candidate_devices(Object)};
preview(#{kind := vpn_service} = Object) ->
    #{kind => vpn_service,
      used_by_device => not_linked,
      suggested_devices => candidate_devices(Object)};
preview(_Object) ->
    #{kind => unknown}.

candidate_certificates(Object) ->
    candidates(Object, ias_demo_store:certificates()).

candidate_services(Object) ->
    candidates(Object, ias_demo_store:services()).

candidate_devices(Object) ->
    candidates(Object, ias_demo_store:devices()).

candidates(Object, Objects) ->
    SameImport = same_import_candidates(Object, Objects),
    Available = [Candidate || Candidate <- Objects,
                              not same_id(Object, Candidate),
                              not lists:member(Candidate, SameImport)],
    SameImport ++ Available.

same_import_candidates(Object, Objects) ->
    ImportId = maps:get(import_id, Object, undefined),
    [Candidate || Candidate <- Objects,
                  not same_id(Object, Candidate),
                  ImportId =/= undefined,
                  maps:get(import_id, Candidate, undefined) =:= ImportId].

same_id(A, B) ->
    maps:get(id, A, undefined) =:= maps:get(id, B, undefined).
