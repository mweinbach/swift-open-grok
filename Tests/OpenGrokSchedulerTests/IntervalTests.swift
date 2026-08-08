// IntervalTests.swift
//
// Golden parity with upstream's interval tests (`interval.rs:78-165`), plus
// error-message goldens for the strings `scheduler_tool_error` surfaces to
// the model. Every table value below is copied from the Rust test, not
// re-derived.

import Foundation
import Testing
import OpenGrokScheduler

@Suite("Interval parsing")
struct IntervalParseTests {
    // interval.rs:82-87
    @Test("parse minutes")
    func parseMinutes() throws {
        #expect(try parseInterval("5m") == 300)
        #expect(try parseInterval("10m") == 600)
        #expect(try parseInterval("1m") == 60)
    }

    // interval.rs:89-93
    @Test("parse hours")
    func parseHours() throws {
        #expect(try parseInterval("2h") == 7200)
        #expect(try parseInterval("1h") == 3600)
    }

    // interval.rs:95-99
    @Test("parse days")
    func parseDays() throws {
        #expect(try parseInterval("1d") == 86400)
        #expect(try parseInterval("7d") == 604800)
    }

    // interval.rs:101-107 — the 60s minimum is a clamp, not an error.
    @Test("parse seconds clamped to minimum")
    func parseSecondsClampedToMinimum() throws {
        #expect(try parseInterval("30s") == 60)
        #expect(try parseInterval("1s") == 60)
        #expect(try parseInterval("60s") == 60)
        #expect(try parseInterval("120s") == 120)
    }

    // interval.rs:109-112
    @Test("parse empty returns error")
    func parseEmptyReturnsError() {
        #expect(throws: SchedulerError.invalidInterval("interval cannot be empty")) {
            try parseInterval("")
        }
        // Trim happens before the empty check (interval.rs:8-13).
        #expect(throws: SchedulerError.invalidInterval("interval cannot be empty")) {
            try parseInterval("   ")
        }
    }

    // interval.rs:114-119
    @Test("parse invalid format returns error")
    func parseInvalidFormatReturnsError() {
        #expect(throws: SchedulerError.invalidInterval(
            "invalid interval format: \"abc\" (expected e.g. 5m, 2h, 1d)"
        )) {
            try parseInterval("abc")
        }
        // "5x": digits parse, the suffix is what fails (interval.rs:33-37).
        #expect(throws: SchedulerError.invalidInterval(
            "invalid interval suffix: \"x\" (expected s, m, h, or d)"
        )) {
            try parseInterval("5x")
        }
        // "m": empty digits fail the numeric parse, not the suffix match.
        #expect(throws: SchedulerError.invalidInterval(
            "invalid interval format: \"m\" (expected e.g. 5m, 2h, 1d)"
        )) {
            try parseInterval("m")
        }
    }

    // interval.rs:121-125
    @Test("parse zero returns error")
    func parseZeroReturnsError() {
        #expect(throws: SchedulerError.invalidInterval("interval value must be greater than 0")) {
            try parseInterval("0m")
        }
        #expect(throws: SchedulerError.invalidInterval("interval value must be greater than 0")) {
            try parseInterval("0s")
        }
    }

    // interval.rs:127-134 — digits parse as u64 but the unit multiplication
    // overflows; must surface an error, not trap or wrap.
    @Test("parse overflow returns error")
    func parseOverflowReturnsError() throws {
        #expect(throws: SchedulerError.invalidInterval(
            "interval too large: \"1000000000000000000d\""
        )) {
            try parseInterval("1000000000000000000d")
        }
        #expect(try parseInterval("\(UInt64.max)s") == UInt64.max)
        #expect(throws: SchedulerError.self) {
            try parseInterval("\(UInt64.max)d")
        }
    }

    // interval.rs:161-164
    @Test("parse with whitespace")
    func parseWithWhitespace() throws {
        #expect(try parseInterval("  5m  ") == 300)
    }

    // types.rs:160-161 wraps the detail as "invalid interval: {0}" — the
    // string the create tool hands back verbatim (create.rs:171-176).
    @Test("error description carries upstream display prefix")
    func errorDescription() {
        #expect(
            SchedulerError.invalidInterval("interval cannot be empty").description
                == "invalid interval: interval cannot be empty"
        )
        #expect(
            SchedulerError.taskLimitReached(50).description
                == "maximum of 50 scheduled tasks reached"
        )
        #expect(
            SchedulerError.taskNotFound("abc123").description
                == "no scheduled task with id abc123; call scheduler_list to see active task ids"
        )
    }
}

@Suite("Interval to human")
struct IntervalToHumanTests {
    // interval.rs:136-141
    @Test("human readable minutes")
    func humanReadableMinutes() {
        #expect(intervalToHuman(300) == "every 5 minutes")
        #expect(intervalToHuman(60) == "every 1 minute")
        #expect(intervalToHuman(600) == "every 10 minutes")
    }

    // interval.rs:143-147
    @Test("human readable hours")
    func humanReadableHours() {
        #expect(intervalToHuman(3600) == "every 1 hour")
        #expect(intervalToHuman(7200) == "every 2 hours")
    }

    // interval.rs:149-153
    @Test("human readable days")
    func humanReadableDays() {
        #expect(intervalToHuman(86400) == "every 1 day")
        #expect(intervalToHuman(172800) == "every 2 days")
    }

    // interval.rs:155-159
    @Test("human readable seconds")
    func humanReadableSeconds() {
        #expect(intervalToHuman(45) == "every 45 seconds")
        #expect(intervalToHuman(1) == "every 1 second")
    }
}
