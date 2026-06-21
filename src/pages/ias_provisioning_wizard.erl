-module(ias_provisioning_wizard).
-export([event/1, content/0, content_for/1]).
-include_lib("n2o/include/n2o.hrl").
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(select_device_bound) ->
    {ok, Draft} = ias_provisioning_wizard_store:new(device_bound),
    nitro:redirect(wizard_url(maps:get(id, Draft)));
event({wizard_next, WizardId}) ->
    redirect_after(ias_provisioning_wizard_store:next(WizardId));
event({wizard_back, WizardId}) ->
    redirect_after(ias_provisioning_wizard_store:back(WizardId));
event({wizard_cancel, WizardId}) ->
    ok = ias_provisioning_wizard_store:delete(WizardId),
    nitro:redirect(start_url());
event(_) ->
    ok.

content() ->
    case query_id() of
        undefined ->
            content_for(start);
        WizardId ->
            case ias_provisioning_wizard_store:get(WizardId) of
                {ok, Draft} -> content_for({draft, Draft});
                not_found -> content_for({error, WizardId})
            end
    end.

content_for(start) ->
    page([
        #h2{body = ias_html:text("Device-bound Provisioning Wizard")},
        #p{body = ias_html:text("Live runtime orchestration skeleton for future device-bound VPN provisioning. Stage 24A creates only a volatile wizard draft.")},
        scheme_panel(undefined)
    ]);
content_for({draft, Draft}) ->
    CurrentStep = maps:get(current_step, Draft, scheme),
    page([
        #h2{body = ias_html:text("Device-bound Provisioning Wizard")},
        #p{body = ias_html:text("Wizard draft is stored in runtime ETS only. No Device, Certificate, VPN Service, relationship or provisioning object is created by this skeleton.")},
        draft_summary(Draft),
        progress_panel(CurrentStep),
        step_panel(Draft)
    ]);
content_for({error, WizardId}) ->
    page([
        #h2{body = ias_html:text("Device-bound Provisioning Wizard")},
        #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;color:#991b1b;">>,
               body = [
                   #h3{body = ias_html:text("Wizard draft not found")},
                   #p{body = ias_html:join([<<"No runtime wizard draft exists for id ">>,
                                             ias_html:text(WizardId), <<".">>])},
                   #link{url = start_url(),
                         class = [button, sgreen],
                         body = ias_html:text("Start Wizard")}
               ]}
    ]).

page(Body) ->
    #panel{class = <<"ias-placeholder">>, body = Body}.

scheme_panel(_Draft) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Choose Provisioning Scheme")},
        scheme_option("Device-bound VPN Profile",
                      "Create a runtime draft for a device-owned VPN profile provisioning flow.",
                      #link{class = [button, sgreen],
                            body = ias_html:text("Choose"),
                            postback = select_device_bound}),
        scheme_option("Import Existing OVPN",
                      "Use the existing onboarding flow for analyzing and importing an existing .ovpn profile.",
                      #link{url = ias_provisioning_wizard_store:ovpn_import_url(),
                            class = [button, sgreen],
                            body = ias_html:text("Open OVPN Import")}),
        scheme_option("Portable VPN Profile",
                      ias_provisioning_wizard_store:portable_reason(),
                      #span{style = disabled_action_style(),
                            body = ias_html:text("Disabled")})
    ]}.

scheme_option(Title, Description, Action) ->
    #panel{style = <<"margin:10px 0;padding:12px;border:1px solid rgba(15,23,42,0.12);border-radius:6px;background:#fff;display:flex;gap:12px;align-items:flex-start;justify-content:space-between;flex-wrap:wrap;">>,
           body = [
               #panel{style = <<"flex:1 1 260px;">>, body = [
                   #h3{style = <<"margin:0 0 4px;font-size:15px;">>,
                       body = ias_html:text(Title)},
                   #p{style = <<"margin:0;font-size:12px;color:#64748b;">>,
                      body = ias_html:text(Description)}
               ]},
               #panel{style = <<"flex:0 0 auto;">>, body = [Action]}
           ]}.

draft_summary(Draft) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Runtime Draft")},
        key_value_table([
            {"Wizard ID", maps:get(id, Draft, undefined)},
            {"Scenario", maps:get(scenario, Draft, undefined)},
            {"Current Step", maps:get(current_step, Draft, undefined)},
            {"Created At", maps:get(created_at, Draft, undefined)},
            {"Updated At", maps:get(updated_at, Draft, undefined)}
        ])
    ]}.

progress_panel(CurrentStep) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Progress")},
        #panel{style = <<"display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:8px;">>,
               body = [progress_item(Index, Step, CurrentStep)
                       || {Index, Step} <- enumerate(ias_provisioning_wizard_store:steps())]}
    ]}.

progress_item(Index, Step, CurrentStep) ->
    State = step_state(Step, CurrentStep),
    #panel{style = progress_style(State), body = [
        #span{style = <<"font-weight:700;margin-right:6px;">>,
              body = ias_html:text(Index)},
        #span{style = <<"font-weight:600;">>,
              body = ias_provisioning_wizard_store:step_title(Step)},
        #span{style = <<"display:block;font-size:11px;color:#64748b;margin-top:2px;">>,
              body = ias_html:text(State)}
    ]}.

step_panel(Draft) ->
    CurrentStep = maps:get(current_step, Draft, scheme),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = step_heading(CurrentStep)},
        #p{body = ias_provisioning_wizard_store:step_description(CurrentStep)},
        placeholder(CurrentStep),
        controls(Draft)
    ]}.

step_heading(scheme) ->
    ias_html:text("Choose Provisioning Scheme");
step_heading(Step) ->
    ias_provisioning_wizard_store:step_title(Step).

placeholder(scheme) ->
    #panel{body = [scheme_panel(undefined)]};
placeholder(_Step) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px dashed rgba(15,23,42,0.2);border-radius:6px;background:#f8fafc;">>,
           body = ias_html:text("Placeholder only. Selection and validation for this step will be implemented in a later stage.")}.

controls(Draft) ->
    WizardId = maps:get(id, Draft, undefined),
    CurrentStep = maps:get(current_step, Draft, scheme),
    #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
           body = [
               nav_action("Back", {wizard_back, WizardId}),
               nav_action("Next", {wizard_next, WizardId}),
               #link{class = [button, sgreen],
                     body = ias_html:text("Cancel"),
                     postback = {wizard_cancel, WizardId}},
               boundary_note(CurrentStep)
           ]}.

nav_action(Label, Postback) ->
    #link{class = [button, sgreen],
          body = ias_html:text(Label),
          postback = Postback}.

boundary_note(scheme) ->
    #span{style = note_style(),
          body = ias_html:text("Select or keep the device-bound scenario before continuing.")};
boundary_note(provisioning) ->
    #span{style = note_style(),
          body = ias_html:text("This is the last skeleton step. Next stays on Provisioning.")};
boundary_note(_Step) ->
    #span{style = note_style(),
          body = ias_html:text("Stage 24A navigation only. No runtime objects are created.")}.

key_value_table(Rows) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [key_value_row(Label, Value) || {Label, Value} <- Rows]}}
    ]}.

key_value_row(Label, Value) ->
    #tr{cells = [
        #th{body = ias_html:text(Label)},
        #td{body = ias_html:text(Value)}
    ]}.

step_state(Step, CurrentStep) ->
    StepIndex = index_of(Step),
    CurrentIndex = index_of(CurrentStep),
    case StepIndex of
        _ when Step =:= CurrentStep -> current;
        _ when StepIndex < CurrentIndex -> completed;
        _ -> pending
    end.

index_of(Step) ->
    index_of(Step, ias_provisioning_wizard_store:steps(), 1).

index_of(_Step, [], _Index) ->
    999;
index_of(Step, [Step | _Rest], Index) ->
    Index;
index_of(Step, [_Other | Rest], Index) ->
    index_of(Step, Rest, Index + 1).

enumerate(Items) ->
    enumerate(Items, 1, []).

enumerate([], _Index, Acc) ->
    lists:reverse(Acc);
enumerate([Item | Rest], Index, Acc) ->
    enumerate(Rest, Index + 1, [{Index, Item} | Acc]).

progress_style(current) ->
    <<"padding:8px;border:1px solid rgba(37,99,235,0.35);border-radius:6px;background:#eff6ff;">>;
progress_style(completed) ->
    <<"padding:8px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>;
progress_style(blocked) ->
    <<"padding:8px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>;
progress_style(_Pending) ->
    <<"padding:8px;border:1px solid rgba(15,23,42,0.12);border-radius:6px;background:#fff;">>.

disabled_action_style() ->
    <<"display:inline-block;padding:7px 10px;border:1px solid #cbd5e1;border-radius:5px;background:#f8fafc;color:#64748b;font-size:12px;font-weight:600;">>.

note_style() ->
    <<"font-size:12px;color:#64748b;">>.

redirect_after({ok, Draft}) ->
    nitro:redirect(wizard_url(maps:get(id, Draft)));
redirect_after({error, _Reason}) ->
    nitro:redirect(start_url()).

wizard_url(WizardId) ->
    ias_html:join([start_url(), <<"?id=">>, ias_html:text(WizardId)]).

start_url() ->
    <<"/app/provisioning-wizard.htm">>.

query_id() ->
    Cx = get(context),
    Req = Cx#cx.req,
    case Req of
        #{qs := QS} ->
            proplists:get_value(<<"id">>, uri_string:dissect_query(nitro:to_binary(QS)));
        #{query_string := QS} ->
            proplists:get_value(<<"id">>, uri_string:dissect_query(nitro:to_binary(QS)));
        _ ->
            nitro:qc(id)
    end.
