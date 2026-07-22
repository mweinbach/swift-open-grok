// OpenGrokWorkspaceTypesTests.swift
//
// Fixture-backed wire-contract tests for OpenGrokWorkspaceTypes.
// Translated from crates/codegen/xai-grok-workspace-types/tests/wire_round_trip.rs
// and the per-module `#[cfg(test)]` suites under src/rpc/*.

import Testing
import Foundation
@testable import OpenGrokWorkspaceTypes
import OpenGrokShared

// MARK: - Helpers

private func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    return e
}

private func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try makeEncoder().encode(value)
    return String(data: data, encoding: .utf8)!
}

private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try makeDecoder().decode(T.self, from: Data(json.utf8))
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try decodeJSON(T.self, try encodeJSON(value))
}

private func fixedDate() -> Date {
    // 2026-04-23T12:00:00Z
    Date(timeIntervalSince1970: 1_777_046_400)
}

// MARK: - Adjacent-tag golden shapes (wire_round_trip.rs)

@Suite("Permission + plan-mode + hunk adjacent tags")
struct AdjacentTagGoldenTests {
    @Test("permission decision deny/allow_once golden")
    func permissionDecisionGolden() throws {
        let deny = PermissionDecision.deny(reason: "no")
        #expect(try encodeJSON(deny) == #"{"data":{"reason":"no"},"type":"deny"}"#)
        #expect(try roundTrip(deny) == deny)

        let allow = PermissionDecision.allowOnce
        #expect(try encodeJSON(allow) == #"{"type":"allow_once"}"#)
        #expect(try roundTrip(allow) == allow)

        #expect(try roundTrip(PermissionDecision.allowSession) == .allowSession)
        #expect(try roundTrip(PermissionDecision.allowProject) == .allowProject)
    }

    @Test("plan mode decision/transition golden")
    func planModeGolden() throws {
        let reject = PlanModeDecision.reject(feedback: "not yet")
        #expect(try encodeJSON(reject) == #"{"data":{"feedback":"not yet"},"type":"reject"}"#)
        #expect(try encodeJSON(PlanModeDecision.approve) == #"{"type":"approve"}"#)
        #expect(try encodeJSON(PlanModeDecision.defer) == #"{"type":"defer"}"#)

        let enter = PlanModeTransition.enter(plan: "draft")
        #expect(try encodeJSON(enter) == #"{"data":{"plan":"draft"},"type":"enter"}"#)
        let exit = PlanModeTransition.exit(finalPlan: nil)
        let exitJSON = try encodeJSON(exit)
        #expect(exitJSON.contains("\"final_plan\""))
        #expect(!exitJSON.contains("\"finalPlan\""))
        #expect(try roundTrip(exit) == exit)
    }

    @Test("hunk action adjacent tag golden")
    func hunkActionGolden() throws {
        let h = HunkAction.accept(hunkId: HunkId("h"))
        #expect(try encodeJSON(h) == #"{"data":{"hunk_id":"h"},"type":"accept"}"#)
        #expect(try roundTrip(h) == h)
    }

    @Test("tool progress adjacent tag golden")
    func toolProgressGolden() throws {
        let started = ToolProgress.started(callId: ToolCallId("c1"))
        #expect(try encodeJSON(started) == #"{"data":{"call_id":"c1"},"type":"started"}"#)
        let percent = ToolProgress.percent(callId: ToolCallId("c1"), fraction: 0.5)
        #expect(try encodeJSON(percent) == #"{"data":{"call_id":"c1","fraction":0.5},"type":"percent"}"#)
        let chunk = ToolChunk.progress(percent)
        #expect(
            try encodeJSON(chunk)
                == #"{"data":{"data":{"call_id":"c1","fraction":0.5},"type":"percent"},"type":"progress"}"#
        )
    }

    @Test("need_permission / need_user_answer / tool_response permission golden")
    func bidiPermissionGolden() throws {
        let chunk = ToolChunk.needPermission(
            reqId: "perm-1",
            request: PermissionRequest(
                toolName: "rm",
                summary: "deletes a file",
                inputJson: #"{"path":"/tmp/x"}"#,
                destructive: true
            )
        )
        let json = try encodeJSON(chunk)
        #expect(json.contains("\"need_permission\""))
        #expect(json.contains("\"req_id\""))
        #expect(json.contains("\"tool_name\""))
        #expect(!json.contains("\"reqId\""))
        #expect(try roundTrip(chunk) == chunk)

        let resp = ToolResponse.permission(reqId: "perm-1", decision: .allowOnce)
        #expect(
            try encodeJSON(resp)
                == #"{"data":{"decision":{"type":"allow_once"},"req_id":"perm-1"},"type":"permission"}"#
        )
    }

    @Test("user answer adjacent tags")
    func userAnswerGolden() throws {
        let resp = ToolResponse.userAnswer(
            reqId: "q-1",
            answers: [.selected("A")]
        )
        #expect(
            try encodeJSON(resp)
                == #"{"data":{"answers":[{"data":"A","type":"selected"}],"req_id":"q-1"},"type":"user_answer"}"#
        )
        #expect(try roundTrip(UserAnswer.multiple(["Cheese", "Olives"])) == .multiple(["Cheese", "Olives"]))
        #expect(try roundTrip(UserAnswer.other("freeform")) == .other("freeform"))
    }
}

// MARK: - Round-trip suites

@Suite("Workspace request/ops/session round trips")
struct WorkspaceRequestRoundTripTests {
    @Test("workspace request variants")
    func workspaceRequest() throws {
        let samples: [WorkspaceRequest] = [
            .tool(.call(ToolCallArgs(
                session: SessionId("s1"),
                toolName: "read_file",
                inputJson: #"{"path":"/etc/hosts"}"#,
                callId: ToolCallId("c1")
            ))),
            .tool(.definitions),
            .ops(.listHunks),
            .session(.list),
        ]
        for s in samples {
            #expect(try roundTrip(s) == s)
        }
        let ops = WorkspaceRequest.ops(.listHunks)
        let json = try encodeJSON(ops)
        #expect(json.hasPrefix(#"{"data":"#) || json.contains(#""type":"ops""#))
        #expect(json.contains(#""type":"ops""#))
    }

    @Test("ops request rich payloads")
    func opsRequest() throws {
        let samples: [WorkspaceOpsRequest] = [
            .gitStatus(GitStatusOpts(includeUntracked: true, includeIgnored: true)),
            .gitDiff(GitDiffArgs(range: "main..HEAD", paths: ["src/lib.rs", "src/main.rs"], staged: true)),
            .gitBranchInfo,
            .gitMetadata,
            .listHunks,
            .actOnHunk(.reject(hunkId: HunkId("h"))),
            .ripgrep(RipgrepArgs(
                pattern: "TODO",
                cwd: "src",
                globs: ["*.rs", "!target/**"],
                caseInsensitive: true,
                maxMatches: 100
            )),
            .fuzzySearch(FuzzySearchArgs(query: "main", cwd: "src", limit: 50)),
            .discoverSkills,
            .discoverPlugins,
            .loadProjectConfig,
            .loadPermissions,
            .loadEnvrc,
            .resolveFileRefs(["@x", "@docs/AGENTS.md"]),
            .memorySearch(query: "auth middleware patterns", limit: 5),
            .memoryWrite("note body"),
            .installPlugin("https://example"),
            .refreshPlugins,
        ]
        for s in samples {
            #expect(try roundTrip(s) == s)
        }
        let mem = WorkspaceOpsRequest.memorySearch(query: "auth", limit: 5)
        let json = try encodeJSON(mem)
        #expect(json.contains("\"query\""))
        #expect(json.contains("\"limit\""))
    }

    @Test("session lifecycle rich payloads")
    func sessionLifecycle() throws {
        let rich = AgentSessionConfig(
            agentId: "subagent-explore",
            isolation: .sandbox,
            capabilityMode: .readOnly,
            toolConfig: [
                ToolServerConfig(id: "fs", enabled: true, command: "/usr/bin/fs-mcp", args: ["k": "v"])
            ],
            maxDepth: 3,
            cwdOverride: "/tmp/work",
            extraEnv: ["FOO": "1", "BAR": "2"]
        )
        let samples: [SessionLifecycleRequest] = [
            .fork(rich),
            .destroy(SessionId("s")),
            .list,
            .applyWorktree(SessionId("s")),
            .beginPrompt(session: SessionId("s"), idx: 7),
            .endPrompt(session: SessionId("s"), idx: 7),
            .rewind(session: SessionId("s"), target: 1),
            .getRewindPoints(SessionId("s")),
        ]
        for s in samples {
            #expect(try roundTrip(s) == s)
        }
        let begin = SessionLifecycleRequest.beginPrompt(session: SessionId("s"), idx: 3)
        let json = try encodeJSON(begin)
        #expect(json.contains("\"session\""))
        #expect(json.contains("\"idx\""))
    }
}

@Suite("Chunks + events + errors")
struct ChunksEventsErrorsTests {
    @Test("tool chunks including permission and plan mode")
    func toolChunks() throws {
        let questions = [
            UserQuestion(
                question: "Pick a color?",
                options: [
                    UserQuestionOption(label: "Red", description: "warm", preview: "```css\ncolor: red;\n```"),
                    UserQuestionOption(label: "Blue", description: "cool", preview: nil),
                ],
                multiSelect: false
            )
        ]
        let samples: [ToolChunk] = [
            .output(ToolOutputChunk(
                callId: ToolCallId("c"),
                stream: "stdout",
                bytes: Data((0...255).map { UInt8($0) }),
                at: fixedDate()
            )),
            .progress(.started(callId: ToolCallId("c"))),
            .progress(.status(callId: ToolCallId("c"), message: "running")),
            .progress(.percent(callId: ToolCallId("c"), fraction: 0.5)),
            .final(ToolCallResult(
                callId: ToolCallId("c"),
                exitCode: 42,
                summary: "ok",
                outputJson: #"{"x":1}"#,
                cancelled: false
            )),
            .definitions([
                ToolDef(name: "read_file", description: "Read a file", inputSchemaJson: #"{"type":"object"}"#, requiresPermission: false),
                ToolDef(name: "", description: "", inputSchemaJson: "", requiresPermission: false),
            ]),
            .needPermission(
                reqId: "perm-1",
                request: PermissionRequest(
                    toolName: "run_terminal_cmd",
                    summary: "rm -rf /tmp/scratch",
                    inputJson: #"{"cmd":"rm -rf /tmp/scratch"}"#,
                    destructive: true
                )
            ),
            .needUserAnswer(reqId: "q-1", questions: questions),
            .needPlanModeChange(reqId: "pm-1", transition: .enter(plan: "# Plan\n")),
            .needPlanModeChange(reqId: "pm-2", transition: .enter(plan: nil)),
            .needPlanModeChange(reqId: "pm-3", transition: .exit(finalPlan: "# Final\n")),
            .needPlanModeChange(reqId: "pm-4", transition: .exit(finalPlan: nil)),
        ]
        for s in samples {
            #expect(try roundTrip(s) == s)
        }
    }

    @Test("tool response permission/user/plan variants")
    func toolResponses() throws {
        let samples: [ToolResponse] = [
            .permission(reqId: "perm-1", decision: .allowOnce),
            .permission(reqId: "perm-2", decision: .allowSession),
            .permission(reqId: "perm-3", decision: .allowProject),
            .permission(reqId: "perm-4", decision: .deny(reason: "no thank you")),
            .userAnswer(reqId: "q-1", answers: [.selected("Red")]),
            .userAnswer(reqId: "q-2", answers: [.other("freeform answer")]),
            .userAnswer(reqId: "q-3", answers: [.multiple(["Cheese", "Olives"])]),
            .planModeChange(reqId: "pm-1", decision: .approve),
            .planModeChange(reqId: "pm-2", decision: .reject(feedback: "read more first")),
            .planModeChange(reqId: "pm-3", decision: .reject(feedback: nil)),
            .planModeChange(reqId: "pm-4", decision: .defer),
        ]
        for s in samples {
            #expect(try roundTrip(s) == s)
        }
    }

    @Test("ops + session chunks")
    func opsSessionChunks() throws {
        let richStatus = GitStatus(
            branch: "main", headCommit: "deadbeef", root: "/repo",
            staged: ["a"], unstaged: ["b"], untracked: ["c"], clean: false, vcs: .jj
        )
        let samples: [OpsChunk] = [
            .gitStatus(richStatus),
            .gitDiff(GitDiff(patch: "@@ -1 +1 @@\n-a\n+b", files: ["src/lib.rs"])),
            .gitBranchInfo(GitBranchInfo(current: "main", local: ["main", "dev"], upstream: "origin/main")),
            .gitMetadata(nil),
            .gitMetadata(GitMetadata(originUrl: "git@github.com:org/repo.git", root: "/repo", defaultBranch: "main", vcs: .git)),
            .hunks([Hunk(id: HunkId("h1"), path: "src/lib.rs", added: 5, removed: 2, startLine: 12, summary: "add hello")]),
            .skills([SkillInfo(id: "review", displayName: "Code Review", description: "perform code review", path: "/skills/review/SKILL.md", source: "global")]),
            .plugins([PluginInfo(id: "sample-plugin", name: "Sample Plugin", version: "1.2.3", path: "/plugins/sample-plugin", source: "marketplace", enabled: true)]),
            .projectConfig(ProjectConfig(values: ["a": "1"], trusted: true)),
            .permissions(PermissionPolicy(allow: ["read_file"], deny: ["run_terminal_cmd"], ask: ["edit_file"])),
            .envrc(["FOO": "1"]),
            .resolvedFiles([ResolvedFile(reference: "@README.md", path: "/repo/README.md", resolved: true, preview: "# Repo", error: nil)]),
            .memoryChunks([MemoryChunk(id: "m1", content: "auth uses JWT", source: "/memory/auth.md", score: 0.95)]),
            .plugin(PluginInfo(id: "sample-plugin", name: "Sample Plugin", version: "1.2.3", path: "/plugins/sample-plugin", source: "marketplace", enabled: true)),
            .ack,
            .fuzzyMatch(FuzzyMatch(path: "src/main.rs", score: 100, matchedIndices: [0, 1, 2])),
            .ripgrepHit(ContentMatch(path: "src/lib.rs", lineNumber: 12, line: "// TODO: fix", spans: [])),
            .ripgrepDone(RipgrepStats(filesMatched: 3, linesMatched: 10, truncated: false)),
        ]
        for s in samples {
            #expect(try roundTrip(s) == s)
        }

        let sessionSamples: [SessionChunk] = [
            .sessionId(SessionId("s")),
            .sessionInfo(AgentSessionInfo(
                id: SessionId("s1"),
                parent: SessionId("p1"),
                agentId: "subagent-explore",
                isolation: .worktree,
                createdAt: fixedDate()
            )),
            .rewindResult(RewindResult(session: SessionId("s1"), headPromptIndex: 5, promptsDropped: 2)),
            .rewindPoints([RewindPoint(promptIndex: 3, at: fixedDate(), summary: "prompt 3")]),
            .ack,
        ]
        for s in sessionSamples {
            #expect(try roundTrip(s) == s)
        }
    }

    @Test("workspace events + errors + lag")
    func eventsErrorsLag() throws {
        let events: [WorkspaceEvent] = [
            .fsChanged(path: "/a", kind: .created),
            .fsChanged(path: "/a", kind: .modified),
            .fsChanged(path: "/a", kind: .removed),
            .fsChanged(path: "/a", kind: .renamed),
            .gitHeadChanged(commit: "abc", branch: nil, vcs: .git),
            .gitHeadChanged(commit: "abc", branch: "main", vcs: .jj),
            .gitLockHeld(until: fixedDate()),
            .skillsChanged(added: [SkillInfo(id: "s")], removed: ["x"]),
            .pluginsChanged(plugins: [PluginInfo(id: "p")], projectTrusted: true),
            .hooksChanged(hooks: [HookInfo(id: "h")], projectTrusted: false),
            .mcpServerStateChanged(server: "fs", status: .stopped),
            .lspServerStateChanged(server: "rust", status: .failed),
            .codebaseIndexUpdated(filesIndexed: 99),
            .projectConfigChanged,
            .permissionPolicyChanged,
            .toolsChanged(sessionId: "session-7"),
        ]
        for e in events {
            #expect(try roundTrip(e) == e)
        }
        let idx = WorkspaceEvent.codebaseIndexUpdated(filesIndexed: 7)
        let json = try encodeJSON(idx)
        #expect(json.contains("\"files_indexed\""))
        #expect(!json.contains("\"filesIndexed\""))

        let errs: [WorkspaceError] = [
            .io(message: "x", kind: .permissionDenied),
            .vcs("oops"),
            .permission(reason: "no"),
            .notFound("/x"),
            .cancelled,
            .timeout(elapsedMs: 10),
            .sessionNotFound(SessionId("s")),
            .tool(code: "c", message: "m"),
            .remote("x"),
            .protocolMismatch(expected: "GitStatus", got: .ack),
            .protocolViolation("x"),
            .emptyStream,
            .internal("x"),
        ]
        for e in errs {
            #expect(try roundTrip(e) == e)
            #expect(!e.description.isEmpty)
        }
        #expect(try roundTrip(EventLag.lagged(0)) == .lagged(0))
        #expect(try roundTrip(EventLag.lagged(1_000_000)) == .lagged(1_000_000))
    }

    @Test("tool_call_args snake_case field names")
    func toolCallArgsSnakeCase() throws {
        let args = ToolCallArgs(
            session: SessionId("s"),
            toolName: "n",
            inputJson: "{}",
            callId: ToolCallId("c")
        )
        let json = try encodeJSON(args)
        #expect(json.contains("\"tool_name\""))
        #expect(json.contains("\"input_json\""))
        #expect(json.contains("\"call_id\""))
        #expect(!json.contains("\"toolName\""))
    }

    @Test("permission policy preserves allow/deny/ask order")
    func permissionPolicyOrder() throws {
        let policy = PermissionPolicy(
            allow: ["read_file", "list_dir"],
            deny: ["run_terminal_cmd"],
            ask: ["edit_file", "write"]
        )
        let back = try roundTrip(policy)
        #expect(back.allow == ["read_file", "list_dir"])
        #expect(back.deny == ["run_terminal_cmd"])
        #expect(back.ask == ["edit_file", "write"])
        // Audit context lives on PermissionRequest
        let req = PermissionRequest(
            toolName: "edit_file",
            summary: "edit Package.swift",
            inputJson: #"{"path":"Package.swift"}"#,
            destructive: true
        )
        #expect(try roundTrip(req) == req)
    }
}

// MARK: - RPC method constants + fixtures

@Suite("Workspace RPC methods")
struct WorkspaceRpcMethodTests {
    @Test("core method constants")
    func coreMethods() {
        #expect(WorkspaceInfoReq.method == "workspace.info")
        #expect(LoadPermissionsReq.method == "workspace.load_permissions")
        #expect(ListTodosReq.method == "workspace.list_todos")
        #expect(BeginPromptReq.method == "workspace.begin_prompt")
        #expect(EndPromptReq.method == "workspace.end_prompt")
        #expect(RewindToReq.method == "workspace.rewind_to")
    }

    @Test("filesystem method constants + defaults")
    func filesystemMethods() throws {
        #expect(PutFilesReq.method == "workspace.put_files")
        #expect(GetFilesReq.method == "workspace.get_files")
        #expect(FsListReq.method == "workspace.fs_list")
        #expect(FsExistsReq.method == "workspace.fs_exists")
        #expect(FsReadFileReq.method == "workspace.fs_read_file")
        #expect(FsWriteFileReq.method == "workspace.fs_write_file")
        #expect(FsDeleteFileReq.method == "workspace.fs_delete_file")
        #expect(CLIENT_FS_LIST_METHOD == "workspace.client_fs_list")
        #expect(ClientFsListReq.method == CLIENT_FS_LIST_METHOD)

        let list = try decodeJSON(FsListReq.self, #"{"path":"."}"#)
        #expect(list.depth == 1)
        #expect(list.limit == 1000)
        #expect(list.offset == 0)
        #expect(list.includeHidden)
        #expect(list.followSymlinks)
        #expect(list.respectGitIgnore)

        let read = try decodeJSON(FsReadFileReq.self, #"{"path":"a.txt"}"#)
        #expect(read.offset == nil)
        #expect(read.maxBytes == 1_048_576)
        #expect(read.encoding == .utf8)

        let node = FsListNode(name: "a", path: "/a", nodeType: "file", size: 1)
        let nodeJSON = try encodeJSON(node)
        #expect(nodeJSON.contains(#""type":"file""#))
        #expect(!nodeJSON.contains("isSymlink"))
    }

    @Test("client_fs wire stability snapshot")
    func clientFsSnapshot() throws {
        let listReq = try decodeJSON(ClientFsListReq.self, #"{"path":"docs"}"#)
        #expect(listReq.depth == 1)
        #expect(listReq.limit == 1000)
        #expect(listReq.includeHidden)

        let populated = ClientFsListReq(
            path: "docs", depth: 2, includeHidden: false, limit: 100, offset: 200,
            followSymlinks: false, respectGitIgnore: false,
            includeGlobs: ["*.md"], excludeGlobs: [".git"]
        )
        let json = try encodeJSON(populated)
        #expect(json.contains("\"includeHidden\":false"))
        #expect(json.contains("\"followSymlinks\":false"))
        #expect(json.contains("\"includeGlobs\""))

        let listRes = ClientFsListRes(
            nodes: [
                ClientFsListNode(
                    name: "a.txt", path: "docs/a.txt", nodeType: .file,
                    isSymlink: true, size: 11, mtimeMs: 1_700_000_000_000
                )
            ],
            truncated: true
        )
        let resJSON = try encodeJSON(listRes)
        #expect(resJSON.contains(#""type":"file""#))
        #expect(resJSON.contains("\"mtimeMs\""))
        #expect(resJSON.contains("\"isSymlink\":true"))

        let missing = ClientFsStatRes(exists: false)
        #expect(try encodeJSON(missing) == #"{"exists":false}"#)

        let readRes = ClientFsReadFileRes(
            content: nil, contentBase64: "aGVsbG8=", size: 5, hash: "abc123", contentType: .binary
        )
        let readJSON = try encodeJSON(readRes)
        #expect(readJSON.contains("\"contentBase64\""))
        #expect(readJSON.contains(#""type":"binary""#))
        #expect(try roundTrip(readRes) == readRes)
    }

    @Test("git + worktree + search + hunk + code_nav method constants")
    func familyMethods() {
        #expect(GitStatusExtReq.method == "workspace.git_status_ext")
        #expect(GitDiffRpcReq.method == "workspace.git_diff")
        #expect(DetectVcsKindReq.method == "workspace.detect_vcs_kind")
        #expect(GitCollectChangesReq.method == "workspace.git_collect_changes")

        #expect(CreateWorktreeRequest.method == "workspace.create_worktree")
        #expect(WorktreeCreateSyncReq.method == "workspace.worktree_create_sync")
        #expect(RemoveWorktreeRequest.method == "workspace.remove_worktree")
        #expect(ApplyWorktreeRequest.method == "workspace.apply_worktree")
        #expect(CreateWorktreeFromWorktreeSyncReq.method == "workspace.worktree_create_from_worktree_sync")
        #expect(WorktreeListReq.method == "workspace.worktree_list")

        #expect(ContentSearchRequest.method == "workspace.ripgrep")
        #expect(FuzzyOpenReq.method == "workspace.fuzzy_open")
        #expect(FuzzyChangeReq.method == "workspace.fuzzy_change")
        #expect(FuzzyCloseReq.method == "workspace.fuzzy_close")
        #expect(FuzzyStatusReq.method == "workspace.fuzzy_search")

        #expect(HunkSingleActionReq.method == "workspace.hunk_action")
        #expect(HunkFileActionReq.method == "workspace.hunk_file_action")
        #expect(HunkGetAllHunksReq.method == "workspace.get_all_hunks")
        #expect(HunkGetSessionSummaryReq.method == "workspace.get_session_summary")

        #expect(CodeGotoDefinitionReq.method == "workspace.code_goto_definition")
        #expect(CodeGotoReferencesReq.method == "workspace.code_goto_references")
        #expect(CodeFindDefinitionsReq.method == "workspace.code_find_definitions")
        #expect(CodeFindReferencesReq.method == "workspace.code_find_references")
        #expect(CodeIndexStatusReq.method == "workspace.code_index_status")
    }

    @Test("worktree transparent vs inner wrapper")
    func worktreeWrappers() throws {
        let create = CreateWorktreeRequest(sessionId: "s1", sourcePath: "/repo")
        let sync = WorktreeCreateSyncReq(create)
        let syncJSON = try encodeJSON(sync)
        #expect(syncJSON.contains("\"sessionId\""))
        #expect(syncJSON.contains("\"sourcePath\""))
        #expect(!syncJSON.contains("\"inner\""))
        #expect(try roundTrip(sync) == sync)

        let fromWt = CreateWorktreeFromWorktreeSyncReq(
            inner: CreateWorktreeFromWorktreeRequestWire(
                sourceWorktreePath: "/src",
                newSessionId: "s2"
            )
        )
        let fromJSON = try encodeJSON(fromWt)
        #expect(fromJSON.contains("\"inner\""))
        #expect(fromJSON.contains("\"sourceWorktreePath\""))
        #expect(fromJSON.contains("\"copyMode\":\"dirty\""))
        #expect(try roundTrip(fromWt) == fromWt)

        let creating = CreateWorktreeResponse.creating(sessionId: "s1", worktreePath: "/wt", sourceGitRoot: nil)
        let cJSON = try encodeJSON(creating)
        #expect(cJSON.contains("\"status\":\"creating\""))
        #expect(cJSON.contains("\"sessionId\""))
        #expect(!cJSON.contains("sourceGitRoot"))
        #expect(WorktreeType.parse("linked") == .linked)
        #expect(WorktreeType.parse("bogus") == nil)
    }

    @Test("search defaults + target client id untagged")
    func searchFixtures() throws {
        let req = try decodeJSON(ContentSearchRequest.self, #"{"pattern":"foo"}"#)
        #expect(req.respectGitignore)
        #expect(!req.caseInsensitive)
        #expect(req.cwd == nil)
        #expect(try roundTrip(req) == req)

        let file = ContentSearchMatchFile.fromPath("/repo/src/lib.rs")
        #expect(file.name == "lib.rs")
        #expect(file.path == "/repo/src/lib.rs")

        let none = try decodeJSON(FuzzyTargetClientId.self, "null")
        #expect(none.isNone)
        let client = try decodeJSON(FuzzyTargetClientId.self, #"{"connId":"c-1","instanceId":"i-1"}"#)
        if case .clientId(let id) = client {
            #expect(id.instanceId == "i-1")
            #expect(id.connId == "c-1")
        } else {
            Issue.record("expected clientId")
        }
        #expect(try roundTrip(client) == client)
    }

    @Test("hunk wire + forward-tolerant unknowns")
    func hunkWire() throws {
        #expect(try encodeJSON(HunkActionKind.accept) == "\"accept\"")
        #expect(try encodeJSON(HunkActionKind.reject) == "\"reject\"")

        let unknown = try decodeJSON(HunkSourceWire.self, #"{"type":"futureSource"}"#)
        #expect(unknown == .unknown)

        let status = try decodeJSON(FileContentStatusWire.self, "\"futureStatus\"")
        #expect(status == .unknown)

        let entryJSON = """
        {"path":"/x.rs","baseline":{"status":"futureStatus"},"current":{"status":"full","byteLen":1,"content":"a"},"isAgentFile":false,"staged":false}
        """
        let entry = try decodeJSON(FileContentEntryWire.self, entryJSON)
        #expect(entry.baseline.status == .unknown)
        #expect(entry.current.status == .full)

        let created = try makeDecoder().decode(
            Date.self,
            from: Data("\"2026-06-23T00:00:00Z\"".utf8)
        )
        let wire = HunkWire(
            id: "hunk-1",
            path: "/repo/src/main.rs",
            lineInfo: HunkLineInfoWire(oldStart: 1, oldCount: 2, newStart: 1, newCount: 3),
            source: .agentEdit(promptIndex: 4),
            oldText: "old\n",
            newText: "new\n",
            patch: nil,
            createdAt: created
        )
        #expect(try roundTrip(wire) == wire)
        let wJSON = try encodeJSON(wire)
        #expect(wJSON.contains("\"lineInfo\""))
        #expect(wJSON.contains("\"agentEdit\""))
        #expect(wJSON.contains("\"prompt_index\""))
    }

    @Test("session rewind conflict snake_case")
    func sessionRewind() throws {
        #expect(try encodeJSON(FileRewindConflictType.deletedExternally) == "\"deleted_externally\"")
        let resp = FileRewindResponse(
            success: true,
            targetPromptIndex: 3,
            revertedFiles: ["a.swift"],
            cleanFiles: ["b.swift"],
            conflicts: [FileRewindConflict(path: "c.swift", conflictType: .modifiedExternally)],
            error: nil
        )
        #expect(try roundTrip(resp) == resp)
        let begin = BeginPromptReq(sessionId: "s", promptIndex: 1)
        #expect(try roundTrip(begin) == begin)
    }

    @Test("rpc envelope success/failure + unit response")
    func rpcEnvelope() throws {
        let ok: RpcEnvelope<String> = .ok("hello")
        #expect(try encodeJSON(ok) == #"{"ok":"hello"}"#)
        #expect(try roundTrip(ok) == ok)

        let err: RpcEnvelope<String> = .err(RpcError(code: "session_not_found", message: "gone"))
        #expect(try encodeJSON(err).contains("\"err\""))
        #expect(try roundTrip(err) == err)

        let unit = WorkspaceRpcUnit()
        #expect(try encodeJSON(unit) == "null")
        #expect(try decodeJSON(WorkspaceRpcUnit.self, "null") == unit)
    }

    @Test("git status ext envelope + legacy flat payload")
    func gitStatusExt() throws {
        let structured = GitStatusExtResponse.structured(
            GitStatusData(branch: "main", staged: [], unstaged: [])
        )
        #expect(try roundTrip(structured) == structured)

        // Legacy flat payload (no format/data/prompt keys) wraps as structured.
        let legacy = try decodeJSON(GitStatusExtResponse.self, #"{"branch":"main","staged":[],"unstaged":[]}"#)
        #expect(legacy.format == .structured)
        #expect(legacy.data?.branch == "main")

        #expect(try encodeJSON(DetectedVcsKind.jujutsuColocated) == "\"jujutsuColocated\"")
        #expect(DetectedVcsKind.git.isRepo)
        #expect(!DetectedVcsKind.none.isRepo)
    }

    @Test("malformed input rejected")
    func malformed() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(PermissionDecision.self, #"{"type":"nope"}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(IsolationMode.self, "\"bogus\"")
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(WorktreeType.self, "\"bogus\"")
        }
    }
}

@Suite("Metadata keys")
struct MetadataKeyTests {
    @Test("standard metadata keys are unique")
    func unique() {
        let keys = STANDARD_META_KEYS
        #expect(Set(keys).count == keys.count)
        #expect(!keys.isEmpty)
    }
}

// MARK: - Hub / process / terminal / todo / foreign-session / capability fixtures
//
// Deterministic JSON corpora aligned with the Rust
// `xai-grok-workspace-types` serde shapes (rpc/workspace.rs, types/config.rs,
// error.rs, envelope.rs). These cover the acceptance families that the
// constructor round-trips above do not exercise as golden bytes.

@Suite("Workspace hub + session family JSON goldens")
struct WorkspaceHubFamilyGoldenTests {
    @Test("Computer Hub workspace.info typed shape + unknown fields")
    func computerHubWorkspaceInfo() throws {
        // Captured shape from hub_server workspace.info (Rust WorkspaceInfo).
        let raw = #"{"os":"linux","shell":"bash","cwd":"/workspace","future_field":42}"#
        let info = try decodeJSON(WorkspaceInfo.self, raw)
        #expect(info == WorkspaceInfo(os: "linux", shell: "bash", cwd: "/workspace"))
        // Re-encode drops unknown fields (serde default: ignore on decode,
        // do not echo unknowns).
        #expect(try encodeJSON(info) == #"{"cwd":"/workspace","os":"linux","shell":"bash"}"#)

        // Empty request is a Rust empty struct → `{}`, not null.
        #expect(try encodeJSON(WorkspaceInfoReq()) == "{}")
        #expect(try decodeJSON(WorkspaceInfoReq.self, "{}") == WorkspaceInfoReq())
        #expect(try decodeJSON(WorkspaceInfoReq.self, "null") == WorkspaceInfoReq())
        #expect(try decodeJSON(WorkspaceInfoReq.self, #"{"future":true}"#) == WorkspaceInfoReq())

        let ok: RpcEnvelope<WorkspaceInfo> = .ok(info)
        #expect(
            try encodeJSON(ok)
                == #"{"ok":{"cwd":"/workspace","os":"linux","shell":"bash"}}"#
        )
        let err: RpcEnvelope<WorkspaceInfo> = .err(
            RpcError(code: "hub_error", message: "computer hub unavailable")
        )
        let errJSON = try encodeJSON(err)
        #expect(errJSON == #"{"err":{"code":"hub_error","message":"computer hub unavailable"}}"#)
        #expect(try roundTrip(err) == err)
        #expect(err.intoResult().isFailure)
    }

    @Test("process/terminal list_background_tasks golden")
    func processTerminalBackgroundTasks() throws {
        #expect(ListBackgroundTasksReq.method == "workspace.list_background_tasks")
        let reqJSON = #"{"session_id":"sess-hub-1"}"#
        let req = try decodeJSON(ListBackgroundTasksReq.self, reqJSON)
        #expect(req.sessionId == "sess-hub-1")
        #expect(try encodeJSON(req) == reqJSON)

        // Slim TaskSnapshot wire DTO — tool_name omitted when absent.
        let bare = try decodeJSON(
            BackgroundTaskSummaryWire.self,
            #"{"task_id":"bg-1","command":"npm test"}"#
        )
        #expect(bare.toolName == nil)
        #expect(try encodeJSON(bare) == #"{"command":"npm test","task_id":"bg-1"}"#)

        let withTool = BackgroundTaskSummaryWire(
            taskId: "bg-2",
            command: "cargo test --package x",
            toolName: "run_terminal_cmd"
        )
        #expect(
            try encodeJSON(withTool)
                == #"{"command":"cargo test --package x","task_id":"bg-2","tool_name":"run_terminal_cmd"}"#
        )
        #expect(try roundTrip(withTool) == withTool)

        let responseJSON = """
        {"tasks":[\
        {"task_id":"bg-1","command":"sleep 30"},\
        {"task_id":"bg-2","command":"npm run build","tool_name":"run_terminal_cmd"}\
        ]}
        """
        let response = try decodeJSON(ListBackgroundTasksResponse.self, responseJSON)
        #expect(response.tasks.count == 2)
        #expect(response.tasks[0].toolName == nil)
        #expect(response.tasks[1].toolName == "run_terminal_cmd")
        #expect(try roundTrip(response) == response)

        let envelope: RpcEnvelope<ListBackgroundTasksResponse> = .ok(response)
        #expect(try roundTrip(envelope) == envelope)
    }

    @Test("todo list_todos golden + status tags")
    func todoList() throws {
        #expect(ListTodosReq.method == "workspace.list_todos")
        let req = ListTodosReq(sessionId: "s-todo")
        #expect(try encodeJSON(req) == #"{"session_id":"s-todo"}"#)

        let responseJSON = """
        {"todos":[\
        {"id":"t1","content":"write fixtures","status":"completed"},\
        {"id":"t2","content":"run tests","status":"in_progress"},\
        {"id":"t3","content":"ship","status":"pending"},\
        {"id":"t4","content":"rollback","status":"cancelled"}\
        ]}
        """
        let response = try decodeJSON(ListTodosResponse.self, responseJSON)
        #expect(response.todos.map(\.status) == [
            "completed", "in_progress", "pending", "cancelled"
        ])
        #expect(try roundTrip(response) == response)
        #expect(
            try encodeJSON(TodoSummaryWire(id: "t1", content: "x", status: "pending"))
                == #"{"content":"x","id":"t1","status":"pending"}"#
        )
    }

    @Test("foreign-session drop_session + update_tool_config goldens")
    func foreignSessionAdmin() throws {
        // Operating on a session other than the hub-bound caller session.
        let dropJSON = #"{"caller_session_id":"caller-A","session_id":"foreign-B"}"#
        let drop = try decodeJSON(DropSessionReq.self, dropJSON)
        #expect(drop.callerSessionId == "caller-A")
        #expect(drop.sessionId == "foreign-B")
        #expect(try encodeJSON(drop) == dropJSON)
        #expect(DropSessionReq.method == "workspace.drop_session")

        // Empty caller_session_id is skipped on encode (serde skip_serializing_if empty).
        let dropDefault = DropSessionReq(sessionId: "foreign-C")
        #expect(try encodeJSON(dropDefault) == #"{"session_id":"foreign-C"}"#)
        let dropDecoded = try decodeJSON(DropSessionReq.self, #"{"session_id":"foreign-C"}"#)
        #expect(dropDecoded.callerSessionId == "")

        let updateJSON = """
        {"caller_session_id":"caller-A","session_id":"foreign-B",\
        "new_config":{"tools":["read_file"],"mode":"read_only"}}
        """
        let update = try decodeJSON(UpdateToolConfigReq.self, updateJSON)
        #expect(update.sessionId == "foreign-B")
        #expect(update.callerSessionId == "caller-A")
        if case .object(let obj) = update.newConfig {
            #expect(obj["mode"] == .string("read_only"))
        } else {
            Issue.record("expected object new_config")
        }
        #expect(try roundTrip(update) == update)
        #expect(UpdateToolConfigReq.method == "workspace.update_tool_config")

        // TURN_ACTIVE structured failure when mutating a live foreign session.
        let turnActive: RpcEnvelope<JSONValue> = .err(
            RpcError(code: TURN_ACTIVE, message: "session has an active turn")
        )
        #expect(try roundTrip(turnActive) == turnActive)
        if case .err(let e) = turnActive {
            #expect(e.isTurnActive)
            #expect(e.code == "turn_active")
        }
    }

    @Test("capability negotiation wire values + agent session config")
    func capabilityNegotiation() throws {
        #expect(try encodeJSON(CapabilityMode.readWrite) == "\"read_write\"")
        #expect(try encodeJSON(CapabilityMode.readOnly) == "\"read_only\"")
        #expect(try encodeJSON(CapabilityMode.none) == "\"none\"")
        #expect(try roundTrip(CapabilityMode.readOnly) == .readOnly)

        let cfgJSON = """
        {"agent_id":"subagent-explore","isolation":"worktree","capability_mode":"read_only",\
        "tool_config":[{"id":"fs","enabled":true,"command":"/bin/fs","args":{"k":"v"}}],\
        "max_depth":2,"cwd_override":"/tmp/wt","extra_env":{"A":"1"}}
        """
        let cfg = try decodeJSON(AgentSessionConfig.self, cfgJSON)
        #expect(cfg.capabilityMode == .readOnly)
        #expect(cfg.isolation == .worktree)
        #expect(cfg.maxDepth == 2)
        #expect(try roundTrip(cfg) == cfg)

        // Fork request carries the capability negotiation payload.
        let fork = SessionLifecycleRequest.fork(cfg)
        #expect(try roundTrip(fork) == fork)
        let forkJSON = try encodeJSON(fork)
        #expect(forkJSON.contains("\"capability_mode\""))
        #expect(forkJSON.contains("\"read_only\""))
        #expect(!forkJSON.contains("capabilityMode"))
    }

    @Test("cancellation + structured failure + success envelope goldens")
    func cancelSuccessFailure() throws {
        let cancelled = WorkspaceError.cancelled
        #expect(try encodeJSON(cancelled) == #"{"type":"cancelled"}"#)
        #expect(try roundTrip(cancelled) == cancelled)
        #expect(cancelled.isCancelled)
        #expect(!cancelled.isRetryable)

        let timeout = WorkspaceError.timeout(elapsedMs: 1500)
        #expect(try roundTrip(timeout) == timeout)
        #expect(!timeout.isCancelled)

        // Tool-call final with cancelled=true (process/terminal abort path).
        let finalCancelled = ToolChunk.final(ToolCallResult(
            callId: ToolCallId("c-cancel"),
            exitCode: 130,
            summary: "interrupted",
            outputJson: "{}",
            cancelled: true
        ))
        let finalJSON = try encodeJSON(finalCancelled)
        #expect(finalJSON.contains("\"cancelled\":true"))
        #expect(try roundTrip(finalCancelled) == finalCancelled)

        let okUnit: RpcEnvelope<WorkspaceRpcUnit> = .ok(WorkspaceRpcUnit())
        #expect(try encodeJSON(okUnit) == #"{"ok":null}"#)
        #expect(try roundTrip(okUnit) == okUnit)

        let notFound: RpcEnvelope<JSONValue> = .err(
            RpcError(code: "session_not_found", message: "foreign session gone")
        )
        #expect(
            try encodeJSON(notFound)
                == #"{"err":{"code":"session_not_found","message":"foreign session gone"}}"#
        )
    }

    @Test("empty hub RPC requests encode as {} and ignore unknown keys")
    func emptyHubRequests() throws {
        let empties: [(String, () throws -> String)] = [
            ("load_project_config", { try encodeJSON(LoadProjectConfigReq()) }),
            ("load_permissions", { try encodeJSON(LoadPermissionsReq()) }),
            ("load_envrc", { try encodeJSON(LoadEnvrcReq()) }),
            ("install_plugin", { try encodeJSON(InstallPluginReq()) }),
            ("refresh_plugins", { try encodeJSON(RefreshPluginsReq()) }),
            ("discover_agents_md", { try encodeJSON(DiscoverAgentsMdReq()) }),
            ("discover_skills", { try encodeJSON(RPCSkills.DiscoverReq()) }),
            ("discover_plugins", { try encodeJSON(RPCSkills.DiscoverPluginsReq()) }),
            ("hook_registry", { try encodeJSON(HookRegistryReq()) }),
        ]
        for (name, encode) in empties {
            let json = try encode()
            if json != "{}" {
                Issue.record("\(name) must encode as empty object (Rust empty struct), got \(json)")
            }
            #expect(json == "{}")
        }
        #expect(try decodeJSON(LoadPermissionsReq.self, #"{"x":1}"#) == LoadPermissionsReq())
        #expect(try decodeJSON(HookRegistryReq.self, "{}") == HookRegistryReq())
    }

    @Test("unknown future skill scope + hook event preserved")
    func unknownFutureMessages() throws {
        let scope = try decodeJSON(RPCSkills.SkillScope.self, "\"brand_new_scope\"")
        #expect(scope == .unknown("brand_new_scope"))
        #expect(try encodeJSON(scope) == "\"brand_new_scope\"")

        let event = try decodeJSON(HookEventNameWire.self, "\"future_hook_event\"")
        #expect(event == .unknown("future_hook_event"))
        #expect(try encodeJSON(event) == "\"future_hook_event\"")

        // Hook registry map key stays distinct under deploy skew.
        let registryJSON = """
        {"hooks":{"future_hook_event":[\
        {"name":"h1","event":"future_hook_event","handler_type":"command",\
        "enabled":true,"timeout_ms":1000,"source_dir":"/hooks","extra_env":{}}\
        ]}}
        """
        let registry = try decodeJSON(HookRegistryWire.self, registryJSON)
        #expect(registry.hooks.keys.contains(.unknown("future_hook_event")))
        #expect(try roundTrip(registry) == registry)
    }

    @Test("filesystem put/get + process-adjacent permission rule order")
    func filesystemAndPermissionRules() throws {
        #expect(PutFilesReq.method == "workspace.put_files")
        #expect(GetFilesReq.method == "workspace.get_files")

        // Permission policy evaluation order: allow, deny, ask preserved.
        let policyJSON = #"{"allow":["read_file","list_dir"],"deny":["run_terminal_cmd"],"ask":["edit_file"]}"#
        let policy = try decodeJSON(PermissionPolicy.self, policyJSON)
        #expect(policy.allow == ["read_file", "list_dir"])
        #expect(policy.deny == ["run_terminal_cmd"])
        #expect(policy.ask == ["edit_file"])
        #expect(try roundTrip(policy) == policy)

        // Decisions cover allow / deny / allow-once / allow-session / allow-project.
        let decisions: [(PermissionDecision, String)] = [
            (.allowOnce, #"{"type":"allow_once"}"#),
            (.allowSession, #"{"type":"allow_session"}"#),
            (.allowProject, #"{"type":"allow_project"}"#),
            (.deny(reason: "policy"), #"{"data":{"reason":"policy"},"type":"deny"}"#),
        ]
        for (decision, golden) in decisions {
            #expect(try encodeJSON(decision) == golden)
            #expect(try roundTrip(decision) == decision)
        }
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
