-module(ias_index).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("IAS")},
        #p{body = ias_html:text("Identity, Access and Security Administration bootstrap.")},
        #panel{class = <<"empty-state">>, body = [
            #p{body = ias_html:text("Select an IAS area from the navigation.")}
        ]},
        #panel{class = <<"ias-status-card">>, body = [
            #h3{body = ias_html:text("Device-bound Provisioning")},
            #p{body = ias_html:text(
                "Create a new VPN configuration step by step with the provisioning wizard.")},
            #link{class = [button, sgreen],
                  url = <<"/app/provisioning-wizard.htm">>,
                  body = ias_html:text("Start Device-bound Provisioning")}
        ]}
    ]}.
