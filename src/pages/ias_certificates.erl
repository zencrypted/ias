-module(ias_certificates).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, content());
event(_) ->
    ok.

content() ->
    VpnSummary = ias_vpn_runtime:summary(),
    Peers = ias_vpn_runtime:peers(VpnSummary),
    Devices = ias_demo_data:devices(),
    Certificates = ias_demo_data:certificates(),
    Profiles = ias_demo_data:profiles(),
    #panel{class = <<"ias-placeholder">>, body = [
        #h2{body = "Certificates"},
        #p{body = "Review live VPN certificate metadata from the VPN admin API."},
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
        imported_demo_objects()
    ]}.

status({error, _Reason}) ->
    #panel{class = <<"ias-status-card">>, body = "VPN certificate metadata unavailable."};
status(_VpnSummary) ->
    [].

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
    [#tr{cells = [#th{body = Column} || Column <- Columns]}].

row(Values) ->
    #tr{cells = [#td{body = cell_body(Value)} || Value <- Values]}.

cell_body(#link{} = Link) ->
    Link;
cell_body(Value) ->
    ias_html:text(Value).

imported_demo_objects() ->
    Records = ias_demo_store:certificates(),
    #panel{class = <<"ias-status-card">>, body = [
        #h3{body = ias_html:text("Imported Demo Objects")},
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
    [Label, ": ", integer_to_list(length(Rows))].
