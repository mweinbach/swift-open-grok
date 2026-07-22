// ACPWireCorpusFixture.swift
//
// Semantic ACP wire corpus embedded as source so the fixture ships
// without Package.swift resource registration (slice-owned test path).
// Payloads mirror agent-client-protocol / xai-acp-lib shapes used by open-grok.

enum ACPWireCorpusFixture {
    /// JSON document: initialize/auth/session reverse requests, ask-user
    /// single/multi-select/Other/cancel, extension notifications, errors.
    static let json = ###"""
    {
      "referenceRevision": "open-grok.21",
      "description": "Semantic ACP wire corpus for OpenGrokACP round-trip parity.",
      "cases": [
        {
          "name": "initialize-request",
          "direction": "agent",
          "method": "initialize",
          "isNotification": false,
          "params": {
            "protocolVersion": 1,
            "clientCapabilities": {
              "fs": { "readTextFile": true, "writeTextFile": true },
              "terminal": true
            },
            "clientInfo": { "name": "open-grok-pager", "version": "0.1.0" },
            "_meta": {
              "openGrok": {
                "product": "Open Grok",
                "executable": "open-grok",
                "stateDirectory": ".opengrok",
                "homeEnvironmentVariable": "OPENGROK_HOME"
              }
            }
          },
          "response": {
            "protocolVersion": 1,
            "agentCapabilities": { "loadSession": true },
            "authMethods": [{ "id": "xai", "name": "xAI" }],
            "agentInfo": { "name": "open-grok", "version": "0.1.0" }
          }
        },
        {
          "name": "authenticate-request",
          "direction": "agent",
          "method": "authenticate",
          "isNotification": false,
          "params": { "methodId": "xai" },
          "response": {}
        },
        {
          "name": "session-new-request",
          "direction": "agent",
          "method": "session/new",
          "isNotification": false,
          "params": {
            "cwd": "/tmp/proj",
            "additionalDirectories": [],
            "mcpServers": []
          }
        },
        {
          "name": "session-load-request",
          "direction": "agent",
          "method": "session/load",
          "isNotification": false,
          "params": { "sessionId": "sess-load-1", "cwd": "/tmp/proj" }
        },
        {
          "name": "session-resume-request",
          "direction": "agent",
          "method": "session/resume",
          "isNotification": false,
          "params": { "sessionId": "sess-resume-1" }
        },
        {
          "name": "session-fork-request",
          "direction": "agent",
          "method": "session/fork",
          "isNotification": false,
          "params": { "sessionId": "sess-fork-1", "cwd": "/tmp/fork" }
        },
        {
          "name": "session-list-request",
          "direction": "agent",
          "method": "session/list",
          "isNotification": false,
          "params": { "cwd": "/tmp/proj" }
        },
        {
          "name": "session-prompt-request",
          "direction": "agent",
          "method": "session/prompt",
          "isNotification": false,
          "params": {
            "sessionId": "sess-1",
            "prompt": [{ "type": "text", "text": "hello wire corpus" }]
          },
          "response": { "stopReason": "end_turn" }
        },
        {
          "name": "session-cancel-notification",
          "direction": "agent",
          "method": "session/cancel",
          "isNotification": true,
          "params": { "sessionId": "sess-1" }
        },
        {
          "name": "session-set-mode-request",
          "direction": "agent",
          "method": "session/set_mode",
          "isNotification": false,
          "params": { "sessionId": "sess-1", "modeId": "code" }
        },
        {
          "name": "session-set-model-camel-alias",
          "direction": "agent",
          "method": "session/setModel",
          "isNotification": false,
          "params": { "sessionId": "sess-1", "modelId": "grok-4" }
        },
        {
          "name": "session-set-config-option",
          "direction": "agent",
          "method": "session/set_config_option",
          "isNotification": false,
          "params": {
            "sessionId": "sess-1",
            "configId": "model",
            "value": "grok-4"
          }
        },
        {
          "name": "request-permission-reverse",
          "direction": "client",
          "method": "session/request_permission",
          "isNotification": false,
          "params": {
            "sessionId": "sess-1",
            "toolCall": { "toolCallId": "tc-perm-1", "title": "Write file" },
            "options": [
              {
                "optionId": "once",
                "name": "Allow once",
                "kind": "allow_once"
              }
            ]
          },
          "response": { "outcome": { "outcome": "cancelled" } }
        },
        {
          "name": "session-update-notification",
          "direction": "client",
          "method": "session/update",
          "isNotification": true,
          "params": {
            "sessionId": "sess-1",
            "update": {
              "sessionUpdate": "agent_message_chunk",
              "content": { "type": "text", "text": "streamed" }
            }
          }
        },
        {
          "name": "terminal-create-request",
          "direction": "client",
          "method": "terminal/create",
          "isNotification": false,
          "params": {
            "sessionId": "sess-1",
            "command": "bash",
            "args": ["-lc", "echo hi"]
          }
        },
        {
          "name": "extension-method-request",
          "direction": "agent",
          "method": "x.ai/custom_tool",
          "isNotification": false,
          "params": { "payload": { "k": "v" } },
          "response": { "ok": true }
        },
        {
          "name": "extension-notification-named",
          "direction": "agent",
          "method": "x.ai/session_event",
          "isNotification": true,
          "params": { "event": "turn_start" }
        },
        {
          "name": "ask-user-single-select-recommended",
          "direction": "client",
          "method": "x.ai/ask_user_question",
          "isNotification": false,
          "params": {
            "sessionId": "sess-1",
            "toolCallId": "tc-ask-1",
            "mode": "default",
            "questions": [
              {
                "question": "Which database?",
                "multiSelect": false,
                "options": [
                  {
                    "label": "Redis (Recommended)",
                    "description": "In-memory",
                    "preview": "<div>redis</div>"
                  },
                  {
                    "label": "Postgres",
                    "description": "Relational"
                  }
                ]
              }
            ]
          },
          "response": {
            "outcome": "accepted",
            "answers": { "Which database?": ["Redis (Recommended)"] }
          }
        },
        {
          "name": "ask-user-multi-select",
          "direction": "client",
          "method": "x.ai/ask_user_question",
          "isNotification": false,
          "params": {
            "sessionId": "sess-1",
            "toolCallId": "tc-ask-2",
            "mode": "default",
            "questions": [
              {
                "question": "Which caches?",
                "multiSelect": true,
                "options": [
                  { "label": "Redis", "description": "hot" },
                  { "label": "Memcached", "description": "legacy" }
                ]
              }
            ]
          },
          "response": {
            "outcome": "accepted",
            "answers": { "Which caches?": ["Redis", "Memcached"] }
          }
        },
        {
          "name": "ask-user-other-freeform",
          "direction": "client",
          "method": "x.ai/ask_user_question",
          "isNotification": false,
          "params": {
            "sessionId": "sess-1",
            "toolCallId": "tc-ask-3",
            "mode": "plan",
            "questions": [
              {
                "question": "Notes?",
                "options": [
                  { "label": "Other", "description": "Freeform input" }
                ]
              }
            ]
          },
          "response": {
            "outcome": "accepted",
            "answers": { "Notes?": ["Other"] },
            "annotations": { "Notes?": { "notes": "please use SQLite" } }
          }
        },
        {
          "name": "ask-user-cancelled",
          "direction": "client",
          "method": "x.ai/ask_user_question",
          "isNotification": false,
          "params": {
            "sessionId": "sess-1",
            "toolCallId": "tc-ask-4",
            "mode": "default",
            "questions": []
          },
          "response": { "outcome": "cancelled" }
        },
        {
          "name": "json-rpc-error-auth-required",
          "kind": "jsonrpc-error",
          "id": 7,
          "error": {
            "code": -32000,
            "message": "Authentication required"
          }
        },
        {
          "name": "json-rpc-error-with-data",
          "kind": "jsonrpc-error",
          "id": "err-1",
          "error": {
            "code": -32002,
            "message": "Resource not found",
            "data": { "uri": "file:///tmp/missing" }
          }
        }
      ]
    }
    """###
}
