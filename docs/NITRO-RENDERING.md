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
