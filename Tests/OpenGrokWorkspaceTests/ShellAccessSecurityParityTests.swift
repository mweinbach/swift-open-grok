import Testing
@testable import OpenGrokWorkspace

@Suite("shell file-access policies cannot be bypassed through wrappers or operands")
struct ShellAccessSecurityParityTests {
    private let cwd = "/workspace"

    private func policy(_ tool: ToolFilter, pattern: String = "**/.env") -> CompiledPolicy {
        CompiledPolicy(
            config: PermissionConfig(rules: [
                PermissionRule(
                    action: .deny,
                    tool: tool,
                    pattern: pattern,
                    source: .managedSettings
                ),
            ]),
            pathContext: PathRuleContext(cwd: cwd)
        )
    }

    private func expectDenied(
        _ command: String,
        tool: ToolFilter = .read,
        pattern: String = "**/.env"
    ) {
        let decision = policy(tool, pattern: pattern)
            .evaluateShellFileAccess(command, cwd: cwd)
        guard case .policyDeny = decision else {
            Issue.record("expected managed denial for \(command), received \(String(describing: decision))")
            return
        }
    }

    @Test("literal inline shells recurse into managed read denies", arguments: [
        "bash -c 'cat .env'",
        "sh -c 'cat .env'",
        "dash -c 'cat .env'",
        "zsh -c 'cat .env'",
        "ksh -c 'cat .env'",
        "/bin/bash -c 'cat .env'",
        "bash -lc 'cat .env'",
        "bash -c -x 'cat .env'",
        "bash -c -- 'cat .env'",
        "bash -c -o pipefail 'cat .env'",
        "bash -c -O extglob 'cat .env'",
        "bash -c +O extglob 'cat .env'",
        "timeout 5 bash -c 'cat .env'",
        "bash -c \"sh -c 'cat .env'\"",
        "bash -c 'cat .env' '$IGNORED'",
    ])
    func inlineReadersCannotBypassDenies(_ command: String) {
        expectDenied(command)
    }

    @Test("literal inline shells recurse into redirects and output flags", arguments: [
        "bash -c 'echo secret > .env'",
        "sh -c 'sort README.md -o .env'",
        "timeout 3 bash -c 'tee .env'",
        "bash -c 'exec sed -ni s/old/new/ .env'",
    ])
    func inlineWritersCannotBypassDenies(_ command: String) {
        expectDenied(command, tool: .edit)
    }

    @Test("transparent command and exec prefixes preserve managed denies", arguments: [
        "command cat .env",
        "command -p cat .env",
        "exec cat .env",
        "exec -a harmless-name cat .env",
        "builtin cat .env",
        "/usr/bin/exec cat .env",
        "bash -c 'exec cat .env'",
        "bash -c 'command cat .env'",
        "bash -c 'builtin cat .env'",
        "exec bash -c 'cat .env'",
        "command bash -c 'cat .env'",
        "bash -c 'exec bash -c \"cat .env\"'",
        "exec command builtin exec command builtin exec command cat .env",
    ])
    func transparentWrappersCannotBypassDenies(_ command: String) {
        expectDenied(command)
    }

    @Test("opaque env splitting and unsupported wrapper forms fail closed", arguments: [
        "env -S 'cat .env'",
        "env -S 'bash -c cat'",
        "env --split-string 'cat .env'",
        "env --split-string=cat",
        "env -Scat",
        "/usr/bin/env -S 'cat .env'",
        "timeout 5 env -S 'cat .env'",
        "env -S",
        "exec -u cat .env",
        "command -Z cat .env",
        "bash -c '$SCRIPT'",
        "bash -c",
        "bash -c 'cat",
        "$SHELL -c 'cat .env'",
        "exec exec exec exec exec exec exec exec exec cat .env",
    ])
    func opaqueShellFormsRequireApproval(_ command: String) {
        #expect(policy(.read).evaluateShellFileAccess(command, cwd: cwd) == .ask)
    }

    @Test("ordinary env assignments are transparent but positional equals are filenames", arguments: [
        "env FOO=1 cat .env",
        "env cat .env",
        "/usr/bin/env FOO=1 cat .env",
        "FOO=1 cat .env",
        "timeout 5 env FOO=1 command cat .env",
    ])
    func ordinaryEnvironmentWrappersRemainTransparent(_ command: String) {
        expectDenied(command)
    }

    @Test("positional filenames containing equals are never discarded as assignments")
    func equalsContainingFilenameIsDenyChecked() {
        expectDenied("cat data=v1.env", pattern: "**/data=*.env")
        #expect(
            policy(.read, pattern: "**/data=*.env")
                .evaluateShellFileAccess("FOO=data=v1.env cat README.md", cwd: cwd) == nil
        )
    }

    @Test("directory-recursive searches cannot silently traverse denied files", arguments: [
        "rg secret",
        "ack secret",
        "ag secret",
        "rg secret .",
        "rg secret src/",
        "ag secret .",
        "ack secret ../",
        "grep -r secret .",
        "grep -R secret .",
        "grep --recursive secret .",
    ])
    func recursiveSearchRequiresApproval(_ command: String) {
        #expect(policy(.read).evaluateShellFileAccess(command, cwd: cwd) == .ask)
    }

    @Test("bounded file searches remain allowed while exact denied files still reject")
    func singleFileSearchRemainsPrecise() {
        #expect(policy(.read).evaluateShellFileAccess("rg secret README.md", cwd: cwd) == nil)
        #expect(policy(.read).evaluateShellFileAccess("grep secret README.md", cwd: cwd) == nil)
        expectDenied("rg secret .env")
        expectDenied("grep secret .env")
    }

    @Test("reader auxiliary file options cannot hide managed read denies", arguments: [
        "grep -f .env README.md",
        "rg -f .env README.md",
        "sed -f .env README.md",
        "awk -f .env README.md",
        "comm .env /dev/null",
        "rev .env",
        "select-string secret .env",
        "zgrep secret .env",
        "head -n 5 .env",
        "sed -n 1p .env",
    ])
    func readerFileOptionsAreChecked(_ command: String) {
        expectDenied(command)
    }

    @Test("sort output forms and PowerShell writers enforce edit restrictions", arguments: [
        "sort README.md -o .env",
        "sort -o .env README.md",
        "sort README.md --output .env",
        "sort README.md --output=.env",
        "sort README.md -o.env",
        "sed -i.bak s/old/new/ .env",
        "sed -ni s/old/new/ .env",
        "Set-Content .env secret",
        "Add-Content .env secret",
        "Out-File .env",
        "Tee-Object .env",
    ])
    func outputOptionsAreWrites(_ command: String) {
        expectDenied(command, tool: .edit)
    }

    @Test("deny wins over earlier opaque and recursive ask floors", arguments: [
        "env -S 'cat README.md'; cat .env",
        "rg secret .; cat .env",
        "exec -u cat README.md; cat .env",
        "exec exec exec exec exec exec exec exec exec cat README.md; cat .env",
    ])
    func laterDenyOutranksOpaqueAsk(_ command: String) {
        expectDenied(command)
    }

    @Test("safe display and non-inline forms do not acquire invented restrictions", arguments: [
        "command -v cat",
        "command -V cat",
        "bash -- -c 'cat .env'",
        "bash script.sh -c 'cat .env'",
        "$CMD README.md",
        "python script.py",
    ])
    func benignAndUnsupportedProgramsRemainInert(_ command: String) {
        #expect(policy(.read).evaluateShellFileAccess(command, cwd: cwd) == nil)
    }

    @Test("managed file denies defeat broad Bash approval through the real permission handle", arguments: [
        "bash -c 'cat .env'",
        "command cat .env",
        "env FOO=1 exec cat .env",
        "rg secret .env",
        "grep -f .env README.md",
    ])
    func liveManagedReadDenyDefeatsBroadBashApproval(_ command: String) async {
        let permissions = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(action: .allow, tool: .bash, source: .config),
                PermissionRule(action: .deny, tool: .read, pattern: "**/.env", source: .managedSettings),
            ]),
            allowAll: true,
            shellCwd: cwd
        )

        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "managed-shell-read-deny"
        )

        guard case .policyDeny = decision else {
            Issue.record("broad Bash approval bypassed managed read deny for \(command): \(decision)")
            return
        }
        #expect(await permissions.events.last?.decisionReason == "shell_file_access")
    }

    @Test("managed edit denies defeat broad Bash approval for hidden output flags", arguments: [
        "sort README.md -o .env",
        "bash -c 'sort README.md --output=.env'",
        "command sed -ni s/old/new/ .env",
    ])
    func liveManagedEditDenyDefeatsBroadBashApproval(_ command: String) async {
        let permissions = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(action: .allow, tool: .bash, source: .config),
                PermissionRule(action: .deny, tool: .edit, pattern: "**/.env", source: .managedSettings),
            ]),
            allowAll: true,
            shellCwd: cwd
        )

        let decision = await permissions.request(
            access: .bash(command),
            toolName: "bash",
            toolCallId: "managed-shell-edit-deny"
        )

        guard case .policyDeny = decision else {
            Issue.record("broad Bash approval bypassed managed edit deny for \(command): \(decision)")
            return
        }
        #expect(await permissions.events.last?.decisionReason == "shell_file_access")
    }
}
