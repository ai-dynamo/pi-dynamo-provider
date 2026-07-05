# Dynamo Agent Plugins

Small agent integrations that send session identity to Dynamo.

## Plugins

- [`pi-plugin/`](pi-plugin/) - Pi provider for Dynamo's OpenAI-compatible endpoint.
- [`hermes-plugin/`](hermes-plugin/) - Hermes middleware that maps Hermes `session_id` to `x-dynamo-session-id`.
- [`openclaw-plugin/`](openclaw-plugin/) - OpenClaw provider that maps OpenClaw `sessionId` to `x-dynamo-session-id`.

Each plugin owns its install, configuration, and validation instructions.

## Harbor adapters

Harbor-specific integration files live with the plugin they adapt. The Pi adapter is in [`pi-plugin/harbor/`](pi-plugin/harbor/).
