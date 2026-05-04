# pi-dynamo-provider

Pi extension package that registers a `dynamo` provider backed by Dynamo's OpenAI-compatible chat-completions endpoint.

## Usage

```bash
export DYNAMO_BASE_URL=http://127.0.0.1:8000/v1
export DYN_AGENT_WORKFLOW_TYPE_ID=pi_coding_agent
export DYN_AGENT_WORKFLOW_ID=pi-run-001

pi -e ./src/index.ts --model dynamo/<model-id>
```

The extension discovers models from `<base-url>/models`. If discovery fails, it registers `dynamo/default` so Pi can still start.

## Environment

- `DYNAMO_BASE_URL` or `OPENAI_BASE_URL`: endpoint root. Defaults to `http://127.0.0.1:8000/v1`.
- `DYNAMO_API_KEY`: API key. Defaults to `dynamo-local`.
- `DYN_AGENT_WORKFLOW_TYPE_ID`: defaults to `pi_coding_agent`.
- `DYN_AGENT_WORKFLOW_ID`: optional workflow ID. Tool records default this to the Pi session ID when unset.
- `DYN_AGENT_PROGRAM_ID`: optional program override. Defaults to Pi's session ID per request.
- `DYN_AGENT_PARENT_PROGRAM_ID`: optional parent program ID.
- `DYN_AGENT_TOOL_EVENTS_ZMQ_ENDPOINT`, `DYN_AGENT_TRACE_TOOL_ZMQ_ENDPOINT`, or `DYN_AGENT_TRACE_TOOL_EVENTS_ZMQ_ENDPOINT`: optional ZMQ PUB endpoint for Pi tool events.
- `DYN_AGENT_TOOL_EVENTS_ZMQ_TOPIC`, `DYN_AGENT_TRACE_TOOL_ZMQ_TOPIC`, or `DYN_AGENT_TRACE_TOOL_EVENTS_ZMQ_TOPIC`: optional tool-event topic. Defaults to `agent-tool-events`.
- `DYN_AGENT_TOOL_EVENTS_QUEUE_CAPACITY`: optional local publish queue capacity. Defaults to `100000`.

Each request adds:

- `nvext.agent_context`
- `x-request-id` if one was not already present

When tool-event ZMQ is configured, the extension also publishes `tool_start`, `tool_end`, and `tool_error`
records using Dynamo's agent trace schema:

```text
[topic, seq_be_u64, msgpack(AgentTraceRecord)]
```

Dynamo must be started with a matching subscriber endpoint, for example:

```bash
export DYN_AGENT_TRACE_SINKS=jsonl
export DYN_AGENT_TRACE_OUTPUT_PATH=/tmp/dynamo-agent-trace.jsonl
export DYN_AGENT_TRACE_TOOL_EVENTS_ZMQ_ENDPOINT=tcp://127.0.0.1:20390
```

Then start Pi with:

```bash
export DYN_AGENT_TOOL_EVENTS_ZMQ_ENDPOINT=tcp://127.0.0.1:20390
```

The provider delegates serialization and streaming to Pi's existing OpenAI-compatible provider.
