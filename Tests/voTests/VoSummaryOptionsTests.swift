import ArgumentParser
import Foundation
import Testing
@testable import vo

@Suite("Vo CLI summary options")
struct VoSummaryOptionsTests {
    @Test func summaryFlagWithoutValue() throws {
        let vo = try Vo.parse(["--summary"])
        #expect(vo.summary == "")
        #expect(vo.summaryOut == nil)
    }

    @Test func summaryOptionWithValue() throws {
        let vo = try Vo.parse(["--summary", "min.md"])
        #expect(vo.summary == "min.md")
        #expect(vo.summaryOut == nil)
    }

    @Test func summaryOptionWithEqualSign() throws {
        let vo = try Vo.parse(["--summary=min.md"])
        #expect(vo.summary == "min.md")
        #expect(vo.summaryOut == nil)
    }

    @Test func summaryWithoutValueFollowedByAnotherFlag() throws {
        let vo = try Vo.parse(["--summary", "--json"])
        #expect(vo.summary == "")
        #expect(vo.json == true)
    }

    @Test func summaryNotSpecified() throws {
        let vo = try Vo.parse([])
        #expect(vo.summary == nil)
        #expect(vo.summaryOut == nil)
    }

    @Test func summaryOutBackwardCompatibility() throws {
        let vo = try Vo.parse(["--summary-out", "min.md"])
        #expect(vo.summary == nil)
        #expect(vo.summaryOut == "min.md")
    }

    @Test func summaryAndSummaryOutTogether() throws {
        let vo = try Vo.parse(["--summary", "--summary-out", "min.md"])
        #expect(vo.summary == "")
        #expect(vo.summaryOut == "min.md")
    }
}
