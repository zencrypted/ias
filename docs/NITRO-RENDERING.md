# Nitro Rendering Rules

IAS pages should keep text rendering explicit before values are passed to Nitro records.

## Text Values

- Convert atoms before rendering. Use `ias_html:text/1` or `atom_to_binary(Value, utf8)`.
- Collapse mixed text into one binary before assigning it to an element body. Use `ias_html:join/1`.
- Join lists of atom or binary values with `ias_html:join_csv/1`.
- Do not pass mixed text iolists such as `[default_user, " - ", <<"Default User">>]` directly to Nitro.

## Element Bodies

- A list used as a Nitro element body means child elements or child body items.
- Use lists only when the body intentionally contains multiple Nitro elements.
- If the value is text, collapse it to a binary first.

## Websocket Updates

- Multiline HTML sent through websocket JavaScript must be escaped with `nitro:js_escape/1`.
- Render first with `nitro:render/1`, convert to binary if needed, then wire the escaped HTML.
