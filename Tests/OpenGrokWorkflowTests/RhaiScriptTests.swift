import Foundation
import Testing
@testable import OpenGrokWorkflow
import OpenGrokShared

/// Language-level tests: every construct in the supported subset, and a
/// rejection test for each construct deliberately left out.
@Suite("RhaiScript")
struct RhaiScriptTests {
    /// Runs a script with no host traffic and returns the completion value.
    private func evaluate(
        _ body: String,
        arguments: JSONValue = .object([:])
    ) async -> RhaiWorkflowOutcome {
        await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: #"let meta = #{ name: "t", description: "d" };"# + "\n" + body,
            arguments: arguments,
            journal: RhaiJournal(clock: { 1 }),
            host: RhaiProbeHost()
        ))
    }

    private func complete(_ body: String, arguments: JSONValue = .object([:])) async throws -> JSONValue {
        let outcome = await evaluate(body, arguments: arguments)
        guard case .completed(let result) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return .null
        }
        return result
    }

    private func failure(_ body: String) async -> String {
        let outcome = await evaluate(body)
        guard case .failed(let error) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return ""
        }
        return error
    }

    // MARK: Literals and operators

    @Test("literals of every supported kind round-trip")
    func literals() async throws {
        #expect(try await complete(#"complete(42);"#) == .number(.int64(42)))
        #expect(try await complete(#"complete(1.5);"#) == .number(.double(1.5)))
        #expect(try await complete(#"complete("hi");"#) == .string("hi"))
        #expect(try await complete(#"complete(true);"#) == .bool(true))
        #expect(try await complete(#"complete(());"#) == .null)
        #expect(try await complete(#"complete([1, "a", true]);"#)
            == .array([.number(.int64(1)), .string("a"), .bool(true)]))
        #expect(try await complete(#"complete(#{ a: 1, "b": [2] });"#)
            == .object(["a": .number(.int64(1)), "b": .array([.number(.int64(2))])]))
    }

    @Test("arithmetic, comparison, and logical operators")
    func operators() async throws {
        #expect(try await complete("complete(2 + 3 * 4);") == .number(.int64(14)))
        #expect(try await complete("complete((2 + 3) * 4);") == .number(.int64(20)))
        #expect(try await complete("complete(7 % 3);") == .number(.int64(1)))
        #expect(try await complete("complete(7 / 2);") == .number(.int64(3)))
        #expect(try await complete("complete(1 < 2 && 3 >= 3);") == .bool(true))
        #expect(try await complete("complete(!false || false);") == .bool(true))
        #expect(try await complete(#"complete("a" + "b" + 1.to_string());"#) == .string("ab1"))
        #expect(try await complete("complete(-5);") == .number(.int64(-5)))
    }

    @Test("`&&` and `||` short-circuit rather than evaluating both sides")
    func shortCircuits() async throws {
        // The right operand would throw if it were evaluated.
        #expect(try await complete("complete(false && undefined_variable);") == .bool(false))
        #expect(try await complete("complete(true || undefined_variable);") == .bool(true))
    }

    @Test("mismatched types compare unequal instead of erroring")
    func mixedEquality() async throws {
        // `r == ()` guards appear all over the shipped workflows.
        #expect(try await complete(#"let r = #{ a: 1 }; complete(r == ());"#) == .bool(false))
        #expect(try await complete(#"complete(() == ());"#) == .bool(true))
        #expect(try await complete(#"complete("1" == 1);"#) == .bool(false))
    }

    // MARK: Control flow

    @Test("if / else if / else as both statement and expression")
    func conditionals() async throws {
        #expect(try await complete("""
        let x = 2;
        let label = if x == 1 { "one" } else if x == 2 { "two" } else { "many" };
        complete(label);
        """) == .string("two"))

        #expect(try await complete("""
        let out = "";
        if false { out = "a"; } else { out = "b"; }
        complete(out);
        """) == .string("b"))
    }

    @Test("while, for-in, ranges, break, and continue")
    func loops() async throws {
        #expect(try await complete("""
        let total = 0;
        let i = 0;
        while i < 5 { total += i; i += 1; }
        complete(total);
        """) == .number(.int64(10)))

        #expect(try await complete("""
        let seen = [];
        for item in [1, 2, 3, 4] {
            if item == 2 { continue; }
            if item == 4 { break; }
            seen.push(item);
        }
        complete(seen);
        """) == .array([.number(.int64(1)), .number(.int64(3))]))

        #expect(try await complete("""
        let total = 0;
        for i in 0..4 { total += i; }
        complete(total);
        """) == .number(.int64(6)))

        #expect(try await complete("""
        let total = 0;
        for i in 0..=4 { total += i; }
        complete(total);
        """) == .number(.int64(10)))
    }

    @Test("loop runs until break")
    func loopForever() async throws {
        #expect(try await complete("""
        let n = 0;
        loop { n += 1; if n == 3 { break; } }
        complete(n);
        """) == .number(.int64(3)))
    }

    @Test("functions take parameters, return values, and do not see caller locals")
    func functions() async throws {
        #expect(try await complete("""
        fn add(a, b) { a + b }
        complete(add(2, 3));
        """) == .number(.int64(5)))

        #expect(try await complete("""
        fn early(x) { if x > 0 { return "positive"; } "other" }
        complete(early(1));
        """) == .string("positive"))

        let error = await failure("""
        let outer = 1;
        fn peek() { outer }
        complete(peek());
        """)
        #expect(error.contains("`outer` is not defined"))
    }

    @Test("closures capture by value and drive map/filter")
    func closures() async throws {
        #expect(try await complete("""
        let doubled = [1, 2, 3].map(|n| n * 2);
        complete(doubled);
        """) == .array([.number(.int64(2)), .number(.int64(4)), .number(.int64(6))]))

        #expect(try await complete("""
        let kept = [1, 2, 3, 4].filter(|n| n % 2 == 0);
        complete(kept);
        """) == .array([.number(.int64(2)), .number(.int64(4))]))

        #expect(try await complete("""
        let results = [#{ output: "a" }, ()];
        let summary = results.map(|r| if r == () { "null" } else { r.output });
        complete(summary);
        """) == .array([.string("a"), .string("null")]))
    }

    @Test("try / catch binds the error message and only catches runtime errors")
    func tryCatch() async throws {
        #expect(try await complete("""
        let out = "";
        try { out = missing_function(); } catch (e) { out = "caught:" + e; }
        complete(out);
        """) == .string("caught:function not found: missing_function"))

        // `complete` is terminal, not catchable: the catch block never runs.
        #expect(try await complete("""
        try { complete("inner"); } catch (e) { complete("caught"); }
        """) == .string("inner"))
    }

    // MARK: Data access

    @Test("member access, indexing, and missing keys")
    func access() async throws {
        #expect(try await complete(#"let m = #{ a: #{ b: 7 } }; complete(m.a.b);"#) == .number(.int64(7)))
        #expect(try await complete(#"let m = #{ a: 1 }; complete(m["a"]);"#) == .number(.int64(1)))
        // A missing map key is `()`, which is what `args.task != ()` relies on.
        #expect(try await complete(#"let m = #{ a: 1 }; complete(m.missing);"#) == .null)
        #expect(try await complete("complete([10, 20][1]);") == .number(.int64(20)))

        let error = await failure("complete([1][5]);")
        #expect(error.contains("array index out of bounds"))
    }

    @Test("nested assignment writes back through maps and arrays")
    func nestedAssignment() async throws {
        #expect(try await complete("""
        let m = #{ a: #{ b: 1 } };
        m.a.b = 2;
        complete(m.a.b);
        """) == .number(.int64(2)))

        #expect(try await complete("""
        let rows = [#{ n: 1 }, #{ n: 2 }];
        rows[1].n = 9;
        complete(rows[1].n);
        """) == .number(.int64(9)))
    }

    @Test("args are visible to the script (engine.rs:1172)")
    func argumentsAreVisible() async throws {
        let arguments = JSONValue.object([
            "objective": .string("test"),
            "breadth": .number(.int64(4)),
        ])
        #expect(try await complete("complete(args.objective);", arguments: arguments) == .string("test"))
        // A JSON integer must still look like an `i64` to `type_of`, which the
        // shipped workflows check before accepting a numeric argument.
        #expect(try await complete(#"complete(type_of(args.breadth));"#, arguments: arguments)
            == .string("i64"))
    }

    // MARK: Methods and builtins

    @Test("mutating methods write through to the receiver variable")
    func mutatingMethods() async throws {
        // The shipped `fn trimmed(s) { s.trim(); s }` idiom depends on this.
        #expect(try await complete("""
        fn trimmed(s) { if type_of(s) == "string" { s.trim(); s } else { "" } }
        complete(trimmed("  padded  "));
        """) == .string("padded"))

        #expect(try await complete("""
        let items = [];
        items.push("a");
        items.push("b");
        complete(items.len());
        """) == .number(.int64(2)))
    }

    @Test("string and array methods behave as the workflows expect")
    func methods() async throws {
        #expect(try await complete(#"complete("a,b,c".split(","));"#)
            == .array([.string("a"), .string("b"), .string("c")]))
        #expect(try await complete(#"complete("hello".sub_string(1, 3));"#) == .string("ell"))
        #expect(try await complete(#"complete("hello".contains("ell"));"#) == .bool(true))
        #expect(try await complete(#"complete([1,2,3].len());"#) == .number(.int64(3)))
        #expect(try await complete(#"complete(#{ b: 1, a: 2 }.keys());"#)
            == .array([.string("a"), .string("b")]))
        #expect(try await complete(#"complete(42.to_string());"#) == .string("42"))
    }

    @Test("type_of reports Rhai's type names")
    func typeOf() async throws {
        #expect(try await complete(#"complete(type_of("s"));"#) == .string("string"))
        #expect(try await complete("complete(type_of(1));") == .string("i64"))
        #expect(try await complete("complete(type_of(1.5));") == .string("f64"))
        #expect(try await complete("complete(type_of(true));") == .string("bool"))
        #expect(try await complete("complete(type_of(()));") == .string("()"))
        #expect(try await complete("complete(type_of([1]));") == .string("array"))
        #expect(try await complete(#"complete(type_of(#{ a: 1 }));"#) == .string("map"))
    }

    @Test("json_encode quotes untrusted strings (engine.rs:1479)")
    func jsonEncode() async throws {
        #expect(try await complete(#"complete(json_encode("</tag>\nquoted"));"#)
            == .string(#""</tag>\nquoted""#))
        #expect(try await complete(#"complete(json_encode(#{ b: 1, a: 2 }));"#)
            == .string(#"{"a":2,"b":1}"#))
    }

    @Test("fingerprint is pure and stable (engine.rs:1464)")
    func fingerprint() async throws {
        #expect(try await complete(#"complete(fingerprint("abc") == fingerprint("abc"));"#) == .bool(true))
        #expect(try await complete(#"complete(fingerprint("abc"));"#)
            == .string("ec7fe10b83b9c6454d1166fe7ea063f5"))
    }

    @Test("a script that falls off the end completes with its last value")
    func implicitCompletion() async throws {
        let outcome = await evaluate("let x = 3; x + 1;")
        #expect(outcome == .completed(result: .number(.int64(4))))
    }

    // MARK: Determinism guards

    @Test("timestamp, sleep, and exit are refused with their reasons (engine.rs:128)")
    func nondeterministicBuiltinsAreRefused() async {
        #expect(await failure("let t = timestamp(); complete(t);").contains("deterministic"))
        #expect(await failure("sleep(1); complete(1);").contains("host calls already block"))
        #expect(await failure("exit();").contains("complete(value) or pause(kind, msg)"))
        #expect(await failure(#"eval("1");"#).contains("eval() is disabled"))
    }

    // MARK: Out-of-subset rejections

    @Test("constructs outside the subset are rejected by name, not mis-executed")
    func outOfSubsetConstructsAreRejected() async {
        let cases: [(script: String, expected: String)] = [
            ("switch x { 1 => 2 }", "`switch` is outside the supported"),
            ("do { let a = 1; } while true;", "`do` is outside the supported"),
            (#"import "x" as y;"#, "`import` is outside the supported"),
            (#"throw "boom";"#, "`throw` is outside the supported"),
            ("let shared = 1;", "reserved keyword"),
            ("let x = 1", "let y = 2"),
        ]
        for testCase in cases.dropLast() {
            let error = await failure(testCase.script)
            #expect(
                error.contains(testCase.expected),
                "expected \(testCase.expected) for \(testCase.script), got: \(error)"
            )
        }
    }

    @Test("a syntax error names the position and never runs the script")
    func syntaxErrorsAreReported() async {
        let error = await failure("let x = ;")
        #expect(error.contains("script failed to compile"))
        #expect(error.contains("line"))

        let unclosed = await failure("if true { complete(1);")
        #expect(unclosed.contains("unterminated block"))
    }

    @Test("an unknown method reports the method and receiver type")
    func unknownMethodIsRejected() async {
        let error = await failure(#"complete("abc".rotate13());"#)
        #expect(error.contains("`rotate13`"))
        #expect(error.contains("string"))
    }

    @Test("a non-boolean condition is an error rather than a coercion")
    func nonBooleanConditionIsRejected() async {
        let error = await failure(#"if "yes" { complete(1); }"#)
        #expect(error.contains("expected a boolean condition"))
    }

    @Test("field access on a non-map carries the upstream authoring hint")
    func fieldAccessHint() async {
        // lib.rs:27 attaches a hint to this exact Rhai message.
        let error = await failure(#"let s = "abc"; complete(s[0].severity);"#)
        #expect(error.contains("getter is not registered"))
        #expect(error.contains("indexing a string"))
    }

    @Test("a runaway loop stops at the operation ceiling")
    func operationCeiling() async {
        var limits = RhaiInterpreterLimits()
        limits.maxOperations = 5_000
        let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: """
            let meta = #{ name: "t", description: "d" };
            let x = 0;
            loop { x += 1; }
            """,
            journal: RhaiJournal(clock: { 1 }),
            host: RhaiProbeHost(),
            limits: limits
        ))
        guard case .failed(let error) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(error.contains("maximum of 5000 operations"))
    }

    @Test("cancellation wins over a pure loop (engine.rs:1232)")
    func cancellationWins() async {
        let cancellation = RhaiCancellationToken()
        cancellation.cancel()
        let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: """
            let meta = #{ name: "t", description: "d" };
            let x = 0;
            loop { x += 1; }
            """,
            journal: RhaiJournal(clock: { 1 }),
            host: RhaiProbeHost(),
            cancellation: cancellation
        ))
        #expect(outcome == .cancelled)
    }
}
