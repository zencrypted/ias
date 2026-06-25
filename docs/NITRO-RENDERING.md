# Nitro Rendering Rules

IAS pages should keep text rendering explicit before values are passed to Nitro
records or websocket DOM actions.

## Text Values

- Convert atoms before rendering. Use `ias_html:text/1` or
  `atom_to_binary(Value, utf8)`.
- Collapse mixed text into one binary before assigning it to an element body.
  Use `ias_html:join/1`.
- Join lists of atom or binary values with `ias_html:join_csv/1`.
- Do not pass mixed text iolists such as
  `[default_user, " - ", <<"Default User">>]` directly to Nitro.

## Element Bodies

- A list used as a Nitro element body means child elements or child body items.
- Use lists only when the body intentionally contains multiple Nitro elements.
- If the value is text, collapse it to a binary first.

## Render Lifecycle

- Build Nitro record trees without mutating ETS or creating domain state.
- Do not call `nitro:render/1` merely to validate a page before returning the
  same tree to Nitro. DOM actions render the tree later; manual pre-rendering can
  register postbacks or alter render state twice.
- `event(init)` should enqueue the page once through the normal Nitro insertion
  path. Render helpers must remain deterministic for the same runtime state.
- Catch page-tree construction failures where useful, but remember that final
  serialization and browser-side JavaScript execution may happen after the page
  callback returns.

## Websocket and JavaScript Safety

- HTML manually embedded into JavaScript must be escaped for the JavaScript
  context, for example with `nitro:js_escape/1` when appropriate.
- Nitro DOM insertion serializes rendered HTML inside a JavaScript template
  literal. HTML escaping alone is therefore not sufficient for arbitrary
  generated text.
- Dynamic shell/configuration text rendered through that path must neutralize
  characters that can change template-literal parsing:

```text
$  -> &#36;
\  -> &#92;
`  -> &#96;
```

  in addition to normal HTML metacharacters (`&`, `<`, `>`, `"`, `'`). The
  browser decodes the numeric entities back to the original visible text after
  assigning `innerHTML`.
- A raw shell expansion such as `${OPENSSL3:-openssl}` inside rendered HTML can
  otherwise be parsed as JavaScript template interpolation and prevent the whole
  Nitro DOM update from executing, leaving the static loading placeholder on the
  page even though every server callback returned successfully.
- Keep regression tests for multiline text, `${...}`, backticks and shell line
  continuation backslashes whenever a page renders generated scripts or configs.

## Diagnostics

When a live page remains on its static loading placeholder:

1. trace the page event, state update, `event(init)`, content construction and
   Nitro insertion on the server;
2. verify whether all server functions returned normally;
3. inspect the browser console for a JavaScript parse/runtime error;
4. inspect the generated websocket action for unescaped dynamic text.

A successful server trace does not prove that the browser executed the returned
Nitro command.

## Dynamic Interactive Fragments

Nitro DOM updates carry two outputs, not only rendered HTML. In the current Nitro
implementation, `nitro:update/2`:

1. renders the supplied Nitro element tree with `render_html/1`;
2. captures the actions registered while that tree is rendered;
3. replaces the target element with `outerHTML`;
4. executes the captured actions, including postback event listeners.

This behavior is visible in Nitro `src/nitro.erl`, while link ID and event
registration are implemented in `src/elements/input/element_link.erl` and
`src/actions/action_event.erl`.

A `#link{postback = ...}` follows the same contract. Its renderer chooses the
link ID, registers a click `#event` for that ID, and emits the `<a>` element.
Nitro generates a temporary ID when none is supplied, so an explicit ID is not a
framework requirement. IAS nevertheless requires explicit, unique IDs for
interactive controls inside fragments that can be refreshed. Stable IDs make
repeated rendering deterministic to inspect and prevent duplicate or ambiguous
controls in lists and tables.

### Preserve the replacement target

`nitro:update(Target, Elements)` replaces the target element itself, not only its
children. The root element returned by `Elements` must therefore preserve the
same ID when the fragment is expected to be updated again:

```erlang
vpn_access_container(Body) ->
    #panel{id = device_vpn_access, body = Body}.

refresh_vpn_access(Body) ->
    nitro:update(device_vpn_access, vpn_access_container(Body)).
```

If the replacement root does not contain `id = device_vpn_access`, the first
update can succeed, but a later update silently finds no target.

### Render records, not pre-rendered HTML

Interactive children must be supplied to `nitro:update/2` as Nitro records so
that their postback actions are captured during `render_html/1`:

```erlang
nitro:update(fragment_id,
             #panel{id = fragment_id,
                    body = [#link{id = action_id,
                                  postback = do_action,
                                  body = <<"Run">>}]}).
```

Do not pre-render the fragment with `nitro:render/1`, insert a raw HTML binary,
or assign equivalent markup through manual `innerHTML`. Those approaches can
make the control visible without returning the event-listener actions needed to
make its postback work.

### Give dynamic controls unique IDs

Use an ID that contains both the operation and the entity identity whenever the
same control can appear in repeated rows or multiple live fragments:

```erlang
incident_action_id(resolve, DeviceId) ->
    ias_html:join([<<"vpn_incident_resolve_">>, DeviceId]).
```

A fixed atom ID is suitable only when exactly one such control can exist on the
page. The device VPN lifecycle panel uses fixed IDs because one device detail is
rendered at a time. The provisioning wizard includes `WizardId` in lifecycle
action IDs because those controls belong to a particular wizard transaction.

Controls that use `source = [...]` must reference unique, stable input IDs. The
source elements must still exist when the click occurs; replacing or duplicating
them can produce missing or wrong values.

### Avoid overlapping fragment replacements

Do not update a child fragment and then replace its ancestor in the same server
response. A later ancestor `outerHTML` replacement discards the child DOM nodes
and any listeners just attached to them. Prefer one coherent update of the
outermost fragment, or update independent, non-overlapping targets.

### Keep backend push separate from editable interactive fragments

A runtime notification must not replace a fragment that contains editable fields
or controls for a separate administrative workflow. Even when the replacement is
correctly wired, an asynchronous update can discard an operator's unsaved input
or replace a control between pointer-down and click delivery.

The VPN page uses an OTP bridge for this pattern:

1. the bridge subscribes to the VPN event bus through distributed Erlang RPC;
2. a VPN event is treated only as a wake-up signal;
3. IAS reads the current runtime snapshot through its normal client;
4. the bridge sends a Nitro `#direct{}` message to each subscribed VPN page;
5. the page updates only the read-only runtime status and summary fragments.

The reconciliation editor is not replaced by runtime events. A separate stable
notice (`vpn_reconciliation_stale_notice`) tells the operator to refresh the
comparison before acting on incidents. Refresh reconciliation controls, incident
editors, and their postbacks only through explicit reconciliation actions. When
one action must refresh several related interactive areas, prefer one outer
fragment with one stable replacement root instead of several sibling
`nitro:update/2` calls.

Disconnect and reconnect notifications must also preserve the last rendered
read-only snapshot. On disconnect, update independent status/notice targets and
mark the existing table as last-known/stale; do not replace it with an empty or
error table. Treat event-stream connectivity and snapshot freshness as separate
states. A successful subscription followed by a failed snapshot RPC must emit a
snapshot-failed UI event, not the same event used for a fresh snapshot. This avoids
claims such as "fresh snapshot loaded" when only the transport reconnected.

A page websocket process may register itself with a supervised bridge during
`event(init)` and unregister during `event(terminate)`. The bridge must monitor
page processes, and backend code must send `{direct, Payload}` to the websocket
process instead of calling `nitro:update/2` outside the page's N2O context. The
page module handles `Payload` in `event/1`, where Nitro actions are safe to emit.

### Destructive actions and confirmation

Use a two-step Nitro postback for destructive operations:

```erlang
event({confirm_revoke, DeviceId}) ->
    nitro:wire(#confirm{
        text = <<"Revoke VPN access permanently?">>,
        postback = {revoke, DeviceId}});
event({revoke, DeviceId}) ->
    Result = revoke(DeviceId),
    nitro:update(device_vpn_access,
                 device_vpn_access_container(render_result(Result))).
```

The working `Disable VPN Access` and `Revoke VPN Access` flows follow this
pattern: the control has an explicit ID, the destructive action is confirmed by
a server-generated `#confirm`, and the result replaces a container that keeps
its original ID. Newly rendered lifecycle controls are returned as Nitro records
and are wired again after insertion.

### Failure signatures

- The first update works, but later updates do nothing: the replacement root
  probably lost the target ID.
- A refreshed button is visible but has no working postback: the control was
  probably inserted as pre-rendered/raw HTML, or a later ancestor replacement
  discarded its listener.
- The wrong row reacts, or only one of several controls works: inspect duplicate
  IDs and make row action IDs entity-specific.
- `source` values are empty or belong to another row: inspect missing, replaced,
  or duplicated source element IDs.

### Verification

A text-only rendering assertion is not enough for a refreshed interactive
fragment. Verify the full lifecycle:

1. render the initial fragment;
2. trigger an action that calls `nitro:update/2`;
3. trigger a newly rendered postback control;
4. for destructive operations, accept the confirmation and verify the final
   postback;
5. update the same fragment again to prove that its target ID was preserved.

At minimum, server-side tests should assert that the replacement root keeps the
expected ID and that repeated controls receive unique explicit IDs. A browser or
websocket integration test is needed to prove that the newly emitted listener
JavaScript executes and the second postback reaches the server.
