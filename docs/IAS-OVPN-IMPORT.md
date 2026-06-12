OVPN Import Preview
===================

Purpose
-------

The OVPN Import Preview workflow provides a read-only bridge between an
OpenVPN client configuration and the IAS domain model.

Flow
----

OVPN
-> Extracted Config
-> IAS Device Preview
-> IAS Certificate Preview
-> VPN Service Preview
-> Import Plan Preview

The workflow is intended for analysis and planning only.

Current Behavior
----------------

The preview may:

* Load .ovpn content from paste or file upload.
* Extract common OpenVPN configuration properties.
* Build IAS-oriented preview objects.
* Show a proposed import plan.

The preview does not modify IAS state.

Non-Goals
---------

The preview does not:

* Persist imported data.
* Create Devices.
* Create Certificates.
* Create VPN Services.
* Start VPN connections.
* Call CA services.
* Call LDAP services.

Future Direction
----------------

A future controlled import workflow may transform preview objects into
IAS domain entities after explicit user confirmation.

The preview stage exists to validate mappings before any state-changing
operation is introduced.
