-module(ias_certificates).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(register_ca_certificate) ->
    Fields = #{name => nitro:q(ca_certificate_name),
               subject => nitro:q(ca_certificate_subject),
               pem => nitro:q(ca_certificate_pem)},
    Result = ias_demo_ca_certificate:register(Fields),
    nitro:update(ca_certificate_register_result, register_result(Result)),
    nitro:update(certificate_runtime_objects, imported_demo_objects());
event(_) ->
    ok.

content() ->
    VpnSummary = ias_vpn_runtime:summary(),
    Peers = ias_vpn_runtime:peers(VpnSummary),
    Devices = ias_demo_data:devices(),
    Certificates = ias_demo_data:certificates(),
    Profiles = ias_demo_data:profiles(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = ias_html:text("Certificates")},
        #p{body = ias_html:text("Review live VPN certificate metadata from the VPN admin API.")},
        #h3{body = count("Certificates", Peers)},
        status(VpnSummary),
        table([
            #table{class = <<"ias-table">>,
                   header = header(["Peer", "Subject CN", "Issuer CN", "Valid From",
                                    "Valid To", "Trusted", "Key Match", "Security Profile",
                                    "Claims"]),
                   body = #tbody{body =
                       [certificate_row(Peer, Devices, Certificates, Profiles) || Peer <- Peers]}}
        ]),
        register_ca_certificate_panel(),
        #panel{id = certificate_runtime_objects, body = imported_demo_objects()}
    ]}.

status({error, _Reason}) ->
    #panel{class = <<"ias-status-card">>, body = ias_html:text("VPN certificate metadata unavailable.")};
status(_VpnSummary) ->
    [].

register_ca_certificate_panel() ->
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Register Demo CA Certificate")},
        #p{style = <<"font-size:12px;margin:0 0 10px;color:#64748b;">>,
           body = ias_html:text("Registers CA certificate metadata in demo runtime state and stores public PEM material separately.")},
        input_row("Name", ca_certificate_name, <<"">>),
        input_row("Subject", ca_certificate_subject, <<"CN=Demo CA">>),
        #panel{style = <<"margin:8px 0;">>, body = [
            #label{for = ca_certificate_pem,
                   style = <<"display:block;font-weight:600;color:#334155;margin-bottom:4px;">>,
                   body = ias_html:text("Certificate PEM")},
            #textarea{id = ca_certificate_pem,
                      rows = 8,
                      placeholder = <<"-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----">>,
                      style = <<"width:100%;font-family:monospace;box-sizing:border-box;">>}
        ]},
        #panel{style = <<"margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">>,
               body = [
                   #link{id = ca_certificate_register_button,
                         class = [button, sgreen],
                         body = ias_html:text("Register CA Certificate"),
                         source = [ca_certificate_name, ca_certificate_subject,
                                   ca_certificate_pem],
                         postback = register_ca_certificate},
                   #span{style = <<"font-size:12px;color:#64748b;">>,
                         body = ias_html:text("Demo runtime only. PEM is stored in the volatile public material store, not in metadata.")}
               ]},
        #panel{id = ca_certificate_register_result}
    ]}.

input_row(Label, Id, Value) ->
    #panel{style = <<"display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0;">>,
           body = [
               #label{for = Id,
                      style = <<"min-width:130px;font-weight:600;color:#334155;">>,
                      body = ias_html:text(Label)},
               #input{id = Id,
                      type = <<"text">>,
                      value = ias_html:text(Value),
                      style = <<"min-width:260px;max-width:420px;width:100%;">>}
           ]}.

register_result({ok, Certificate}) ->
    Id = maps:get(id, Certificate, undefined),
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(22,163,74,0.25);border-radius:6px;background:#f0fdf4;">>,
           body = [
               #h3{body = ias_html:text("CA certificate registered")},
               key_value_table([
                   {"Certificate", demo_link(Id)},
                   {"Source", maps:get(source, Certificate, undefined)},
                   {"Material Role", maps:get(material_type, Certificate, undefined)}
               ])
           ]};
register_result({error, Reason}) ->
    #panel{style = <<"margin-top:12px;padding:12px;border:1px solid rgba(220,38,38,0.25);border-radius:6px;background:#fef2f2;color:#991b1b;">>,
           body = [
               #h3{body = ias_html:text("CA certificate was not registered")},
               #p{body = ias_html:text(Reason)}
           ]}.

certificate_row(Peer, Devices, Certificates, Profiles) ->
    ProfileId = profile_id(Peer, Devices, Certificates),
    row([ias_vpn_runtime:field(Peer, [<<"id">>, id, peer, name]),
         ias_vpn_runtime:certificate_field(Peer, [subject_cn]),
         ias_vpn_runtime:certificate_field(Peer, [issuer_cn]),
         ias_vpn_runtime:certificate_field(Peer, [not_before]),
         ias_vpn_runtime:certificate_field(Peer, [not_after]),
         ias_vpn_runtime:certificate_field(Peer, [trusted]),
         ias_vpn_runtime:certificate_field(Peer, [key_match]),
         ProfileId,
         claims(ProfileId, Profiles)]).

claims(undefined, _Profiles) ->
    undefined;
claims(ProfileId, Profiles) ->
    Profile = profile(ProfileId, Profiles),
    ias_policy:format_claims(ias_policy:certificate_claims(Profile)).

profile_id(Peer, Devices, Certificates) ->
    PeerId = ias_vpn_runtime:field(Peer, [<<"id">>, id, peer, name]),
    case certificate_for_peer(PeerId, Certificates) of
        #{profile_id := ProfileId} ->
            ProfileId;
        _ ->
            device_profile_id(PeerId, Devices)
    end.

certificate_for_peer(undefined, _Certificates) ->
    #{};
certificate_for_peer(PeerId, Certificates) ->
    case [Certificate || Certificate <- Certificates,
                         maps:get(vpn_peer, Certificate, undefined) =:= PeerId] of
        [Certificate | _] -> Certificate;
        [] -> #{}
    end.

device_profile_id(undefined, _Devices) ->
    undefined;
device_profile_id(PeerId, Devices) ->
    case [Device || Device <- Devices,
                    maps:get(vpn_peer, Device, undefined) =:= PeerId] of
        [#{profile_id := ProfileId} | _] -> ProfileId;
        _ -> undefined
    end.

profile(undefined, _Profiles) ->
    #{};
profile(ProfileId, Profiles) ->
    case [Profile || Profile <- Profiles, maps:get(id, Profile) =:= ProfileId] of
        [Profile | _] -> Profile;
        [] -> #{}
    end.

header(Columns) ->
    [#tr{cells = [#th{body = ias_html:text(Column)} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = cell_body(Value)} || Value <- Values]}.

cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

imported_demo_objects() ->
    Records = ias_demo_store:certificates(),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Runtime Demo Objects")},
        imported_certificates(Records)
    ]}.

imported_certificates([]) ->
    #p{body = ias_html:text("No imported demo objects yet.")};
imported_certificates(Records) ->
    table([
        #table{class = <<"ias-table">>,
               header = header(["ID", "Subject", "Issuer", "CA", "Client Certificate",
                                "Private Key Present", "Private Key Stored", "TLS Auth",
                                "Source", "Import ID"]),
               body = #tbody{body = [imported_certificate_row(Record) || Record <- Records]}}
    ]).

imported_certificate_row(Record) ->
    row([demo_link(maps:get(id, Record, undefined)),
         maps:get(subject, Record, <<"not found">>),
         maps:get(issuer, Record, <<"not found">>),
         maps:get(ca_present, Record, false),
         maps:get(client_certificate_present, Record, false),
         maps:get(private_key_present, Record, false),
         maps:get(private_key_stored, Record, false),
         maps:get(tls_auth_present, Record, false),
         maps:get(source, Record, undefined),
         maps:get(import_id, Record, undefined)]).

demo_link(undefined) ->
    undefined;
demo_link(Id) ->
    TextId = ias_html:text(Id),
    #link{url = ias_html:join([<<"/app/demo.htm?id=">>, TextId]),
          body = TextId}.

table(Body) ->
    #panel{class = <<"ias-table-container">>, body = Body}.

count(Label, Rows) ->
    ias_html:join([Label, ": ", integer_to_list(length(Rows))]).

key_value_table(Rows) ->
    table([
        #table{class = <<"ias-table">>,
               body = #tbody{body = [key_value_row(Label, Value) || {Label, Value} <- Rows]}}
    ]).

key_value_row(Label, Value) ->
    #tr{cells = [
        #th{body = ias_html:text(Label)},
        #td{body = cell_body(Value)}
    ]}.
