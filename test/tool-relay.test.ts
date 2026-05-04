import { decode } from "@msgpack/msgpack";
import type { ExtensionContext } from "@mariozechner/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { DEFAULT_DYNAMO_BASE_URL, DEFAULT_WORKFLOW_TYPE_ID } from "../src/dynamo-provider.js";
import {
	buildDynamoTraceAgentContext,
	DEFAULT_TOOL_EVENT_QUEUE_CAPACITY,
	DynamoToolEventPublisher,
	DynamoToolEventRelay,
	getToolClass,
	readDynamoToolRelayConfig,
	type DynamoAgentTraceRecord,
	type ToolEventSocket,
} from "../src/tool-relay.js";

const config = {
	baseUrl: DEFAULT_DYNAMO_BASE_URL,
	apiKey: "test-key",
	workflowTypeId: DEFAULT_WORKFLOW_TYPE_ID,
};

class FakeToolEventSocket implements ToolEventSocket {
	endpoint: string | undefined;
	closed = false;
	readonly sent: [Buffer, Buffer, Buffer][] = [];

	async bind(endpoint: string): Promise<void> {
		this.endpoint = endpoint;
	}

	async send(frames: [Buffer, Buffer, Buffer]): Promise<void> {
		this.sent.push(frames);
	}

	close(): void {
		this.closed = true;
	}
}

function createContext(sessionId: string): ExtensionContext {
	return {
		sessionManager: {
			getSessionId: () => sessionId,
		},
	} as unknown as ExtensionContext;
}

function decodeTraceRecord(frame: Buffer): DynamoAgentTraceRecord {
	return decode(frame) as DynamoAgentTraceRecord;
}

describe("tool relay config", () => {
	it("reads Dynamo tool relay env aliases", () => {
		expect(
			readDynamoToolRelayConfig({
				DYN_AGENT_TRACE_TOOL_EVENTS_ZMQ_ENDPOINT: "tcp://127.0.0.1:20390",
				DYN_AGENT_TRACE_TOOL_EVENTS_ZMQ_TOPIC: "tools",
			}),
		).toEqual({
			endpoint: "tcp://127.0.0.1:20390",
			topic: "tools",
			queueCapacity: DEFAULT_TOOL_EVENT_QUEUE_CAPACITY,
		});

		expect(
			readDynamoToolRelayConfig({
				DYN_AGENT_TOOL_EVENTS_ZMQ_ENDPOINT: "ipc:///tmp/pi-tools",
				DYN_AGENT_TOOL_EVENTS_ZMQ_TOPIC: "pi-tools",
				DYN_AGENT_TOOL_EVENTS_QUEUE_CAPACITY: "7",
			}),
		).toEqual({
			endpoint: "ipc:///tmp/pi-tools",
			topic: "pi-tools",
			queueCapacity: 7,
		});
	});
});

describe("tool relay agent context", () => {
	it("uses the Pi session ID as default program and workflow ID", () => {
		expect(buildDynamoTraceAgentContext(config, "pi-session")).toEqual({
			workflow_type_id: DEFAULT_WORKFLOW_TYPE_ID,
			workflow_id: "pi-session",
			program_id: "pi-session",
		});
	});

	it("uses env workflow/program IDs when provided", () => {
		expect(
			buildDynamoTraceAgentContext(
				{
					...config,
					workflowId: "workflow-1",
					programId: "program-1",
					parentProgramId: "parent-1",
				},
				"pi-session",
			),
		).toEqual({
			workflow_type_id: DEFAULT_WORKFLOW_TYPE_ID,
			workflow_id: "workflow-1",
			program_id: "program-1",
			parent_program_id: "parent-1",
		});
	});
});

describe("tool relay records", () => {
	it("publishes msgpack-framed tool_start and tool_end records", async () => {
		const socket = new FakeToolEventSocket();
		const publisher = new DynamoToolEventPublisher(
			{ endpoint: "tcp://127.0.0.1:20390", topic: "tools", queueCapacity: 10 },
			() => socket,
		);
		await publisher.start();

		let unixMs = 1000;
		let perfMs = 10;
		const relay = new DynamoToolEventRelay(
			{ ...config, workflowId: "workflow-1" },
			publisher,
			() => unixMs,
			() => perfMs,
		);

		relay.handleToolExecutionStart(
			{ toolCallId: "call-1", toolName: "agent_tools---search", args: { query: "hello" } },
			createContext("pi-session"),
		);
		await publisher.flush();

		expect(socket.endpoint).toBe("tcp://127.0.0.1:20390");
		expect(socket.sent).toHaveLength(1);
		expect(socket.sent[0]?.[0].toString("utf8")).toBe("tools");
		expect(socket.sent[0]?.[1].readBigUInt64BE()).toBe(0n);
		expect(decodeTraceRecord(socket.sent[0]?.[2] ?? Buffer.alloc(0))).toEqual({
			schema: "dynamo.agent.trace.v1",
			event_type: "tool_start",
			event_time_unix_ms: 1000,
			event_source: "harness",
			agent_context: {
				workflow_type_id: DEFAULT_WORKFLOW_TYPE_ID,
				workflow_id: "workflow-1",
				program_id: "pi-session",
			},
			tool: {
				tool_call_id: "call-1",
				tool_class: "agent_tools",
				started_at_unix_ms: 1000,
				status: "running",
			},
		});

		unixMs = 1500;
		perfMs = 15.25;
		relay.handleToolExecutionEnd(
			{
				toolCallId: "call-1",
				toolName: "agent_tools---search",
				result: { content: [{ type: "text", text: "done" }] },
				isError: false,
			},
			createContext("pi-session"),
		);
		await publisher.flush();

		expect(socket.sent).toHaveLength(2);
		expect(socket.sent[1]?.[1].readBigUInt64BE()).toBe(1n);
		expect(decodeTraceRecord(socket.sent[1]?.[2] ?? Buffer.alloc(0))).toEqual({
			schema: "dynamo.agent.trace.v1",
			event_type: "tool_end",
			event_time_unix_ms: 1500,
			event_source: "harness",
			agent_context: {
				workflow_type_id: DEFAULT_WORKFLOW_TYPE_ID,
				workflow_id: "workflow-1",
				program_id: "pi-session",
			},
			tool: {
				tool_call_id: "call-1",
				tool_class: "agent_tools",
				started_at_unix_ms: 1000,
				ended_at_unix_ms: 1500,
				duration_ms: 5.25,
				status: "succeeded",
				output_bytes: 4,
			},
		});
	});

	it("publishes self-contained terminal errors even without a start event", async () => {
		const socket = new FakeToolEventSocket();
		const publisher = new DynamoToolEventPublisher(
			{ endpoint: "tcp://127.0.0.1:20390", topic: "tools", queueCapacity: 10 },
			() => socket,
		);
		await publisher.start();

		const relay = new DynamoToolEventRelay(config, publisher, () => 2000, () => 20);
		relay.handleToolExecutionEnd(
			{
				toolCallId: "call-2",
				toolName: "bash",
				result: { content: [{ type: "text", text: "failed" }] },
				isError: true,
			},
			createContext("pi-session"),
		);
		await publisher.flush();

		expect(decodeTraceRecord(socket.sent[0]?.[2] ?? Buffer.alloc(0))).toEqual({
			schema: "dynamo.agent.trace.v1",
			event_type: "tool_error",
			event_time_unix_ms: 2000,
			event_source: "harness",
			agent_context: {
				workflow_type_id: DEFAULT_WORKFLOW_TYPE_ID,
				workflow_id: "pi-session",
				program_id: "pi-session",
			},
			tool: {
				tool_call_id: "call-2",
				tool_class: "bash",
				started_at_unix_ms: 2000,
				ended_at_unix_ms: 2000,
				duration_ms: 0,
				status: "error",
				error_type: "pi_tool_error",
				output_bytes: 6,
			},
		});
	});

	it("normalizes Pi and MCP-style tool names to tool classes", () => {
		expect(getToolClass("agent_tools---search")).toBe("agent_tools");
		expect(getToolClass("mcp/server.tool")).toBe("mcp");
		expect(getToolClass("bash")).toBe("bash");
	});
});
