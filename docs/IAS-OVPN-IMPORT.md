OVPN Import Preview and Demo Store
==================================

Purpose
-------

The OVPN workflow is a Live Runtime Mode bridge between an OpenVPN client
configuration and the IAS domain model. It deliberately separates read-only
analysis from an explicit, non-production demo state change.

Runtime Flow
------------

Read-only path:

OVPN
-> Extracted Config
-> IAS Device Preview
-> IAS Certificate Preview
-> VPN Service Preview
-> Import Plan Preview

Explicit demo path:

Import Plan Preview
-> Sanitize extracted metadata
-> Store demo Device, Certificate metadata and VPN Service objects
-> Volatile ETS demo state

Current Behavior
----------------

The live page may:

* Load `.ovpn` content from paste or a file selected with the `.ovpn` filter.
* Automatically preview a selected file.
* Extract common OpenVPN configuration properties.
* Build IAS-oriented Device, Certificate and VPN Service previews.
* Generate a read-only import plan without changing runtime state.
* Store sanitized demo objects in ETS only after the explicit
  `Store Demo Objects` action.
* Expose the stored demo objects through the Devices, Certificates and Services
  runtime pages.

The preview and import-plan actions are read-only. The demo-store action is the
only state-changing action in this workflow.

Demo State Boundary
-------------------

The demo-store action is not a production OVPN import.

* State is node-local and volatile.
* State is lost when the ETS table is cleared or the Erlang runtime stops.
* The original `.ovpn` document is not persisted.
* CA, certificate, private-key and TLS-auth bodies are not persisted.
* Private-key presence may be recorded, but `private_key_stored` is always
  `false`.
* No VPN tunnel is started and no OpenVPN client configuration is installed.
* No CA, LDAP or external VPN service is called.

Terminology
-----------

`Preview` and `Generate Import Plan` mean that no runtime state changes are
made.

`Store Demo Objects` means that sanitized metadata is written to volatile ETS
demo state. It must not be described as a real import, provisioning operation or
secret installation.

Non-Goals
---------

The current workflow does not:

* Persist production IAS entities.
* Persist private keys or complete certificate material.
* Install or activate an OpenVPN configuration.
* Start VPN connections.
* Call CA services.
* Call LDAP services.
* Authorize production access.

Future Direction
----------------

A controlled production import may later transform a validated import plan into
persistent IAS domain entities after explicit authorization. Secret handling,
validation, audit, rollback and VPN activation semantics must be defined before
that state-changing workflow is introduced.
