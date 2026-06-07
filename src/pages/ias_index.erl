-module(ias_index).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    #panel{class = "ias-placeholder", body = [
        #h2{body = "IAS"},
        #p{body = "Identity, Access and Security Administration bootstrap."},
        #panel{class = "empty-state", body = "Select an IAS area from the navigation."}
    ]}.
