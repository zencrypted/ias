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
    redirect_after(ias_provisioning_wizard_store:select_existing_device(WizardId, DeviceId));
event({wizard_select_security_profile, WizardId, ProfileId}) ->
    redirect_after(ias_provisioning_wizard_store:select_existing_security_profile(WizardId, ProfileId));
event({wizard_select_vpn_service, WizardId, ServiceId}) ->
    redirect_after(ias_provisioning_wizard_store:select_existing_vpn_service(WizardId, ServiceId));
event({wizard_select_ca_certificate, WizardId, CertificateId}) ->
    redirect_after(ias_provisioning_wizard_store:select_existing_ca_certificate(WizardId, CertificateId));
event({wizard_select_client_certificate, WizardId, CertificateId}) ->
    redirect_after(ias_provisioning_wizard_store:select_existing_client_certificate(WizardId, CertificateId));
event({wizard_request_device_csr_certificate, WizardId}) ->
    CsrPem = nitro:q(wizard_device_csr_pem),
    PrivateKeyRef = nitro:q(wizard_pending_private_key_ref),
    case ias_device_csr_enrollment:enroll_for_wizard(WizardId, CsrPem, PrivateKeyRef) of
        {ok, Draft, _Certificate} -> nitro:redirect(wizard_url(maps:get(id, Draft)));
        {error, Reason} -> nitro:update(wizard_feedback, wizard_error(device_csr_error_text(Reason)))
    end;
event({wizard_download_device_csr_script, WizardId}) ->
    wizard_download_device_csr_script(WizardId);
event({wizard_prepare_device_csr_plan, WizardId}) ->
    redirect_after_device_csr_plan(
        fun() -> ias_provisioning_wizard_store:prepare_device_csr_plan(WizardId) end);
event({wizard_regenerate_device_csr_plan, WizardId}) ->
    redirect_after_device_csr_plan(
        fun() -> ias_provisioning_wizard_store:regenerate_device_csr_plan(WizardId) end);
event({wizard_apply_relationships, WizardId}) ->
    case ias_provisioning_wizard_store:apply_relationships(WizardId) of
        {ok, Draft} -> nitro:redirect(wizard_url(maps:get(id, Draft)));
        {error, Reason} -> nitro:update(wizard_feedback, wizard_error(Reason))
    end;
event({wizard_verify_client_certificate, WizardId}) ->
    case ias_provisioning_wizard_store:get(WizardId) of
        {ok, Draft} ->
            case ias_provisioning_wizard_authorization:verify_client_certificate(Draft) of
                {ok, _Verification} -> nitro:redirect(wizard_url(WizardId));
                {error, Reason} -> nitro:update(wizard_feedback, wizard_error(Reason))
            end;
        not_found ->
            nitro:update(wizard_feedback, wizard_error(not_found))
    end;
event({wizard_refresh_readiness, WizardId}) ->
    redirect_after(ias_provisioning_wizard_store:remediate_readiness(WizardId));
event({wizard_repair_relationships, WizardId}) ->
    redirect_after(ias_provisioning_wizard_store:remediate_readiness(WizardId));
event({wizard_review_relationships, WizardId}) ->
    redirect_after(ias_provisioning_wizard_store:update(
        WizardId, #{current_step => relationships,
                    relationships_applied => false}));
event({wizard_create_provisioning, WizardId}) ->
    case ias_provisioning_wizard_store:create_provisioning(WizardId) of
        {ok, Draft, _Transaction} -> nitro:redirect(wizard_url(maps:get(id, Draft)));
        {error, Reason} -> nitro:update(wizard_feedback, wizard_error(Reason))
    end;
event({wizard_create_another_provisioning, WizardId}) ->
    case ias_provisioning_wizard_store:create_another_provisioning(WizardId) of
        {ok, Draft, _Transaction} -> nitro:redirect(wizard_url(maps:get(id, Draft)));
        {error, Reason} -> nitro:update(wizard_feedback, wizard_error(Reason))
    end;
event({wizard_download_device_bound_ovpn, ProvisioningId}) ->
    wizard_download_device_bound_ovpn(
        ias_device_bound_ovpn:download_response(ProvisioningId));
event({wizard_issue_client_certificate, WizardId}) ->
    Fields = #{user_id => nitro:q(wizard_client_certificate_user),
               subject_cn => nitro:q(wizard_client_certificate_subject_cn),
               pem => nitro:q(wizard_client_certificate_pem)},
    case ias_wizard_client_certificate:issue(Fields) of
        {ok, Certificate} ->
            redirect_after(ias_provisioning_wizard_store:select_existing_client_certificate(
                WizardId, maps:get(id, Certificate)));
        {error, Reason} ->
            nitro:update(wizard_feedback, wizard_error(Reason))
    end;
event({wizard_register_ca_certificate, WizardId}) ->
    Fields = #{name => nitro:q(wizard_ca_certificate_name),
               subject => nitro:q(wizard_ca_certificate_subject),
               pem => nitro:q(wizard_ca_certificate_pem)},
    case ias_demo_ca_certificate:register(Fields) of
        {ok, Certificate} ->
            redirect_after(ias_provisioning_wizard_store:select_existing_ca_certificate(
                WizardId, maps:get(id, Certificate)));
        {error, Reason} ->
            nitro:update(wizard_feedback, wizard_error(Reason))
    end;
event({wizard_load_configured_ca_trust_anchor, WizardId}) ->
    case ias_configured_ca_trust_anchor:load() of
        {ok, Certificate} ->
            redirect_after(ias_provisioning_wizard_store:select_existing_ca_certificate(
                WizardId, maps:get(id, Certificate)));
        {error, Reason} ->
            nitro:update(wizard_ca_configured_result,
                         wizard_error_panel(configured_ca_error_text(Reason)))
    end;
event({wizard_create_vpn_service, WizardId}) ->
    Fields = #{name => nitro:q(wizard_vpn_service_name),
               endpoint => nitro:q(wizard_vpn_service_endpoint),
               port => nitro:q(wizard_vpn_service_port),
               protocol => nitro:q(wizard_vpn_service_protocol)},
    case ias_manual_vpn_service:create(Fields) of
        {ok, Service} ->
            redirect_after(ias_provisioning_wizard_store:select_existing_vpn_service(
                WizardId, maps:get(id, Service)));
        {error, Reason} ->
            nitro:update(wizard_feedback, wizard_error(Reason))
    end;
event({wizard_create_device, WizardId}) ->
    Fields = #{name => nitro:q(wizard_device_name),
               type => nitro:q(wizard_device_type),
               tunnel_device => nitro:q(wizard_device_tunnel_device),
               transport => nitro:q(wizard_device_transport),
               endpoint => nitro:q(wizard_device_endpoint),
               private_key_provider => nitro:q(wizard_device_private_key_provider),
               private_key_ref => nitro:q(wizard_device_private_key_ref)},
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
    page([
        #h2{body = ias_html:text("Device-bound Provisioning Wizard")},
        #p{body = ias_html:text("Wizard draft is stored in runtime ETS. The derived Security Policy is shown with the selected profile, and relationships are committed automatically after the client certificate step when preflight succeeds.")},
        draft_summary(Draft),
        progress_panel(Draft),
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
                   {"Status", draft_status(Draft)},
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
            {"Status", draft_status(Draft)},
            {"Provisioning", draft_reference(maps:get(provisioning_id, Draft, undefined))},
            {"Created At", maps:get(created_at, Draft, undefined)},
            {"Updated At", maps:get(updated_at, Draft, undefined)}
        ])
    ]}.

progress_panel(Draft) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Progress")},
        #panel{style = <<"display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:8px;">>,
               body = [progress_item(Index, Step, Draft)
                       || {Index, Step} <- enumerate(ias_provisioning_wizard_store:steps())]}
    ]}.

progress_item(Index, Step, Draft) ->
    State = step_state(Step, Draft),
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
step_content(ca_certificate, Draft) ->
    ca_certificate_step(Draft);
step_content(client_certificate, Draft) ->
    client_certificate_step(Draft);
step_content(relationships, Draft) ->
    relationships_step(Draft);
step_content(material_readiness, Draft) ->
    material_readiness_step(Draft);
step_content(provisioning, Draft) ->
    provisioning_step(Draft);
step_content(_Step, _Draft) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px dashed rgba(15,23,42,0.2);border-radius:6px;background:#f8fafc;">>,
           body = ias_html:text("Placeholder only. Selection and validation for this step will be implemented in a later stage.")}.



draft_status(Draft) ->
    case maps:get(completed, Draft, false) of
        true -> completed;
        false -> in_progress
    end.

provisioning_step(Draft) ->
    Readiness = ias_provisioning_wizard_store:material_readiness(Draft),
    #panel{body = [
        provisioning_final_summary(Draft, Readiness),
        provisioning_result_panel(Draft, Readiness)
    ]}.

provisioning_final_summary(Draft, Readiness) ->
    Plan = maps:get(plan, Readiness, #{}),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Final Provisioning Summary")},
        key_value_table([
            {"Device", device_link(maps:get(device_id, Draft, undefined))},
            {"Security Profile", selected_profile_value(Draft)},
            {"Security Policy", derived_policy_value(Draft)},
            {"VPN Service", service_link(maps:get(vpn_service_id, Draft, undefined))},
            {"CA Certificate", certificate_link(maps:get(ca_certificate_id, Draft, undefined))},
            {"Client Certificate", certificate_link(maps:get(client_certificate_id, Draft, undefined))},
            {"Authorization", maps:get(authorization, Plan, deny)},
            {"Material", maps:get(material_status, Readiness,
                                  maps:get(material_status, Plan, blocked))},
            {"Assembly", maps:get(assembly_status, Plan, blocked)}
        ])
    ]}.

selected_profile_value(Draft) ->
    case ias_provisioning_wizard_store:selected_security_profile(Draft) of
        {ok, Profile} -> maps:get(name, Profile, maps:get(id, Profile, undefined));
        _ -> undefined
    end.

derived_policy_value(Draft) ->
    case ias_provisioning_wizard_authorization:derived_policy(Draft) of
        {ok, Policy} -> maps:get(id, Policy, undefined);
        _ -> undefined
    end.

provisioning_result_panel(Draft, Readiness) ->
    case ias_provisioning_wizard_store:provisioning_transaction(Draft) of
        {ok, Transaction} ->
            provisioning_created_panel(Draft, Transaction);
        not_found ->
            case maps:get(provisioning_id, Draft, undefined) of
                undefined -> provisioning_create_panel(Draft, Readiness);
                <<>> -> provisioning_create_panel(Draft, Readiness);
                MissingId -> provisioning_missing_panel(Draft, Readiness, MissingId)
            end
    end.

provisioning_created_panel(Draft, Transaction) ->
    ProvisioningId = maps:get(id, Transaction, undefined),
    #panel{class = <<"ias-status-card">>, body = [
        wizard_notice("Provisioning Transaction Created",
                      "The wizard is complete. Reopening this draft reuses the same transaction instead of creating a duplicate."),
        key_value_table([
            {"Provisioning ID", provisioning_link(ProvisioningId)},
            {"Authorization", maps:get(authorization, Transaction, deny)},
            {"Material", maps:get(material_status, Transaction, blocked)},
            {"Assembly", maps:get(assembly_status, Transaction, blocked)},
            {"Certificate Validation", maps:get(certificate_validation_mode, Transaction, strict)},
            {"Artifact", maps:get(artifact_status, Transaction, unavailable)},
            {"Delivery", maps:get(delivery_status, Transaction, not_ready)},
            {"Expires At", maps:get(expires_at, Transaction, undefined)},
            {"Completed At", maps:get(completed_at, Draft, undefined)}
        ]),
        wizard_certificate_validation_warning(Transaction),
        #panel{style = <<"margin-top:12px;display:flex;gap:8px;align-items:center;flex-wrap:wrap;">>, body = [
            #link{url = demo_object_url(ProvisioningId), class = [button, sgreen],
                  body = ias_html:text("Open Provisioning Transaction")},
            wizard_download_device_bound_ovpn_action(Transaction),
            #link{class = [button, more],
                  body = ias_html:text("Create Another Transaction"),
                  postback = {wizard_create_another_provisioning, maps:get(id, Draft)}}
        ]},
        #panel{id = wizard_ovpn_download_result}
    ]}.

wizard_download_device_bound_ovpn_action(#{mode := device_bound,
                                           artifact_status := public_bundle_ready,
                                           id := ProvisioningId}) ->
    #link{class = [button, sgreen],
          body = ias_html:text("Download Device-bound OVPN"),
          postback = {wizard_download_device_bound_ovpn, ProvisioningId}};
wizard_download_device_bound_ovpn_action(_Transaction) ->
    #span{body = <<>>}.

wizard_certificate_validation_warning(#{certificate_validation_bypass := true}) ->
    wizard_notice("Development certificate validation mode",
                  "Validity and chain checks may be relaxed for demo fixtures; PEM parsing, role separation, fingerprint checks and OVPN injection protections remain enforced.");
wizard_certificate_validation_warning(_Transaction) ->
    #panel{body = []}.

provisioning_create_panel(Draft, #{ready := true}) ->
    #panel{class = <<"ias-status-card">>, body = [
        wizard_notice("Ready to Create Transaction",
                      "Final preflight passed. Create the sanitized device-bound provisioning transaction."),
        #link{class = [button, sgreen],
              body = ias_html:text("Create Provisioning Transaction"),
              postback = {wizard_create_provisioning, maps:get(id, Draft)}}
    ]};
provisioning_create_panel(_Draft, Readiness) ->
    #panel{class = <<"ias-status-card">>, body = [
        wizard_error_panel(maps:get(reason, Readiness,
                                    <<"Provisioning preflight is blocked.">>)),
        #p{body = ias_html:text("Return to Material Readiness and resolve the failed checks before creating a transaction.")}
    ]}.

provisioning_missing_panel(Draft, #{ready := true}, MissingId) ->
    #panel{class = <<"ias-status-card">>, body = [
        wizard_error_panel(ias_html:join([<<"The stored provisioning transaction ">>,
                                          ias_html:text(MissingId),
                                          <<" no longer exists.">>])),
        #link{class = [button, sgreen],
              body = ias_html:text("Create Replacement Transaction"),
              postback = {wizard_create_another_provisioning, maps:get(id, Draft)}}
    ]};
provisioning_missing_panel(_Draft, Readiness, MissingId) ->
    #panel{class = <<"ias-status-card">>, body = [
        wizard_error_panel(ias_html:join([<<"The stored provisioning transaction ">>,
                                          ias_html:text(MissingId),
                                          <<" no longer exists, and current readiness is blocked: ">>,
                                          ias_html:text(maps:get(reason, Readiness, undefined))]))
    ]}.

provisioning_link(undefined) -> undefined;
provisioning_link(ProvisioningId) ->
    #link{url = demo_object_url(ProvisioningId), body = ias_html:text(ProvisioningId)}.

demo_object_url(ObjectId) ->
    ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(ObjectId)]).

material_readiness_step(Draft) ->
    Readiness = ias_provisioning_wizard_store:material_readiness(Draft),
    #panel{body = [
        material_readiness_notice(Readiness),
        material_readiness_items(maps:get(items, Readiness, [])),
        material_readiness_summary(Readiness),
        material_readiness_actions(Draft, Readiness)
    ]}.

material_readiness_notice(#{ready := true}) ->
    wizard_notice("Ready for Provisioning",
                  "Authorization, relationships and public certificate material are ready. Continue to create the provisioning transaction.");
material_readiness_notice(#{reason := Reason}) ->
    wizard_error_panel(Reason);
material_readiness_notice(_Readiness) ->
    wizard_error_panel("Material readiness is blocked.").

material_readiness_items(Items) ->
    #panel{style = <<"display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px;margin-top:12px;">>,
           body = [material_readiness_card(Item) || Item <- Items]}.

material_readiness_card(Item) ->
    Status = maps:get(status, Item, unknown),
    #panel{style = material_readiness_card_style(Status), body = [
        #panel{style = <<"display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;">>,
               body = [
                   #h3{style = <<"margin:0;font-size:14px;">>,
                       body = ias_html:text(maps:get(label, Item, undefined))},
                   material_readiness_badge(Status)
               ]},
        #p{style = <<"margin:8px 0 0;font-size:12px;line-height:1.45;color:#475569;overflow-wrap:anywhere;word-break:normal;">>,
           body = ias_html:text(maps:get(detail, Item, undefined))}
    ]}.

material_readiness_badge(Status) ->
    relationship_badge(ias_html:text(Status), material_readiness_badge_style(Status)).

material_readiness_badge_style(ready) ->
    <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>;
material_readiness_badge_style(ready_for_device_assembly) ->
    <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>;
material_readiness_badge_style(public_bundle_ready) ->
    <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>;
material_readiness_badge_style(ready_for_delivery) ->
    <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>;
material_readiness_badge_style(ready_for_device_import) ->
    <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>;
material_readiness_badge_style(available) ->
    <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>;
material_readiness_badge_style(available_on_device) ->
    <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>;
material_readiness_badge_style(trusted) ->
    <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>;
material_readiness_badge_style(allow) ->
    <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>;
material_readiness_badge_style(verified) ->
    <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>;
material_readiness_badge_style(compatible) ->
    <<"background:#eff6ff;color:#1d4ed8;border-color:#93c5fd;">>;
material_readiness_badge_style(optional) ->
    <<"background:#f8fafc;color:#475569;border-color:#cbd5e1;">>;
material_readiness_badge_style(configured) ->
    <<"background:#eff6ff;color:#1d4ed8;border-color:#93c5fd;">>;
material_readiness_badge_style(warning) ->
    <<"background:#fffbeb;color:#92400e;border-color:#fcd34d;">>;
material_readiness_badge_style(_Status) ->
    <<"background:#fef2f2;color:#991b1b;border-color:#fca5a5;">>.

material_readiness_card_style(warning) ->
    <<"padding:12px;border:1px solid rgba(217,119,6,0.24);border-radius:6px;background:#fffbeb;min-width:0;">>;
material_readiness_card_style(Status) ->
    Border = case readiness_positive_status(Status) of
                 true -> <<"rgba(22,163,74,0.24)">>;
                 false -> <<"rgba(220,38,38,0.22)">>
             end,
    Background = case readiness_positive_status(Status) of
                     true -> <<"#fff">>;
                     false -> <<"#fefafa">>
                 end,
    ias_html:join([<<"padding:12px;border:1px solid ">>, Border,
                   <<";border-radius:6px;background:">>, Background,
                   <<";min-width:0;">>]).

readiness_positive_status(ready) -> true;
readiness_positive_status(ready_for_device_assembly) -> true;
readiness_positive_status(public_bundle_ready) -> true;
readiness_positive_status(ready_for_delivery) -> true;
readiness_positive_status(ready_for_device_import) -> true;
readiness_positive_status(available) -> true;
readiness_positive_status(available_on_device) -> true;
readiness_positive_status(trusted) -> true;
readiness_positive_status(allow) -> true;
readiness_positive_status(verified) -> true;
readiness_positive_status(compatible) -> true;
readiness_positive_status(optional) -> true;
readiness_positive_status(configured) -> true;
readiness_positive_status(_) -> false.

material_readiness_summary(Readiness) ->
    Plan = maps:get(plan, Readiness, #{}),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Readiness Decision")},
        key_value_table([
            {"Ready", maps:get(ready, Readiness, false)},
            {"Authorization", maps:get(authorization, Plan, deny)},
            {"Material", maps:get(material_status, Readiness,
                                  maps:get(material_status, Plan, blocked))},
            {"Assembly", maps:get(assembly_status, Plan, blocked)},
            {"Reason", maps:get(reason, Readiness, undefined)},
            {"Next Step", maps:get(next_step, Readiness, undefined)}
        ])
    ]}.

material_readiness_actions(Draft, Readiness) ->
    CaId = maps:get(ca_certificate_id, Draft, undefined),
    ClientId = maps:get(client_certificate_id, Draft, undefined),
    DeviceId = maps:get(device_id, Draft, undefined),
    ServiceId = maps:get(vpn_service_id, Draft, undefined),
    Review = maps:get(relationship_review, Readiness, #{}),
    Actions0 = [
        relationship_remediation_action(Draft, Review),
        device_remediation_action(Readiness, DeviceId),
        private_key_remediation_action(Readiness, DeviceId),
        object_remediation_action(readiness_status(vpn_endpoint, Readiness),
                                  available, "Open VPN Service", ServiceId),
        ca_certificate_action(Readiness, CaId),
        client_certificate_action(Readiness, ClientId),
        client_verification_action(Draft),
        #link{class = [button, more],
              body = ias_html:text("Refresh Readiness"),
              postback = {wizard_refresh_readiness, maps:get(id, Draft)}}
    ],
    Actions = [Action || Action <- Actions0, Action =/= undefined],
    #panel{style = <<"margin-top:12px;display:flex;gap:8px;align-items:center;flex-wrap:wrap;">>,
           body = Actions}.

relationship_remediation_action(_Draft, #{ready := true}) ->
    undefined;
relationship_remediation_action(Draft, #{can_apply := true}) ->
    #link{class = [button, sgreen],
          body = ias_html:text("Repair Relationships"),
          postback = {wizard_repair_relationships, maps:get(id, Draft)}};
relationship_remediation_action(Draft, _Review) ->
    #link{class = [button, more],
          body = ias_html:text("Review Relationships"),
          postback = {wizard_review_relationships, maps:get(id, Draft)}}.


device_remediation_action(Readiness, DeviceId) ->
    RelationshipStatus = readiness_status(relationships, Readiness),
    PolicyStatus = readiness_status(security_policy, Readiness),
    ProfileStatus = readiness_status(security_profile, Readiness),
    case readiness_statuses_positive([
             {RelationshipStatus, [ready]},
             {PolicyStatus, [ready]},
             {ProfileStatus, [compatible, warning]}
         ]) of
        true -> undefined;
        false -> object_link_action("Open Device", DeviceId)
    end.

private_key_remediation_action(Readiness, DeviceId) ->
    case readiness_status(private_key, Readiness) of
        available_on_device -> undefined;
        _ -> object_link_action("Configure Device Key Reference", DeviceId)
    end.

ca_certificate_action(Readiness, CaId) ->
    CertificateStatus = readiness_status(ca_certificate, Readiness),
    MaterialStatus = readiness_status(ca_certificate_pem, Readiness),
    case readiness_statuses_positive([
             {CertificateStatus, [trusted]},
             {MaterialStatus, [available]}
         ]) of
        true -> undefined;
        false -> object_link_action("Open CA Certificate", CaId)
    end.

client_certificate_action(Readiness, ClientId) ->
    CertificateStatus = readiness_status(client_certificate, Readiness),
    MaterialStatus = readiness_status(client_certificate_pem, Readiness),
    case readiness_statuses_positive([
             {CertificateStatus, [trusted]},
             {MaterialStatus, [available]}
         ]) of
        true -> undefined;
        false -> object_link_action("Open Client Certificate", ClientId)
    end.

object_remediation_action(Status, Expected, _Label, _ObjectId)
  when Status =:= Expected ->
    undefined;
object_remediation_action(_Status, _Expected, Label, ObjectId) ->
    object_link_action(Label, ObjectId).

object_link_action(_Label, undefined) ->
    undefined;
object_link_action(Label, ObjectId) ->
    #link{url = demo_object_url(ObjectId), class = [button, sgreen],
          body = ias_html:text(Label)}.

readiness_status(Key, Readiness) ->
    case [maps:get(status, Item, unknown)
          || Item <- maps:get(items, Readiness, []),
             maps:get(key, Item, undefined) =:= Key] of
        [Status | _] -> Status;
        [] -> unknown
    end.

readiness_statuses_positive(Checks) ->
    lists:all(fun({Status, Allowed}) -> lists:member(Status, Allowed) end, Checks).


client_verification_action(Draft) ->
    WizardId = maps:get(id, Draft, undefined),
    case ias_provisioning_wizard_authorization:verification_status(Draft) of
        verified ->
            undefined;
        not_verified ->
            #link{class = [button, sgreen],
                  body = ias_html:text("Verify Client Certificate"),
                  postback = {wizard_verify_client_certificate, WizardId}};
        failed ->
            #link{class = [button, sgreen],
                  body = ias_html:text("Verify Client Certificate Again"),
                  postback = {wizard_verify_client_certificate, WizardId}};
        _ ->
            undefined
    end.

relationships_step(Draft) ->
    Review = ias_provisioning_wizard_store:relationship_review(Draft),
    #panel{body = [
        relationships_review_notice(Review),
        relationships_review_table(maps:get(items, Review, [])),
        relationships_apply_action(Review, maps:get(id, Draft))
    ]}.

relationships_review_notice(#{ready := true}) ->
    wizard_notice("Relationships Applied",
                  "All required relationships are present. Continue to Material Readiness.");
relationships_review_notice(#{can_apply := true}) ->
    wizard_notice("Ready to Apply",
                  "Preflight passed. Review the graph below, then apply all missing relationships together.");
relationships_review_notice(_Review) ->
    wizard_error_panel("Relationship preflight found a conflict, invalid selection or stale reference. Resolve it before applying the graph.").

relationships_review_table(Items) ->
    #panel{style = <<"display:grid;grid-template-columns:1fr;gap:10px;">>,
           body = [relationships_review_card(Item) || Item <- Items]}.

relationships_review_card(Item) ->
    Status = maps:get(status, Item, invalid),
    Base = [
        #panel{style = <<"display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;">>,
               body = [
                   #h3{style = <<"margin:0;font-size:15px;line-height:1.3;">>,
                       body = relationship_label(maps:get(key, Item, undefined))},
                   relationship_status_badge(Status)
               ]},
        #panel{style = <<"display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:10px;margin-top:10px;">>,
               body = [
                   relationship_endpoint("Source",
                                         maps:get(source_label, Item, undefined),
                                         maps:get(source_id, Item, undefined)),
                   relationship_endpoint("Target",
                                         maps:get(target_label, Item, undefined),
                                         maps:get(target_id, Item, undefined))
               ]}
    ],
    #panel{style = <<"padding:12px;border:1px solid rgba(15,23,42,0.12);border-radius:6px;background:#fff;min-width:0;overflow:hidden;">>,
           body = Base ++ relationship_notes(maps:get(notes, Item, <<"-">>))}.

relationship_endpoint(Caption, Label, Id) ->
    #panel{style = <<"padding:10px;border:1px solid rgba(15,23,42,0.08);border-radius:5px;background:#f8fafc;min-width:0;">>,
           body = [
               #span{style = <<"display:block;margin-bottom:5px;font-size:10px;font-weight:700;letter-spacing:0.04em;text-transform:uppercase;color:#64748b;">>,
                     body = ias_html:text(Caption)},
               relationship_object_cell(Label, Id)
           ]}.

relationship_object_cell(undefined, Id) ->
    #span{style = <<"display:block;overflow-wrap:anywhere;word-break:normal;min-width:0;">>,
          body = ias_html:text(Id)};
relationship_object_cell(Label, Id) ->
    #panel{style = <<"min-width:0;">>, body = [
        #span{style = <<"display:block;font-weight:600;overflow-wrap:anywhere;word-break:normal;">>,
              body = ias_html:text(Label)},
        #span{style = <<"display:block;margin-top:3px;font-size:10px;line-height:1.35;color:#64748b;overflow-wrap:anywhere;word-break:normal;">>,
              body = ias_html:text(Id)}
    ]}.

relationship_notes(undefined) -> [];
relationship_notes(<<>>) -> [];
relationship_notes(<<"-">>) -> [];
relationship_notes(Notes) ->
    [#panel{style = <<"margin-top:10px;padding-top:9px;border-top:1px solid rgba(15,23,42,0.08);font-size:12px;color:#475569;overflow-wrap:anywhere;word-break:normal;">>,
            body = [
                #span{style = <<"font-weight:700;margin-right:6px;">>,
                      body = ias_html:text("Notes:")},
                #span{body = ias_html:text(Notes)}
            ]}].

relationship_label(device_security_profile) -> <<"Device -> Security Profile">>;
relationship_label(device_security_policy) -> <<"Device -> Security Policy">>;
relationship_label(device_vpn_service) -> <<"Device -> VPN Service">>;
relationship_label(device_client_certificate) -> <<"Device -> Client Certificate">>;
relationship_label(client_certificate_security_policy) -> <<"Client Certificate -> Security Policy">>;
relationship_label(vpn_service_ca_certificate) -> <<"VPN Service -> CA Certificate">>;
relationship_label(Key) -> ias_html:text(Key).

relationship_status_badge(will_create) ->
    relationship_badge("will_create", <<"background:#eff6ff;color:#1d4ed8;border-color:#93c5fd;">>);
relationship_status_badge(already_linked) ->
    relationship_badge("already_linked", <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>);
relationship_status_badge(conflict) ->
    relationship_badge("conflict", <<"background:#fef2f2;color:#991b1b;border-color:#fca5a5;">>);
relationship_status_badge(stale_reference) ->
    relationship_badge("stale_reference", <<"background:#fff7ed;color:#9a3412;border-color:#fdba74;">>);
relationship_status_badge(Status) ->
    relationship_badge(ias_html:text(Status), <<"background:#f8fafc;color:#475569;border-color:#cbd5e1;">>).

relationship_badge(Label, Style) ->
    #span{style = ias_html:join([
              <<"display:inline-block;flex:0 0 auto;padding:3px 6px;border:1px solid;border-radius:999px;font-size:10px;font-weight:700;white-space:nowrap;">>,
              Style]),
          body = ias_html:text(Label)}.

relationships_apply_action(#{ready := true}, _WizardId) ->
    #panel{style = <<"margin-top:12px;">>, body = [
        #span{style = disabled_action_style(), body = ias_html:text("Relationships Applied")}
    ]};
relationships_apply_action(#{can_apply := true}, WizardId) ->
    #panel{style = <<"margin-top:12px;">>, body = [
        #link{class = [button, sgreen],
              body = ias_html:text("Apply Relationships"),
              postback = {wizard_apply_relationships, WizardId}}
    ]};
relationships_apply_action(_Review, _WizardId) ->
    #panel{style = <<"margin-top:12px;">>, body = [
        #span{style = disabled_action_style(), body = ias_html:text("Apply Relationships")}
    ]}.

client_certificate_step(Draft) ->
    #panel{body = [
        selected_client_certificate_panel(Draft),
        existing_client_certificates_panel(Draft),
        request_certificate_from_ca_panel(Draft),
        request_certificate_with_device_csr_panel(Draft)
    ]}.

request_certificate_from_ca_panel(Draft) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Request Certificate from CA")},
        #p{style = <<"font-size:12px;color:#64748b;line-height:1.45;">>,
           body = ias_html:text("Open the CMP enrollment flow with this wizard context. After importing the issued certificate, IAS can return here with the certificate selected.")},
        #link{class = [button, sgreen],
              url = certificate_enrollment_url(Draft),
              body = ias_html:text("Request Certificate from CA")}
    ]}.

certificate_enrollment_url(Draft) ->
    Query = [
        {<<"wizard_id">>, maps:get(id, Draft, <<>>)},
        {<<"return_to">>, <<"provisioning_wizard">>},
        {<<"device_id">>, maps:get(device_id, Draft, <<>>)},
        {<<"suggested_cn">>, suggested_certificate_cn(Draft)}
    ],
    ias_html:join([<<"/app/certificate-enrollment.htm?">>, query_string(Query)]).

query_string(Pairs) ->
    ias_html:join(lists:join(<<"&">>,
                             [ias_html:join([Key, <<"=">>, uri_encode(Value)])
                              || {Key, Value} <- Pairs])).

uri_encode(Value) ->
    uri_string:quote(ias_html:text(Value)).

suggested_certificate_cn(Draft) ->
    case ias_provisioning_wizard_store:selected_device(Draft) of
        {ok, Device} ->
            first_defined([maps:get(name, Device, undefined),
                           maps:get(id, Device, undefined),
                           <<"vpn-client">>]);
        _ ->
            <<"vpn-client">>
    end.

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([<<>> | Rest]) -> first_defined(Rest);
first_defined([Value | _Rest]) -> Value.

selected_client_certificate_panel(Draft) ->
    case ias_provisioning_wizard_store:selected_client_certificate(Draft) of
        {ok, Certificate} ->
            CertificateId = maps:get(id, Certificate, undefined),
            Material = ias_certificate_material:status(CertificateId),
            #panel{style = selected_client_style(Material), body = [
                #h3{body = ias_html:text("Selected Client Certificate")},
                key_value_table([
                    {"Certificate", certificate_link(CertificateId)},
                    {"Subject CN", maps:get(subject_cn, Certificate, maps:get(subject, Certificate, undefined))},
                    {"Status", maps:get(certificate_status, Certificate, trusted)},
                    {"Public PEM", client_material_label(Material)},
                    {"Fingerprint", client_material_fingerprint(Material)},
                    {"Used By Device", client_certificate_device(CertificateId)}
                ]),
                client_material_notice(Material)
            ]};
        not_selected ->
            wizard_notice("No Client Certificate selected", "Select an existing client certificate with public PEM material or issue a new demo certificate before continuing.");
        {error, client_certificate_linked_to_other_device} ->
            wizard_error_panel("The selected Client Certificate is already linked to another Device. Use certificate replacement or select another certificate.");
        {error, selected_client_certificate_missing} ->
            wizard_error_panel("The Client Certificate stored in this wizard draft no longer exists. Select another certificate.");
        {error, invalid_client_certificate} ->
            wizard_error_panel("The selected certificate is not classified as a client certificate.");
        {error, _Reason} ->
            wizard_error_panel("The selected Client Certificate is invalid.")
    end.

existing_client_certificates_panel(Draft) ->
    Certificates = [Certificate || Certificate <- ias_demo_store:certificates(),
                                   explicit_client_certificate(Certificate)],
    WizardId = maps:get(id, Draft),
    SelectedId = maps:get(client_certificate_id, Draft, undefined),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Use Existing Client Certificate")},
        #p{style = <<"font-size:12px;color:#475569;line-height:1.45;">>,
           body = ias_html:text("Only certificates with public PEM material can be used for OVPN provisioning. CMP-issued certificates are recommended because they already contain CA-issued public certificate material.")},
        existing_client_certificates(Certificates, Draft, WizardId, SelectedId)
    ]}.

existing_client_certificates([], _Draft, _WizardId, _SelectedId) ->
    #p{body = ias_html:text("No client certificates exist yet. Issue one below.")};
existing_client_certificates(Certificates, Draft, WizardId, SelectedId) ->
    Ordered = prioritized_client_certificates(Certificates, Draft),
    #panel{style = <<"display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:8px;">>,
           body = [client_certificate_choice(Certificate, Draft, WizardId, SelectedId)
                   || Certificate <- Ordered]}.

prioritized_client_certificates(Certificates, Draft) ->
    DeviceId = maps:get(device_id, Draft, undefined),
    {ForDevice, Other} = lists:partition(
        fun(Certificate) -> issued_for_selected_device(Certificate, DeviceId) end,
        Certificates),
    ForDevice ++ Other.

client_certificate_choice(Certificate, Draft, WizardId, SelectedId) ->
    CertificateId = maps:get(id, Certificate, undefined),
    IsSelected = ias_html:text(CertificateId) =:= ias_html:text(SelectedId),
    Material = ias_certificate_material:status(CertificateId),
    Binding = client_certificate_binding(CertificateId, maps:get(device_id, Draft, undefined)),
    #panel{style = client_choice_style(IsSelected, Material, Binding), body = [
        #panel{style = <<"display:flex;align-items:flex-start;justify-content:space-between;gap:8px;flex-wrap:wrap;margin-bottom:6px;">>,
               body = [
                   #h3{style = <<"margin:0;font-size:14px;overflow-wrap:anywhere;">>,
                       body = ias_html:text(maps:get(subject_cn, Certificate, CertificateId))},
                   client_certificate_badges(Certificate, Material, Binding)
               ]},
        #p{style = <<"margin:0 0 6px;font-size:12px;color:#64748b;overflow-wrap:anywhere;">>,
           body = ias_html:text(CertificateId)},
        #p{style = <<"margin:0 0 4px;font-size:11px;">>,
           body = ias_html:join([<<"Public PEM: ">>, client_material_label(Material)])},
        #p{style = <<"margin:0 0 8px;font-size:11px;">>,
           body = ias_html:join([<<"Device binding: ">>, client_binding_label(Binding)])},
        client_certificate_select_action(IsSelected, Material, Binding, WizardId, CertificateId)
    ]}.

client_certificate_select_action(true, _Material, _Binding, _WizardId, _CertificateId) ->
    #span{style = disabled_action_style(), body = ias_html:text("Selected")};
client_certificate_select_action(false, _Material, {other_device, _}, _WizardId, _CertificateId) ->
    #span{style = disabled_action_style(), body = ias_html:text("Linked elsewhere")};
client_certificate_select_action(false, {ok, #{material_type := client_certificate}}, _Binding, WizardId, CertificateId) ->
    #link{class = [button, sgreen], body = ias_html:text("Select"),
          postback = {wizard_select_client_certificate, WizardId, CertificateId}};
client_certificate_select_action(false, _Material, _Binding, _WizardId, _CertificateId) ->
    #span{style = disabled_action_style(), body = ias_html:text("PEM Required")}.

client_certificate_badges(Certificate, Material, Binding) ->
    #panel{style = <<"display:flex;gap:5px;flex-wrap:wrap;justify-content:flex-end;">>,
           body = client_certificate_badge_items(Certificate, Material, Binding)}.

client_certificate_badge_items(Certificate, Material, Binding) ->
    case Material of
        {ok, #{material_type := client_certificate}} ->
            recommended_client_badges(Certificate, Binding);
        _ ->
            missing_pem_client_badges(Certificate)
    end.

missing_pem_client_badges(Certificate) ->
    DemoBadge = case demo_issued_certificate(Certificate) of
        true ->
            [relationship_badge("Demo Certificate",
                                <<"background:#f8fafc;color:#475569;border-color:#cbd5e1;">>)];
        false ->
            []
    end,
    DemoBadge ++
        [relationship_badge("PEM Missing",
                            <<"background:#fff7ed;color:#9a3412;border-color:#fdba74;">>)].

recommended_client_badges(Certificate, Binding) ->
    case compatible_client_binding(Binding) of
        true ->
            Base0 = [relationship_badge("Recommended",
                                        <<"background:#f0fdf4;color:#166534;border-color:#86efac;">>)],
            Base = case issued_for_binding(Certificate, Binding) of
                true ->
                    Base0 ++ [relationship_badge("Issued for selected Device",
                                                 <<"background:#ecfdf5;color:#047857;border-color:#6ee7b7;">>)];
                false ->
                    Base0
            end,
            case cmp_issued_certificate(Certificate) of
                true ->
                    Base ++ [relationship_badge("Issued by CA",
                                                <<"background:#eff6ff;color:#1d4ed8;border-color:#93c5fd;">>)];
                false ->
                    Base
            end;
        false ->
            []
    end.

compatible_client_binding(unbound) -> true;
compatible_client_binding({selected_device, _DeviceId}) -> true;
compatible_client_binding(_) -> false.

cmp_issued_certificate(#{source := cmp_demo_enrollment}) -> true;
cmp_issued_certificate(#{source := cmp_response}) -> true;
cmp_issued_certificate(_) -> false.

issued_for_selected_device(_Certificate, undefined) ->
    false;
issued_for_selected_device(Certificate, DeviceId) ->
    ias_html:text(maps:get(device_id, Certificate, undefined)) =:= ias_html:text(DeviceId).

issued_for_binding(Certificate, {selected_device, DeviceId}) ->
    issued_for_selected_device(Certificate, DeviceId);
issued_for_binding(_Certificate, _Binding) ->
    false.

demo_issued_certificate(#{source := certificate_issue_demo}) -> true;
demo_issued_certificate(_) -> false.

request_certificate_with_device_csr_panel(Draft) ->
    WizardId = maps:get(id, Draft),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Request Certificate from CA using Device CSR")},
        #p{style = <<"font-size:12px;color:#64748b;line-height:1.45;">>,
           body = ias_html:text("Generate a new key pair and CSR on the Device for each new enrollment. IAS receives only the CSR; the private key never leaves the Device. Existing Device keys must not be reused for new enrollment. Old keys and certificates are not deleted automatically.")},
        safe_device_csr_generation_panel(Draft),
        #panel{style = <<"margin:8px 0;">>, body = [
            #label{for = wizard_device_csr_file,
                   style = <<"display:block;font-weight:600;color:#334155;margin-bottom:4px;">>,
                   body = ias_html:text("Upload .csr / .pem")},
            #input{id = wizard_device_csr_file,
                   type = <<"file">>,
                   accept = <<".csr,.pem,application/pkcs10">>,
                   onchange = device_csr_upload_js()},
            #span{id = wizard_device_csr_file_name,
                  style = <<"display:block;margin-top:4px;font-size:12px;color:#64748b;">>,
                  body = ias_html:text("No file selected")}
        ]},
        #panel{style = <<"margin:8px 0;">>, body = [
            #label{for = wizard_device_csr_pem,
                   style = <<"display:block;font-weight:600;color:#334155;margin-bottom:4px;">>,
                   body = ias_html:text("CSR PEM")},
            #textarea{id = wizard_device_csr_pem, rows = 8,
                      placeholder = <<"-----BEGIN CERTIFICATE REQUEST-----
...
-----END CERTIFICATE REQUEST-----">>,
                      style = <<"width:100%;font-family:monospace;box-sizing:border-box;">>}
        ]},
        #panel{style = <<"margin-top:12px;">>, body = [
            #link{class = [button, sgreen],
                  body = ias_html:text("Request Certificate from CA using Device CSR"),
                  source = [wizard_device_csr_pem, wizard_pending_private_key_ref],
                  postback = {wizard_request_device_csr_certificate, WizardId}}
        ]}
    ]}.

safe_device_csr_generation_panel(Draft) ->
    try device_csr_generation_panel(Draft)
    catch
        Class:Reason:Stack ->
            error_logger:error_msg("Provisioning wizard CSR render failed: ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            wizard_error_panel("Device CSR generation panel is unavailable. The wizard draft was preserved; retry the step or regenerate the plan.")
    end.

device_csr_generation_panel(Draft) ->
    case ias_provisioning_wizard_store:selected_device(Draft) of
        {ok, _Device} ->
            case pending_device_csr_plan(Draft) of
                {ok, Plan} ->
                    device_csr_generation_plan_panel(maps:get(id, Draft), Plan);
                not_found ->
                    device_csr_prepare_panel(maps:get(id, Draft));
                {error, Reason} ->
                    wizard_error_panel(device_csr_error_text(Reason))
            end;
        _ ->
            wizard_error_panel("Select a Device before generating a Device CSR command.")
    end.

pending_device_csr_plan(Draft) ->
    case {maps:get(pending_private_key_reference, Draft, undefined),
          maps:get(pending_csr_filename, Draft, undefined),
          maps:get(pending_enrollment_common_name, Draft, undefined)} of
        {undefined, _, _} -> not_found;
        {<<>>, _, _} -> not_found;
        {KeyRef, CsrFile, CommonName} ->
            case ias_device_key_ref:validate(<<"device_file">>, KeyRef) of
                {ok, #{private_key_ref := SafeKeyRef}} ->
                    {ok, #{private_key_provider => <<"device_file">>,
                           private_key_ref => SafeKeyRef,
                           key_filename => SafeKeyRef,
                           csr_filename => ias_html:text(CsrFile),
                           common_name => ias_html:text(CommonName),
                           script_filename => ias_html:join([
                               ias_html:text(CommonName), <<"-generate-csr.sh">>])}};
                {error, Reason} ->
                    {error, {invalid_private_key_reference, Reason}}
            end
    end.

device_csr_prepare_panel(WizardId) ->
    #panel{style = <<"margin:10px 0;padding:10px;border:1px solid rgba(15,23,42,0.12);border-radius:6px;background:#f8fafc;">>,
           body = [
               #h3{style = <<"margin-top:0;">>,
                   body = ias_html:text("Generate New Device Key and CSR")},
               #p{style = <<"font-size:12px;color:#475569;line-height:1.45;">>,
                  body = ias_html:text("No key rotation plan exists yet. Prepare one explicitly to create stable filenames and a relative Device private-key reference. Refreshing this page will not generate or change a plan.")},
               #link{class = [button, sgreen],
                     body = ias_html:text("Prepare New Device Key and CSR"),
                     postback = {wizard_prepare_device_csr_plan, WizardId}}
           ]}.

device_csr_generation_plan_panel(WizardId, Plan) ->
    Script = ias_device_csr_command:script(Plan),
    CsrFile = maps:get(csr_filename, Plan),
    KeyRef = maps:get(private_key_ref, Plan),
    #panel{style = <<"margin:10px 0;padding:10px;border:1px solid rgba(15,23,42,0.12);border-radius:6px;background:#f8fafc;">>,
           body = [
               #h3{style = <<"margin-top:0;">>, body = ias_html:text("Generate New Device Key and CSR")},
               #p{style = <<"font-size:12px;color:#475569;line-height:1.45;">>,
                  body = ias_html:text("Run this script on the selected Device. It generates a fresh private key and CSR, refuses to overwrite existing files, and verifies the CSR signature. Upload only the generated .csr file to IAS.")},
               key_value_table([
                   {"Pending Private Key Reference", KeyRef},
                   {"CSR File", CsrFile}
               ]),
               #panel{style = <<"margin:8px 0;">>, body = [
                   #label{for = wizard_pending_private_key_ref,
                          style = <<"display:block;font-weight:600;color:#334155;margin-bottom:4px;">>,
                          body = ias_html:text("Confirm Device Private Key Reference")},
                   #input{id = wizard_pending_private_key_ref,
                          type = <<"text">>,
                          value = KeyRef,
                          style = <<"width:100%;box-sizing:border-box;">>}
               ]},
               #pre{id = wizard_device_csr_command,
                    style = <<"margin:8px 0;font-family:monospace;font-size:12px;white-space:pre-wrap;overflow-wrap:anywhere;">>,
                    body = ias_html:text(Script)},
               #panel{style = <<"display:flex;gap:8px;flex-wrap:wrap;margin-top:8px;">>,
                      body = [
                          #link{class = [button, sgreen],
                                url = copy_device_csr_command_js(),
                                body = ias_html:text("Copy Script")},
                          #link{class = [button, sgreen],
                                body = ias_html:text("Download Key and CSR Script"),
                                postback = {wizard_download_device_csr_script, WizardId}},
                          #link{class = [button, more],
                                body = ias_html:text("Generate Another Key and CSR Plan"),
                                postback = {wizard_regenerate_device_csr_plan, WizardId}}
                      ]}
           ]}.

copy_device_csr_command_js() ->
    <<"javascript:(function(){var e=document.getElementById('wizard_device_csr_command');if(e&&navigator.clipboard){navigator.clipboard.writeText(e.textContent||'');}})();">>.

device_csr_upload_js() ->
    <<
        "var file=this.files && this.files[0];",
        "if (!file) { return false; }",
        "var lower=(file.name || '').toLowerCase();",
        "if (!lower.endsWith('.csr') && !lower.endsWith('.pem')) {",
        "alert('Please select a .csr or .pem file.');",
        "this.value='';",
        "return false;",
        "}",
        "var fileName=document.getElementById('wizard_device_csr_file_name');",
        "if (fileName) { fileName.textContent=file.name; }",
        "var reader=new FileReader();",
        "reader.onload=function(e) {",
        "var target=document.getElementById('wizard_device_csr_pem');",
        "if (target) { target.value=e.target.result || ''; }",
        "};",
        "reader.readAsText(file);",
        "return false;"
    >>.

issue_client_certificate_panel(WizardId) ->
    Users = ias_demo_store:users(),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Issue New Demo Client Certificate")},
        #p{style = <<"font-size:12px;color:#64748b;">>,
           body = ias_html:text("Demo issuance creates certificate metadata through the existing issuance service. Paste the returned public certificate PEM; no private key is stored by IAS.")},
        wizard_user_row(Users),
        wizard_input_row("Subject CN", wizard_client_certificate_subject_cn, <<"vpn-client">>),
        #panel{style = <<"margin:8px 0;">>, body = [
            #label{for = wizard_client_certificate_pem,
                   style = <<"display:block;font-weight:600;color:#334155;margin-bottom:4px;">>,
                   body = ias_html:text("Certificate PEM")},
            #textarea{id = wizard_client_certificate_pem, rows = 8,
                      placeholder = <<"-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----">>,
                      style = <<"width:100%;font-family:monospace;box-sizing:border-box;">>}
        ]},
        issue_client_certificate_action(Users, WizardId)
    ]}.

wizard_user_row([]) ->
    wizard_error_panel("No runtime Users are available for demo certificate issuance.");
wizard_user_row(Users) ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>, body = [
        #label{for = wizard_client_certificate_user,
               style = <<"min-width:130px;font-weight:600;color:#334155;">>,
               body = ias_html:text("User")},
        #select{id = wizard_client_certificate_user,
                style = <<"min-width:260px;max-width:420px;width:100%;">>,
                body = [#option{value = ias_html:text(maps:get(id, User)),
                                body = ias_html:text(maps:get(name, User, maps:get(id, User)))}
                        || User <- Users]}
    ]}.

issue_client_certificate_action([], _WizardId) ->
    #span{style = disabled_action_style(), body = ias_html:text("Issue and Select Client Certificate")};
issue_client_certificate_action(_Users, WizardId) ->
    #panel{style = <<"margin-top:12px;">>, body = [
        #link{class = [button, sgreen],
              body = ias_html:text("Issue and Select Client Certificate"),
              source = [wizard_client_certificate_user, wizard_client_certificate_subject_cn,
                        wizard_client_certificate_pem],
              postback = {wizard_issue_client_certificate, WizardId}}
    ]}.

explicit_client_certificate(#{certificate_role := client_certificate}) -> true;
explicit_client_certificate(#{material_type := client_certificate}) -> true;
explicit_client_certificate(#{source := certificate_issue_demo}) -> true;
explicit_client_certificate(#{source := cmp_demo_enrollment}) -> true;
explicit_client_certificate(#{source := ovpn_demo_import}) -> true;
explicit_client_certificate(_) -> false.

selected_client_style({ok, #{material_type := client_certificate}}) ->
    <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>;
selected_client_style(_) ->
    <<"margin-top:12px;padding:12px;border:1px solid rgba(217,119,6,0.25);border-radius:6px;background:#fffbeb;">>.

client_choice_style(true, _Material, _Binding) ->
    <<"padding:12px;border:1px solid rgba(37,99,235,0.35);border-radius:6px;background:#eff6ff;">>;
client_choice_style(false, _Material, {other_device, _}) ->
    <<"padding:12px;border:1px solid rgba(220,38,38,0.22);border-radius:6px;background:#fef2f2;">>;
client_choice_style(false, {ok, #{material_type := client_certificate}}, _Binding) ->
    <<"padding:12px;border:1px solid rgba(22,163,74,0.22);border-radius:6px;background:#fff;">>;
client_choice_style(false, _Material, _Binding) ->
    <<"padding:12px;border:1px solid rgba(217,119,6,0.22);border-radius:6px;background:#fffbeb;">>.

client_material_label({ok, #{material_type := client_certificate}}) -> <<"available">>;
client_material_label(_) -> <<"missing_body">>.

client_material_fingerprint({ok, Status}) -> maps:get(fingerprint_sha256, Status, undefined);
client_material_fingerprint(_) -> undefined.

client_material_notice({ok, #{material_type := client_certificate}}) ->
    wizard_notice("Client material available", "The public client certificate PEM is ready for relationship review.");
client_material_notice(_) ->
    wizard_error_panel("Public client certificate PEM is unavailable. Load material on the certificate detail page or issue a new certificate below.").

client_certificate_device(CertificateId) ->
    case client_certificate_binding(CertificateId, undefined) of
        unbound -> <<"not linked yet">>;
        {selected_device, DeviceId} -> DeviceId;
        {other_device, DeviceId} -> DeviceId
    end.

client_certificate_binding(CertificateId, SelectedDeviceId) ->
    DeviceIds = lists:usort([maps:get(source_id, Relationship, undefined)
                            || Relationship <- ias_demo_store:relationships(),
                               maps:get(relation_type, Relationship, undefined) =:= uses_certificate,
                               maps:get(source_kind, Relationship, undefined) =:= device,
                               maps:get(target_kind, Relationship, undefined) =:= certificate,
                               maps:get(target_id, Relationship, undefined) =:= CertificateId]),
    case DeviceIds of
        [] -> unbound;
        [SelectedDeviceId] when SelectedDeviceId =/= undefined -> {selected_device, SelectedDeviceId};
        [DeviceId | _] -> {other_device, DeviceId}
    end.

client_binding_label(unbound) -> <<"unbound">>;
client_binding_label({selected_device, DeviceId}) -> ias_html:join([<<"selected Device ">>, DeviceId]);
client_binding_label({other_device, DeviceId}) -> ias_html:join([<<"other Device ">>, DeviceId]).

ca_certificate_step(Draft) ->
    #panel{body = [
        ca_trust_anchor_guidance_panel(),
        configured_ca_trust_anchor_panel(maps:get(id, Draft)),
        selected_ca_certificate_panel(Draft),
        existing_ca_certificates_panel(Draft),
        register_ca_certificate_panel(maps:get(id, Draft))
    ]}.

ca_trust_anchor_guidance_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("CA Trust Anchor")},
        #p{style = <<"font-size:12px;color:#475569;line-height:1.45;">>,
           body = ias_html:text("The CA PEM selected here is embedded in the generated OVPN profile <ca> block. The client certificate PEM is selected separately in the next step and is embedded in <cert>.")},
        #panel{style = <<"margin-top:10px;padding:10px;border:1px solid rgba(37,99,235,0.18);border-radius:6px;background:#eff6ff;">>,
               body = [
                   #p{style = <<"margin:0 0 6px;font-weight:600;color:#1e3a8a;">>,
                      body = ias_html:text("SYNRC development CA trust anchor:")},
                   #pre{style = <<"margin:0 0 8px;font-family:monospace;font-size:12px;white-space:pre-wrap;">>,
                        body = ias_html:text("synrc/ecc/secp384r1/ca.pem")},
                   #p{style = <<"margin:0;font-size:12px;color:#334155;line-height:1.45;">>,
                      body = ias_html:text("Upload the public CA certificate only. Never upload ca.key or a client .cer certificate. This path is a SYNRC development-layout hint, not a universal production path.")}
               ]}
    ]}.

configured_ca_trust_anchor_panel(WizardId) ->
    Status = ias_configured_ca_trust_anchor:status(),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Load Configured CA Trust Anchor")},
        #p{style = <<"font-size:12px;color:#475569;line-height:1.45;">>,
           body = ias_html:text("The configured trust anchor is read server-side from IAS application configuration. The resolved filesystem path and PEM body are not displayed or exported.")},
        key_value_table([
            {"Configuration", configured_ca_status_label(Status)},
            {"Configured File", maps:get(display_path, Status, <<"not configured">>)}
        ]),
        configured_ca_action(Status, WizardId),
        #panel{id = wizard_ca_configured_result}
    ]}.

configured_ca_status_label(#{configured := true}) -> <<"configured">>;
configured_ca_status_label(_) -> <<"not configured">>.

configured_ca_action(#{configured := true}, WizardId) ->
    #panel{style = <<"margin-top:12px;">>, body = [
        #link{class = [button, sgreen],
              body = ias_html:text("Load Configured CA Trust Anchor"),
              postback = {wizard_load_configured_ca_trust_anchor, WizardId}}
    ]};
configured_ca_action(_, _WizardId) ->
    #p{style = <<"margin-top:12px;color:#64748b;font-size:12px;">>,
       body = ias_html:text("No configured CA trust anchor is available in sys.config.")}.

selected_ca_certificate_panel(Draft) ->
    case ias_provisioning_wizard_store:selected_ca_certificate(Draft) of
        {ok, Certificate} ->
            CertificateId = maps:get(id, Certificate, undefined),
            Material = ias_certificate_material:status(CertificateId),
            #panel{style = selected_ca_style(Material), body = [
                #h3{body = ias_html:text("Selected CA Trust Anchor")},
                key_value_table([
                    {"Certificate", certificate_link(CertificateId)},
                    {"Name", maps:get(name, Certificate, CertificateId)},
                    {"Subject", maps:get(subject, Certificate, undefined)},
                    {"Status", maps:get(certificate_status, Certificate, undefined)},
                    {"Public PEM", ca_material_label(Material)},
                    {"Fingerprint", ca_material_fingerprint(Material)}
                ]),
                ca_material_notice(Material)
            ]};
        not_selected ->
            wizard_notice("No CA Trust Anchor selected", "Select an existing CA trust anchor with public PEM material or register a new demo CA trust anchor before continuing.");
        {error, selected_ca_certificate_missing} ->
            wizard_error_panel("The CA Trust Anchor stored in this wizard draft no longer exists. Select another CA trust anchor.");
        {error, invalid_ca_certificate} ->
            wizard_error_panel("The selected certificate is not classified as a CA trust anchor.");
        {error, _Reason} ->
            wizard_error_panel("The selected CA Trust Anchor is invalid.")
    end.

existing_ca_certificates_panel(Draft) ->
    Certificates = [Certificate || Certificate <- ias_demo_store:certificates(),
                                   explicit_ca_certificate(Certificate)],
    WizardId = maps:get(id, Draft),
    SelectedId = maps:get(ca_certificate_id, Draft, undefined),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Use Existing CA Trust Anchor")},
        existing_ca_certificates(Certificates, WizardId, SelectedId)
    ]}.

existing_ca_certificates([], _WizardId, _SelectedId) ->
    #p{body = ias_html:text("No explicit CA trust anchors exist yet. Register one below.")};
existing_ca_certificates(Certificates, WizardId, SelectedId) ->
    #panel{style = <<"display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:8px;">>,
           body = [ca_certificate_choice(Certificate, WizardId, SelectedId)
                   || Certificate <- Certificates]}.

ca_certificate_choice(Certificate, WizardId, SelectedId) ->
    CertificateId = maps:get(id, Certificate, undefined),
    IsSelected = ias_html:text(CertificateId) =:= ias_html:text(SelectedId),
    Material = ias_certificate_material:status(CertificateId),
    #panel{style = ca_choice_style(IsSelected, Material), body = [
        #h3{style = <<"margin:0 0 6px;font-size:14px;overflow-wrap:anywhere;">>,
            body = ias_html:text(maps:get(name, Certificate, CertificateId))},
        #p{style = <<"margin:0 0 6px;font-size:12px;color:#64748b;overflow-wrap:anywhere;">>,
           body = ias_html:text(maps:get(subject, Certificate, <<>>))},
        #p{style = <<"margin:0 0 8px;font-size:11px;">>,
           body = ias_html:join([<<"Public PEM: ">>, ca_material_label(Material)])},
        ca_certificate_select_action(IsSelected, Material, WizardId, CertificateId)
    ]}.

ca_certificate_select_action(true, _Material, _WizardId, _CertificateId) ->
    #span{style = disabled_action_style(), body = ias_html:text("Selected")};
ca_certificate_select_action(false, {ok, #{material_type := ca_certificate}}, WizardId, CertificateId) ->
    #link{class = [button, sgreen], body = ias_html:text("Select"),
          postback = {wizard_select_ca_certificate, WizardId, CertificateId}};
ca_certificate_select_action(false, _Material, WizardId, CertificateId) ->
    #link{class = [button, more], body = ias_html:text("Select — PEM required"),
          postback = {wizard_select_ca_certificate, WizardId, CertificateId}}.

register_ca_certificate_panel(WizardId) ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Manual / Demo Override")},
        wizard_input_row("Name", wizard_ca_certificate_name, <<>>),
        wizard_input_row("Subject", wizard_ca_certificate_subject, <<"CN=Demo CA">>),
        #panel{style = <<"margin:8px 0;">>, body = [
            #label{for = wizard_ca_certificate_pem,
                   style = <<"display:block;font-weight:600;color:#334155;margin-bottom:4px;">>,
                   body = ias_html:text("Public CA Certificate PEM")},
            #textarea{id = wizard_ca_certificate_pem, rows = 8,
                      placeholder = <<"-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----">>,
                      style = <<"width:100%;font-family:monospace;box-sizing:border-box;">>}
        ]},
        #panel{style = <<"margin-top:12px;">>, body = [
            #link{class = [button, sgreen],
                  body = ias_html:text("Register and Select CA Trust Anchor"),
                  source = [wizard_ca_certificate_name, wizard_ca_certificate_subject,
                            wizard_ca_certificate_pem],
                  postback = {wizard_register_ca_certificate, WizardId}}
        ]}
    ]}.

explicit_ca_certificate(#{certificate_role := ca_certificate}) -> true;
explicit_ca_certificate(#{material_type := ca_certificate}) -> true;
explicit_ca_certificate(#{source := ca_certificate}) -> true;
explicit_ca_certificate(_) -> false.

selected_ca_style({ok, #{material_type := ca_certificate}}) ->
    <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>;
selected_ca_style(_) ->
    <<"margin-top:12px;padding:12px;border:1px solid rgba(217,119,6,0.25);border-radius:6px;background:#fffbeb;">>.

ca_choice_style(true, _Material) ->
    <<"padding:12px;border:1px solid rgba(37,99,235,0.35);border-radius:6px;background:#eff6ff;">>;
ca_choice_style(false, {ok, #{material_type := ca_certificate}}) ->
    <<"padding:12px;border:1px solid rgba(22,163,74,0.22);border-radius:6px;background:#fff;">>;
ca_choice_style(false, _) ->
    <<"padding:12px;border:1px solid rgba(217,119,6,0.22);border-radius:6px;background:#fffbeb;">>.

ca_material_label({ok, #{material_type := ca_certificate}}) -> <<"available">>;
ca_material_label(_) -> <<"missing_body">>.

ca_material_fingerprint({ok, Status}) -> maps:get(fingerprint_sha256, Status, undefined);
ca_material_fingerprint(_) -> undefined.

ca_material_notice({ok, #{material_type := ca_certificate}}) ->
    wizard_notice("CA trust anchor material available", "The public CA certificate PEM is ready for the generated OVPN <ca> block.");
ca_material_notice(_) ->
    wizard_error_panel("Public CA trust anchor PEM is unavailable. Load material on the certificate detail page or register a new CA trust anchor below.").

configured_ca_error_text(not_configured) ->
    <<"Configured CA trust anchor is not configured.">>;
configured_ca_error_text(file_not_found) ->
    <<"Configured CA trust anchor file was not found.">>;
configured_ca_error_text(permission_denied) ->
    <<"Configured CA trust anchor file is not readable.">>;
configured_ca_error_text(invalid_pem) ->
    <<"Configured CA trust anchor is not a valid certificate PEM.">>;
configured_ca_error_text(private_key_supplied) ->
    <<"Configured CA trust anchor points to private key material. Upload the public CA certificate only.">>;
configured_ca_error_text(certificate_is_not_ca) ->
    <<"Configured certificate is not a CA trust anchor.">>;
configured_ca_error_text(certificate_expired) ->
    <<"Configured CA trust anchor certificate is expired.">>;
configured_ca_error_text({read_failed, Reason}) ->
    ias_html:join([<<"Configured CA trust anchor could not be read: ">>,
                   ias_html:text(Reason)]);
configured_ca_error_text({material_store_failed, Reason}) ->
    ias_html:join([<<"Configured CA trust anchor material could not be stored: ">>,
                   ias_html:text(Reason)]);
configured_ca_error_text(Reason) ->
    ias_html:text(Reason).

device_csr_error_text(malformed_csr) ->
    <<"Malformed PKCS#10 CSR PEM.">>;
device_csr_error_text(exactly_one_csr_required) ->
    <<"Exactly one PKCS#10 CSR PEM is required.">>;
device_csr_error_text(private_key_supplied) ->
    <<"Private key material was supplied. Submit only client.csr.">>;
device_csr_error_text(csr_signature_invalid) ->
    <<"CSR signature verification failed. Regenerate the CSR on the Device.">>;
device_csr_error_text(unsafe_subject) ->
    <<"CSR subject is missing or contains unsafe characters.">>;
device_csr_error_text(unsafe_device_metadata) ->
    <<"Selected Device metadata contains unsafe characters for CSR script generation. Rename the Device before generating a key and CSR script.">>;
device_csr_error_text(certificate_csr_public_key_mismatch) ->
    <<"Issued certificate public key does not match the submitted CSR.">>;
device_csr_error_text(private_key_reference_required) ->
    <<"Confirm the relative Device private key reference before submitting the CSR.">>;
device_csr_error_text({invalid_private_key_reference, Reason}) ->
    ias_html:join([<<"Device private key reference is invalid: ">>, ias_html:text(Reason)]);
device_csr_error_text({csr_plan_failed, _Reason}) ->
    <<"Device key and CSR plan could not be prepared. The wizard draft was preserved; retry the step or check the server log.">>;
device_csr_error_text({invalid_certificate_chain, _Reason}) ->
    <<"Issued certificate does not validate against the configured CA trust anchor.">>;
device_csr_error_text({configured_ca_unavailable, Reason}) ->
    ias_html:join([<<"Configured CA trust anchor is unavailable: ">>,
                   configured_ca_error_text(Reason)]);
device_csr_error_text({cmp_failed, ca_unavailable}) ->
    <<"CA/CMP service is unavailable.">>;
device_csr_error_text({duplicate_csr, _Record}) ->
    <<"This CSR has already been submitted. Generate a new CSR on the Device and try again. Do not resubmit the same CSR.">>;
device_csr_error_text({reused_public_key, _Record}) ->
    <<"This public key has already been used for enrollment. Generate a new Device key and CSR, then try again.">>;
device_csr_error_text({cmp_failed, cmp_unexpected_certificate_response}) ->
    <<"CMP did not return the expected certificate response. This may indicate key reuse or CA rejection. Generate a new Device key and CSR, then try again.">>;
device_csr_error_text({cmp_failed, cmp_connection_failed}) ->
    <<"CMP connection failed. Check that the CA/CMP service is running and reachable.">>;
device_csr_error_text({cmp_failed, cmp_timeout}) ->
    <<"CMP enrollment timed out. Check CA/CMP availability and retry only if the previous request did not reach the CA.">>;
device_csr_error_text({cmp_failed, cmp_malformed_response}) ->
    <<"CMP returned a malformed response. Generate a new Device CSR and try again after checking the CA/CMP service.">>;
device_csr_error_text({cmp_failed, cmp_ca_rejection}) ->
    <<"CA rejected the CMP request. Generate a new Device CSR or check CA enrollment policy.">>;
device_csr_error_text({cmp_failed, cmp_failed}) ->
    <<"CA/CMP enrollment failed. Generate a new Device CSR and try again.">>;
device_csr_error_text({cmp_failed, Reason}) ->
    device_csr_error_text({cmp_failed, ias_device_csr_enrollment:normalize_cmp_error(Reason)});
device_csr_error_text(device_required) ->
    <<"Select a Device before requesting a certificate with a Device CSR.">>;
device_csr_error_text(Reason) ->
    ias_html:text(Reason).

certificate_link(undefined) -> undefined;
certificate_link(CertificateId) ->
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, ias_html:text(CertificateId)]),
          body = ias_html:text(CertificateId)}.

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
                           {"Derived Policy", derived_policy_label(Draft)},
                           {"Policy Applies To", <<"Device, Client Certificate">>},
                           {"Relationship Commit", <<"Automatic after Client Certificate">>},
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

derived_policy_label(Draft) ->
    case ias_provisioning_wizard_authorization:derived_policy(Draft) of
        {ok, Policy} -> ias_security_profile:profile_label(Policy);
        {error, _Reason} -> <<"unavailable">>
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
                           {"Endpoint", maps:get(endpoint, Device, undefined)},
                           {"Private Key Provider", maps:get(private_key_provider, Device, undefined)},
                           {"Private Key Reference", maps:get(private_key_ref, Device, undefined)}
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
                                 maps:get(endpoint, Device, <<"">>), <<" / key ">>,
                                 maps:get(private_key_ref, Device, <<"missing">>)])},
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
        wizard_input_row("Private Key Provider", wizard_device_private_key_provider, <<"device_file">>),
        wizard_input_row("Private Key Reference", wizard_device_private_key_ref, <<"client.key">>),
        #panel{style = <<"margin-top:12px;">>, body = [
            #link{class = [button, sgreen],
                  body = ias_html:text("Create and Select Device"),
                  source = [wizard_device_name, wizard_device_type,
                            wizard_device_tunnel_device, wizard_device_transport,
                            wizard_device_endpoint, wizard_device_private_key_provider,
                            wizard_device_private_key_ref],
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
wizard_error(ca_certificate_required) ->
    wizard_error_panel("Select or register a CA Certificate before continuing.");
wizard_error(selected_ca_certificate_missing) ->
    wizard_error_panel("The selected CA Certificate no longer exists. Select another CA certificate.");
wizard_error(invalid_ca_certificate) ->
    wizard_error_panel("The selected certificate is not classified as a CA certificate.");
wizard_error(ca_certificate_material_required) ->
    wizard_error_panel("Public CA certificate PEM is required before continuing.");
wizard_error(client_certificate_required) ->
    wizard_error_panel("Select or issue a Client Certificate before continuing.");
wizard_error(selected_client_certificate_missing) ->
    wizard_error_panel("The selected Client Certificate no longer exists. Select another certificate.");
wizard_error(invalid_client_certificate) ->
    wizard_error_panel("The selected certificate is not classified as a client certificate.");
wizard_error(client_certificate_material_required) ->
    wizard_error_panel("Public client certificate PEM is required before continuing.");
wizard_error(client_certificate_linked_to_other_device) ->
    wizard_error_panel("The selected Client Certificate is already linked to another Device.");
wizard_error(relationships_not_applied) ->
    wizard_error_panel("Apply all required relationships before continuing to Material Readiness.");
wizard_error(material_readiness_blocked) ->
    wizard_error_panel("Material readiness is blocked. Resolve the failed checks before continuing to Provisioning.");
wizard_error(provisioning_transaction_missing) ->
    wizard_error_panel("The provisioning transaction stored in this wizard draft no longer exists. Create a replacement transaction.");
wizard_error(provisioning_reference_mismatch) ->
    wizard_error_panel("Provisioning references no longer match the wizard selections. Review relationships and readiness before retrying.");
wizard_error({relationship_preflight_failed, _Review}) ->
    wizard_error_panel("Relationship preflight failed. Resolve conflicts or stale selections before applying the graph.");
wizard_error({relationship_apply_failed, Key, Reason}) ->
    wizard_error_panel(ias_html:join([<<"Relationship apply failed for ">>, Key, <<": ">>,
                                      relationship_error_text(Reason)]));
wizard_error({relationship_apply_incomplete, _Review}) ->
    wizard_error_panel("Relationships were not fully applied. Review the graph and try again.");
wizard_error(Reason) ->
    wizard_error_panel(Reason).

relationship_error_text(#{message := Message}) -> ias_html:text(Message);
relationship_error_text(Reason) when is_binary(Reason); is_atom(Reason);
                                     is_integer(Reason); is_float(Reason);
                                     is_list(Reason) ->
    ias_html:text(Reason);
relationship_error_text(Reason) ->
    iolist_to_binary(io_lib:format("~tp", [Reason])).

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
next_action(#{current_step := ca_certificate} = Draft, WizardId) ->
    case ias_provisioning_wizard_store:selected_ca_certificate(Draft) of
        {ok, Certificate} ->
            case ias_certificate_material:status(maps:get(id, Certificate)) of
                {ok, #{material_type := ca_certificate}} -> nav_action("Next", {wizard_next, WizardId});
                _ -> #span{style = disabled_action_style(), body = ias_html:text("Next")}
            end;
        _ -> #span{style = disabled_action_style(), body = ias_html:text("Next")}
    end;
next_action(#{current_step := client_certificate} = Draft, WizardId) ->
    case ias_provisioning_wizard_store:selected_client_certificate(Draft) of
        {ok, Certificate} ->
            case ias_certificate_material:status(maps:get(id, Certificate)) of
                {ok, #{material_type := client_certificate}} -> nav_action("Next", {wizard_next, WizardId});
                _ -> #span{style = disabled_action_style(), body = ias_html:text("Next")}
            end;
        _ -> #span{style = disabled_action_style(), body = ias_html:text("Next")}
    end;
next_action(#{current_step := relationships} = Draft, WizardId) ->
    case ias_provisioning_wizard_store:relationships_ready(Draft) of
        true -> nav_action("Next", {wizard_next, WizardId});
        false -> #span{style = disabled_action_style(), body = ias_html:text("Next")}
    end;
next_action(#{current_step := material_readiness} = Draft, WizardId) ->
    case ias_provisioning_wizard_store:material_readiness_ready(Draft) of
        true -> nav_action("Next", {wizard_next, WizardId});
        false -> #span{style = disabled_action_style(), body = ias_html:text("Next")}
    end;
next_action(#{current_step := provisioning, completed := true}, _WizardId) ->
    #span{style = disabled_action_style(), body = ias_html:text("Completed")};
next_action(#{current_step := provisioning}, _WizardId) ->
    #span{style = disabled_action_style(), body = ias_html:text("Final Step")};
next_action(_Draft, WizardId) ->
    nav_action("Next", {wizard_next, WizardId}).

boundary_note(scheme) ->
    #span{style = note_style(),
          body = ias_html:text("Select or keep the device-bound scenario before continuing.")};
boundary_note(client_certificate) ->
    #span{style = note_style(),
          body = ias_html:text("Next runs relationship preflight automatically and continues directly to Material Readiness when the graph can be committed safely.")};
boundary_note(relationships) ->
    #span{style = note_style(),
          body = ias_html:text("This review is shown when automatic relationship commit needs conflict resolution or a retry.")};
boundary_note(provisioning) ->
    #span{style = note_style(),
          body = ias_html:text("Provisioning creation is explicit and idempotent. Existing transactions are reused unless Create Another Transaction is chosen.")};
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

step_state(Step, Draft) ->
    CurrentStep = maps:get(current_step, Draft, scheme),
    StepIndex = index_of(Step),
    CurrentIndex = index_of(CurrentStep),
    case Step of
        relationships when StepIndex < CurrentIndex ->
            case ias_provisioning_wizard_store:relationships_ready(Draft) of
                true -> completed;
                false -> blocked
            end;
        material_readiness when StepIndex < CurrentIndex ->
            case ias_provisioning_wizard_store:material_readiness_ready(Draft) of
                true -> completed;
                false -> blocked
            end;
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

wizard_download_device_bound_ovpn({ok, #{filename := Filename, body := Content,
                                          private_key_ref := KeyRef}}) ->
    nitro:update(wizard_ovpn_download_result,
                 wizard_device_bound_ovpn_ready(Filename, Content, KeyRef)),
    nitro:wire(wizard_ovpn_download_js(Filename, Content));
wizard_download_device_bound_ovpn({error, Reason}) ->
    nitro:update(wizard_ovpn_download_result,
                 wizard_device_bound_ovpn_error(Reason)).

wizard_download_device_csr_script(WizardId) ->
    case ias_provisioning_wizard_store:get(WizardId) of
        {ok, Draft} ->
            case pending_device_csr_plan(Draft) of
                {ok, Plan} ->
                    Script = ias_device_csr_command:script(Plan),
                    Filename = maps:get(script_filename, Plan),
                    nitro:wire(wizard_download_js(
                        Filename, Script, <<"text/x-shellscript">>));
                not_found ->
                    nitro:update(wizard_feedback, wizard_error(private_key_reference_required));
                {error, Reason} ->
                    nitro:update(wizard_feedback, wizard_error(device_csr_error_text(Reason)))
            end;
        not_found ->
            nitro:update(wizard_feedback, wizard_error(not_found))
    end.

wizard_device_bound_ovpn_ready(Filename, Content, KeyRef) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("Device-bound OVPN ready")},
               #p{body = ias_html:join([
                   <<"This profile references a private key already stored on the device: ">>,
                   ias_html:text(KeyRef)])},
               key_value_table([
                   {"Filename", Filename},
                   {"Bytes", byte_size(Content)}
               ])
           ]}.

wizard_device_bound_ovpn_error(Reason) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;">>,
           body = [
               #h3{body = ias_html:text("Device-bound OVPN unavailable")},
               key_value_table([
                   {"Reason", Reason}
               ])
           ]}.

wizard_ovpn_download_js(Filename, Content) ->
    wizard_download_js(Filename, Content, <<"application/x-openvpn-profile">>).

wizard_download_js(Filename, Content, ContentType) ->
    Encoded = base64:encode(Content),
    SafeFilename = js_string(Filename),
    SafeContentType = js_string(ContentType),
    [
        <<"var data=atob('">>, Encoded, <<"');">>,
        <<"var blob=new Blob([data],{type:'">>, SafeContentType, <<"'});">>,
        <<"var url=URL.createObjectURL(blob);">>,
        <<"var a=document.createElement('a');">>,
        <<"a.href=url;">>,
        <<"a.download='">>, SafeFilename, <<"';">>,
        <<"document.body.appendChild(a);">>,
        <<"a.click();">>,
        <<"document.body.removeChild(a);">>,
        <<"URL.revokeObjectURL(url);">>
    ].

js_string(Value) ->
    Text = ias_html:text(Value),
    << <<(js_string_char(Char))/binary>> || <<Char>> <= Text >>.

js_string_char($\\) -> <<"\\\\">>;
js_string_char($') -> <<"\\'">>;
js_string_char($\n) -> <<"\\n">>;
js_string_char($\r) -> <<"\\r">>;
js_string_char(Char) -> <<Char>>.

redirect_after({ok, Draft}) ->
    nitro:redirect(wizard_url(maps:get(id, Draft)));
redirect_after({error, _Reason}) ->
    nitro:redirect(start_url()).

redirect_after_device_csr_plan(Fun) ->
    try Fun() of
        {ok, Draft} ->
            nitro:redirect(wizard_url(maps:get(id, Draft)));
        {error, Reason} ->
            nitro:update(wizard_feedback,
                         wizard_error(device_csr_error_text(Reason)))
    catch
        Class:Reason:Stack ->
            error_logger:error_msg("Provisioning wizard CSR plan preparation failed: ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            nitro:update(wizard_feedback,
                         wizard_error(device_csr_error_text({csr_plan_failed, Reason})))
    end.

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
