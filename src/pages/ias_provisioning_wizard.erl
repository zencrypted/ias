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
event({wizard_delete_draft, WizardId}) ->
    ok = ias_provisioning_wizard_store:delete(WizardId),
    nitro:redirect(start_url());
event({wizard_next, WizardId}) ->
    case ias_provisioning_wizard_store:next(WizardId) of
        {ok, Draft} -> nitro:redirect(wizard_url(maps:get(id, Draft)));
        {error, Reason} -> nitro:update(wizard_feedback, wizard_error(Reason))
    end;
event({wizard_select_device, WizardId, DeviceId}) ->
    redirect_after(ias_provisioning_wizard_store:select_device(WizardId, DeviceId));
event({wizard_select_security_profile, WizardId, ProfileId}) ->
    redirect_after(ias_provisioning_wizard_store:select_security_profile(WizardId, ProfileId));
event({wizard_select_vpn_service, WizardId, ServiceId}) ->
    redirect_after(ias_provisioning_wizard_store:select_vpn_service(WizardId, ServiceId));
event({wizard_create_vpn_service, WizardId}) ->
    Fields = #{name => nitro:q(wizard_vpn_service_name),
               endpoint => nitro:q(wizard_vpn_service_endpoint),
               port => nitro:q(wizard_vpn_service_port),
               protocol => nitro:q(wizard_vpn_service_protocol)},
    case ias_manual_vpn_service:create(Fields) of
        {ok, Service} ->
            redirect_after(ias_provisioning_wizard_store:select_vpn_service(
                WizardId, maps:get(id, Service)));
        {error, Reason} ->
            nitro:update(wizard_feedback, wizard_error(Reason))
    end;
event({wizard_create_device, WizardId}) ->
    Fields = #{name => nitro:q(wizard_device_name),
               type => nitro:q(wizard_device_type),
               tunnel_device => nitro:q(wizard_device_tunnel_device),
               transport => nitro:q(wizard_device_transport),
               endpoint => nitro:q(wizard_device_endpoint)},
    case ias_manual_device:create(Fields) of
        {ok, Device} ->
            redirect_after(ias_provisioning_wizard_store:select_device(
                WizardId, maps:get(id, Device)));
        {error, Reason} ->
            nitro:update(wizard_feedback, wizard_error(Reason))
    end;
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
        #p{body = ias_html:text("Create a new device-bound provisioning draft or resume work restored from Demo State.")},
        existing_wizard_drafts_panel(),
        scheme_panel(undefined)
    ]);
content_for({draft, Draft}) ->
    CurrentStep = maps:get(current_step, Draft, scheme),
    page([
        #h2{body = ias_html:text("Device-bound Provisioning Wizard")},
        #p{body = ias_html:text("Wizard draft is stored in runtime ETS only. Stage 24D can select or create a Device and VPN Service and select a Security Profile; relationships are not created yet.")},
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

existing_wizard_drafts_panel() ->
    Drafts = lists:reverse(ias_provisioning_wizard_store:all()),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Existing Wizard Drafts")},
        existing_wizard_drafts(Drafts)
    ]}.

existing_wizard_drafts([]) ->
    #p{body = ias_html:text("No saved wizard drafts are available. Start a new provisioning scheme below.")};
existing_wizard_drafts(Drafts) ->
    #panel{style = <<"display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:10px;">>,
           body = [existing_wizard_draft_card(Draft) || Draft <- Drafts]}.

existing_wizard_draft_card(Draft) ->
    WizardId = maps:get(id, Draft, undefined),
    #panel{style = <<"padding:12px;border:1px solid rgba(15,23,42,0.12);border-radius:6px;background:#fff;min-width:0;">>,
           body = [
               #h3{style = <<"margin:0 0 8px;font-size:14px;overflow-wrap:anywhere;">>,
                   body = ias_html:text(WizardId)},
               key_value_table([
                   {"Scenario", maps:get(scenario, Draft, undefined)},
                   {"Current Step", maps:get(current_step, Draft, undefined)},
                   {"Device", draft_reference(maps:get(device_id, Draft, undefined))},
                   {"VPN Service", draft_reference(maps:get(vpn_service_id, Draft, undefined))},
                   {"Updated At", maps:get(updated_at, Draft, undefined)}
               ]),
               #panel{style = <<"margin-top:10px;display:flex;gap:8px;align-items:center;flex-wrap:wrap;">>, body = [
                   #link{url = wizard_url(WizardId), class = [button, sgreen],
                         body = ias_html:text("Resume")},
                   #link{class = [button, more],
                         body = ias_html:text("Delete"),
                         postback = {wizard_delete_draft, WizardId}}
               ]}
           ]}.

draft_reference(undefined) -> <<"not selected">>;
draft_reference(<<>>) -> <<"not selected">>;
draft_reference(Value) -> Value.

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
        step_content(CurrentStep, Draft),
        #panel{id = wizard_feedback},
        controls(Draft)
    ]}.

step_heading(scheme) ->
    ias_html:text("Choose Provisioning Scheme");
step_heading(Step) ->
    ias_provisioning_wizard_store:step_title(Step).

step_content(scheme, _Draft) ->
    #panel{body = [scheme_panel(undefined)]};
step_content(device, Draft) ->
    device_step(Draft);
step_content(security_profile, Draft) ->
    security_profile_step(Draft);
step_content(vpn_service, Draft) ->
    vpn_service_step(Draft);
step_content(_Step, _Draft) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px dashed rgba(15,23,42,0.2);border-radius:6px;background:#f8fafc;">>,
           body = ias_html:text("Placeholder only. Selection and validation for this step will be implemented in a later stage.")}.


vpn_service_step(Draft) ->
    #panel{body = [
        selected_vpn_service_panel(Draft),
        existing_vpn_services_panel(Draft),
        create_vpn_service_panel(maps:get(id, Draft))
    ]}.

selected_vpn_service_panel(Draft) ->
    case ias_provisioning_wizard_store:selected_vpn_service(Draft) of
        {ok, Service} ->
            #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
                   body = [
                       #h3{body = ias_html:text("Selected VPN Service")},
                       key_value_table([
                           {"Service", service_link(maps:get(id, Service, undefined))},
                           {"Name", maps:get(name, Service, maps:get(service, Service, undefined))},
                           {"Endpoint", service_endpoint(Service)},
                           {"Port", service_port(Service)},
                           {"Protocol", maps:get(protocol, Service, undefined)},
                           {"TLS Auth / TLS Crypt", maps:get(tls_auth, Service, not_configured)}
                       ])
                   ]};
        not_selected ->
            wizard_notice("No VPN Service selected", "Select an existing VPN Service or create a new demo VPN Service before continuing.");
        {error, selected_vpn_service_missing} ->
            wizard_error_panel("The VPN Service stored in this wizard draft no longer exists. Select another service.");
        {error, _Reason} ->
            wizard_error_panel("The selected VPN Service is invalid.")
    end.

existing_vpn_services_panel(Draft) ->
    Services = ias_demo_store:services(),
    WizardId = maps:get(id, Draft),
    SelectedId = maps:get(vpn_service_id, Draft, undefined),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Use Existing VPN Service")},
        existing_vpn_services(Services, WizardId, SelectedId)
    ]}.

existing_vpn_services([], _WizardId, _SelectedId) ->
    #p{body = ias_html:text("No runtime VPN Services exist yet. Create one below.")};
existing_vpn_services(Services, WizardId, SelectedId) ->
    #panel{style = <<"display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:8px;">>,
           body = [vpn_service_choice(Service, WizardId, SelectedId) || Service <- Services]}.

vpn_service_choice(Service, WizardId, SelectedId) ->
    ServiceId = maps:get(id, Service, undefined),
    IsSelected = ias_html:text(ServiceId) =:= ias_html:text(SelectedId),
    #panel{style = device_choice_style(IsSelected), body = [
        #h3{style = <<"margin:0 0 6px;font-size:14px;">>,
            body = ias_html:text(maps:get(name, Service, maps:get(service, Service, ServiceId)))},
        #p{style = <<"margin:0 0 8px;font-size:12px;color:#64748b;">>,
           body = service_remote_label(Service)},
        vpn_service_select_action(IsSelected, WizardId, ServiceId)
    ]}.

vpn_service_select_action(true, _WizardId, _ServiceId) ->
    #span{style = disabled_action_style(), body = ias_html:text("Selected")};
vpn_service_select_action(false, WizardId, ServiceId) ->
    #link{class = [button, sgreen], body = ias_html:text("Select"),
          postback = {wizard_select_vpn_service, WizardId, ServiceId}}.

create_vpn_service_panel(WizardId) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Create New Demo VPN Service")},
        wizard_input_row("Service Name", wizard_vpn_service_name, <<"OpenVPN">>),
        wizard_input_row("Endpoint", wizard_vpn_service_endpoint, <<"vpn.example.com">>),
        wizard_input_row("Port", wizard_vpn_service_port, <<"1194">>),
        wizard_vpn_protocol_row(),
        #panel{style = <<"margin-top:12px;">>, body = [
            #link{class = [button, sgreen],
                  body = ias_html:text("Create and Select VPN Service"),
                  source = [wizard_vpn_service_name, wizard_vpn_service_endpoint,
                            wizard_vpn_service_port, wizard_vpn_service_protocol],
                  postback = {wizard_create_vpn_service, WizardId}}
        ]}
    ]}.

wizard_vpn_protocol_row() ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = wizard_vpn_service_protocol,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text("Protocol")},
               #select{id = wizard_vpn_service_protocol,
                       style = <<"min-width:260px;max-width:420px;width:100%;">>,
                       body = [
                           #option{value = <<"udp">>, selected = true, body = ias_html:text("udp")},
                           #option{value = <<"tcp">>, body = ias_html:text("tcp")}
                       ]}
           ]}.

service_endpoint(Service) ->
    case maps:get(remote_host, Service, undefined) of
        undefined -> maps:get(endpoint, Service, maps:get(remote, Service, not_configured));
        Host -> Host
    end.

service_port(Service) ->
    maps:get(remote_port, Service, not_configured).

service_remote_label(Service) ->
    case maps:get(remote_host, Service, undefined) of
        undefined ->
            ias_html:join([ias_html:text(maps:get(remote, Service, not_configured)), <<" / ">>,
                           ias_html:text(maps:get(protocol, Service, not_configured))]);
        Host ->
            ias_html:join([ias_html:text(Host), <<":">>, ias_html:text(service_port(Service)),
                           <<" / ">>, ias_html:text(maps:get(protocol, Service, not_configured))])
    end.

service_link(undefined) -> undefined;
service_link(ServiceId) ->
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(ServiceId)]),
          body = ias_html:text(ServiceId)}.


security_profile_step(Draft) ->
    #panel{body = [
        selected_security_profile_panel(Draft),
        available_security_profiles_panel(Draft)
    ]}.

selected_security_profile_panel(Draft) ->
    case ias_provisioning_wizard_store:selected_security_profile(Draft) of
        {ok, Profile} ->
            Compatibility = ias_provisioning_wizard_store:security_profile_compatibility(Profile),
            #panel{style = selected_profile_style(Compatibility),
                   body = [
                       #h3{body = ias_html:text("Selected Security Profile")},
                       key_value_table([
                           {"Profile", maps:get(name, Profile, maps:get(id, Profile, undefined))},
                           {"Device Lock", ias_security_profile:device_lock_label(Profile)},
                           {"2FA", ias_security_profile:two_factor_label(Profile)},
                           {"Services", ias_html:join_csv(maps:get(services, Profile, []))},
                           {"Trust Level", maps:get(trust_level, Profile, undefined)},
                           {"Provisioning Mode", <<"device_bound">>},
                           {"Private Key Policy", <<"device_owned">>}
                       ]),
                       profile_compatibility_notice(Compatibility)
                   ]};
        not_selected ->
            wizard_notice("No Security Profile selected", "Select a Security Profile before continuing.");
        {error, selected_security_profile_missing} ->
            wizard_error_panel("The Security Profile stored in this wizard draft no longer exists. Select another profile.");
        {error, _Reason} ->
            wizard_error_panel("The selected Security Profile is invalid.")
    end.

available_security_profiles_panel(Draft) ->
    Profiles = ias_security_profile:profiles(),
    WizardId = maps:get(id, Draft),
    SelectedId = maps:get(security_profile_id, Draft, undefined),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Choose Security Profile")},
        #panel{style = <<"display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px;">>,
               body = [security_profile_choice(Profile, WizardId, SelectedId) || Profile <- Profiles]}
    ]}.

security_profile_choice(Profile, WizardId, SelectedId) ->
    ProfileId = maps:get(id, Profile, undefined),
    Selected = ias_html:text(ProfileId) =:= ias_html:text(SelectedId),
    Compatibility = ias_provisioning_wizard_store:security_profile_compatibility(Profile),
    #panel{style = profile_choice_style(Selected, Compatibility), body = [
        #h3{style = <<"margin:0 0 6px;font-size:14px;">>,
            body = ias_html:text(maps:get(name, Profile, ProfileId))},
        #p{style = <<"margin:0 0 6px;font-size:12px;color:#64748b;">>,
           body = ias_html:text(maps:get(description, Profile, <<>>))},
        #p{style = <<"margin:0 0 8px;font-size:12px;">>,
           body = ias_html:join([<<"Device Lock: ">>, ias_security_profile:device_lock_label(Profile),
                                 <<" / 2FA: ">>, ias_security_profile:two_factor_label(Profile)])},
        compact_compatibility(Compatibility),
        profile_select_action(Compatibility, Selected, WizardId, ProfileId)
    ]}.

profile_select_action({blocked, _Reason}, _Selected, _WizardId, _ProfileId) ->
    #span{style = disabled_action_style(), body = ias_html:text("Unavailable")};
profile_select_action(_Compatibility, true, _WizardId, _ProfileId) ->
    #span{style = disabled_action_style(), body = ias_html:text("Selected")};
profile_select_action(_Compatibility, false, WizardId, ProfileId) ->
    #link{class = [button, sgreen], body = ias_html:text("Select"),
          postback = {wizard_select_security_profile, WizardId, ProfileId}}.

compact_compatibility(compatible) ->
    #p{style = <<"margin:0 0 8px;font-size:11px;color:#166534;">>, body = ias_html:text("Recommended for device-bound provisioning")};
compact_compatibility({warning, _Reason}) ->
    #p{style = <<"margin:0 0 8px;font-size:11px;color:#92400e;">>, body = ias_html:text("Allowed with warning")};
compact_compatibility({blocked, _Reason}) ->
    #p{style = <<"margin:0 0 8px;font-size:11px;color:#991b1b;">>, body = ias_html:text("Incompatible with device-bound provisioning")}.

profile_compatibility_notice(compatible) ->
    wizard_notice("Compatible", "This profile requires device lock and matches the device-bound provisioning scenario.");
profile_compatibility_notice({warning, Reason}) ->
    #panel{style = <<"margin-top:10px;padding:10px;border:1px solid rgba(217,119,6,0.25);border-radius:6px;background:#fffbeb;color:#92400e;">>,
           body = ias_html:text(Reason)};
profile_compatibility_notice({blocked, Reason}) ->
    wizard_error_panel(Reason).

selected_profile_style(compatible) ->
    <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>;
selected_profile_style({warning, _}) ->
    <<"margin-top:12px;padding:12px;border:1px solid rgba(217,119,6,0.25);border-radius:6px;background:#fffbeb;">>;
selected_profile_style({blocked, _}) ->
    <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>.

profile_choice_style(true, _Compatibility) ->
    <<"padding:12px;border:1px solid rgba(37,99,235,0.35);border-radius:6px;background:#eff6ff;">>;
profile_choice_style(false, compatible) ->
    <<"padding:12px;border:1px solid rgba(22,163,74,0.22);border-radius:6px;background:#fff;">>;
profile_choice_style(false, {warning, _}) ->
    <<"padding:12px;border:1px solid rgba(217,119,6,0.22);border-radius:6px;background:#fff;">>;
profile_choice_style(false, {blocked, _}) ->
    <<"padding:12px;border:1px solid rgba(220,38,38,0.18);border-radius:6px;background:#f8fafc;opacity:0.8;">>.

device_step(Draft) ->
    #panel{body = [
        selected_device_panel(Draft),
        existing_devices_panel(Draft),
        create_device_panel(maps:get(id, Draft))
    ]}.

selected_device_panel(Draft) ->
    case ias_provisioning_wizard_store:selected_device(Draft) of
        {ok, Device} ->
            #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
                   body = [
                       #h3{body = ias_html:text("Selected Device")},
                       key_value_table([
                           {"Device", device_link(maps:get(id, Device, undefined))},
                           {"Name", maps:get(name, Device, undefined)},
                           {"Type", maps:get(type, Device, undefined)},
                           {"Transport", maps:get(transport, Device, undefined)},
                           {"Endpoint", maps:get(endpoint, Device, undefined)}
                       ])
                   ]};
        not_selected ->
            wizard_notice("No Device selected", "Select an existing Device or create a new demo Device before continuing.");
        {error, selected_device_missing} ->
            #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;color:#991b1b;">>,
                   body = [
                       #h3{body = ias_html:text("Selected Device is unavailable")},
                       #p{body = ias_html:text("The Device stored in this wizard draft no longer exists. Select another Device before continuing.")}
                   ]};
        {error, _Reason} ->
            wizard_notice("Device selection is invalid", "Select an existing Device before continuing.")
    end.

existing_devices_panel(Draft) ->
    Devices = ias_demo_store:devices(),
    WizardId = maps:get(id, Draft),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Use Existing Device")},
        existing_devices(Devices, WizardId, maps:get(device_id, Draft, undefined))
    ]}.

existing_devices([], _WizardId, _SelectedId) ->
    #p{body = ias_html:text("No runtime Devices exist yet. Create one below.")};
existing_devices(Devices, WizardId, SelectedId) ->
    #panel{style = <<"display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:8px;">>,
           body = [device_choice(Device, WizardId, SelectedId) || Device <- Devices]}.

device_choice(Device, WizardId, SelectedId) ->
    DeviceId = maps:get(id, Device, undefined),
    IsSelected = DeviceId =:= SelectedId,
    #panel{style = device_choice_style(IsSelected), body = [
        #h3{style = <<"margin:0 0 6px;font-size:14px;">>,
            body = ias_html:text(maps:get(name, Device, DeviceId))},
        #p{style = <<"margin:0 0 8px;font-size:12px;color:#64748b;overflow-wrap:anywhere;">>,
           body = ias_html:join([maps:get(type, Device, <<"device">>), <<" / ">>,
                                 maps:get(transport, Device, <<"-">>), <<" / ">>,
                                 maps:get(endpoint, Device, <<"">>)])},
        #link{class = [button, sgreen],
              body = ias_html:text(case IsSelected of true -> "Selected"; false -> "Select" end),
              postback = {wizard_select_device, WizardId, DeviceId}}
    ]}.

create_device_panel(WizardId) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Create New Demo Device")},
        wizard_input_row("Device Name", wizard_device_name, <<>>),
        wizard_input_row("Device Type", wizard_device_type, <<"vpn-client">>),
        wizard_input_row("Tunnel Device", wizard_device_tunnel_device, <<"tun">>),
        wizard_transport_row(),
        wizard_input_row("Endpoint", wizard_device_endpoint, <<>>),
        #panel{style = <<"margin-top:12px;">>, body = [
            #link{class = [button, sgreen],
                  body = ias_html:text("Create and Select Device"),
                  source = [wizard_device_name, wizard_device_type,
                            wizard_device_tunnel_device, wizard_device_transport,
                            wizard_device_endpoint],
                  postback = {wizard_create_device, WizardId}}
        ]}
    ]}.

wizard_input_row(Label, Id, Value) ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = Id, style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text(Label)},
               #input{id = Id, type = <<"text">>, value = Value,
                      style = <<"min-width:260px;max-width:420px;width:100%;">>}
           ]}.

wizard_transport_row() ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = wizard_device_transport,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text("Transport")},
               #select{id = wizard_device_transport,
                       style = <<"min-width:260px;max-width:420px;width:100%;">>,
                       body = [
                           #option{value = <<"udp">>, selected = true, body = ias_html:text("udp")},
                           #option{value = <<"tcp">>, body = ias_html:text("tcp")}
                       ]}
           ]}.

wizard_notice(Title, Text) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(37,99,235,0.2);border-radius:6px;background:#eff6ff;">>,
           body = [#h3{body = ias_html:text(Title)}, #p{body = ias_html:text(Text)}]}.

wizard_error(device_required) ->
    wizard_error_panel("Select or create a Device before continuing.");
wizard_error(selected_device_missing) ->
    wizard_error_panel("The selected Device no longer exists. Select another Device.");
wizard_error(security_profile_required) ->
    wizard_error_panel("Select a Security Profile before continuing.");
wizard_error(selected_security_profile_missing) ->
    wizard_error_panel("The selected Security Profile no longer exists. Select another profile.");
wizard_error(incompatible_security_profile) ->
    wizard_error_panel("The selected Security Profile is incompatible with device-bound provisioning.");
wizard_error(vpn_service_required) ->
    wizard_error_panel("Select or create a VPN Service before continuing.");
wizard_error(selected_vpn_service_missing) ->
    wizard_error_panel("The selected VPN Service no longer exists. Select another service.");
wizard_error(Reason) ->
    wizard_error_panel(Reason).

wizard_error_panel(Reason) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;color:#991b1b;">>,
           body = ias_html:text(Reason)}.

device_link(undefined) -> undefined;
device_link(DeviceId) ->
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(DeviceId)]),
          body = ias_html:text(DeviceId)}.

device_choice_style(true) ->
    <<"padding:12px;border:1px solid rgba(22,163,74,0.35);border-radius:6px;background:#f0fdf4;">>;
device_choice_style(false) ->
    <<"padding:12px;border:1px solid rgba(15,23,42,0.12);border-radius:6px;background:#fff;">>.

controls(Draft) ->
    WizardId = maps:get(id, Draft, undefined),
    CurrentStep = maps:get(current_step, Draft, scheme),
    #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
           body = [
               nav_action("Back", {wizard_back, WizardId}),
               next_action(Draft, WizardId),
               #link{class = [button, sgreen],
                     body = ias_html:text("Cancel"),
                     postback = {wizard_cancel, WizardId}},
               boundary_note(CurrentStep)
           ]}.

nav_action(Label, Postback) ->
    #link{class = [button, sgreen],
          body = ias_html:text(Label),
          postback = Postback}.

next_action(#{current_step := device} = Draft, WizardId) ->
    case ias_provisioning_wizard_store:selected_device(Draft) of
        {ok, _Device} -> nav_action("Next", {wizard_next, WizardId});
        _ -> #span{style = disabled_action_style(), body = ias_html:text("Next")}
    end;
next_action(#{current_step := security_profile} = Draft, WizardId) ->
    case ias_provisioning_wizard_store:selected_security_profile(Draft) of
        {ok, Profile} ->
            case ias_provisioning_wizard_store:security_profile_compatibility(Profile) of
                {blocked, _Reason} -> #span{style = disabled_action_style(), body = ias_html:text("Next")};
                _ -> nav_action("Next", {wizard_next, WizardId})
            end;
        _ -> #span{style = disabled_action_style(), body = ias_html:text("Next")}
    end;
next_action(#{current_step := vpn_service} = Draft, WizardId) ->
    case ias_provisioning_wizard_store:selected_vpn_service(Draft) of
        {ok, _Service} -> nav_action("Next", {wizard_next, WizardId});
        _ -> #span{style = disabled_action_style(), body = ias_html:text("Next")}
    end;
next_action(_Draft, WizardId) ->
    nav_action("Next", {wizard_next, WizardId}).

boundary_note(scheme) ->
    #span{style = note_style(),
          body = ias_html:text("Select or keep the device-bound scenario before continuing.")};
boundary_note(provisioning) ->
    #span{style = note_style(),
          body = ias_html:text("This is the last skeleton step. Next stays on Provisioning.")};
boundary_note(_Step) ->
    #span{style = note_style(),
          body = ias_html:text("Wizard selections are stored in the volatile runtime draft.")}.

key_value_table(Rows) ->
    #panel{class = <<"ias-table-container">>, body = [
        #table{class = <<"ias-table">>,
               body = #tbody{body = [key_value_row(Label, Value) || {Label, Value} <- Rows]}}
    ]}.

key_value_row(Label, Value) ->
    #tr{cells = [
        #th{body = ias_html:text(Label)},
        #td{body = value_body(Value)}
    ]}.

value_body(#link{} = Link) -> Link;
value_body(Value) -> ias_html:text(Value).

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
