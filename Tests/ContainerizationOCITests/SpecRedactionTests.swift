//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import ContainerizationOCI

@Suite("Spec redaction")
struct SpecRedactionTests {
    private static let secret = "hunter2"
    private static let hookSecret = "abc123"

    private func spec() -> Spec {
        Spec(
            hooks: Hooks(
                prestart: [],
                createRuntime: [],
                createContainer: [],
                startContainer: [],
                poststart: [Hook(path: "/hook", args: [], env: ["HOOK_TOKEN=\(Self.hookSecret)"], timeout: nil)],
                poststop: []
            ),
            process: Process(env: ["PATH=/usr/bin", "PASSWORD=\(Self.secret)", "INHERIT_ME"])
        )
    }

    @Test func interpolatingASpecNeverRendersEnvironmentValues() {
        let rendered = "\(spec())"
        #expect(!rendered.contains(Self.secret))
        #expect(!rendered.contains(Self.hookSecret))
        #expect(rendered.contains("PASSWORD=<redacted>"))
        #expect(rendered.contains("HOOK_TOKEN=<redacted>"))
    }

    @Test func everyTextRenderingIsRedacted() {
        let s = spec()
        for rendered in ["\(s)", String(describing: s), String(reflecting: s)] {
            #expect(!rendered.contains(Self.secret))
            #expect(!rendered.contains(Self.hookSecret))
        }
    }

    @Test func variableNamesSurviveSoLogsStayUseful() {
        let rendered = "\(spec())"
        #expect(rendered.contains("PATH="))
        #expect(rendered.contains("PASSWORD="))
    }

    @Test func inheritedEntriesArePreserved() {
        #expect("\(spec())".contains("INHERIT_ME"))
    }

    @Test(arguments: [
        "EMPTY=",
        "CONNECTION=postgres://user:pw@host/db?sslmode=require",
    ])
    func valuesAreMaskedWholeIncludingAnyFurtherEquals(_ entry: String) {
        let name = String(entry[entry.startIndex..<entry.firstIndex(of: "=")!])
        let rendered = "\(Process(env: [entry]))"
        #expect(rendered.contains("\(name)=<redacted>"))
        if let value = entry.split(separator: "=", maxSplits: 1).last, entry.hasSuffix(String(value)), value != name {
            #expect(!rendered.contains(String(value)))
        }
    }

    @Test func encodingIsUnaffected() throws {
        let data = try JSONEncoder().encode(spec())
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(Self.secret))
        #expect(json.contains(Self.hookSecret))

        let decoded = try JSONDecoder().decode(Spec.self, from: data)
        #expect(decoded.process?.env == ["PATH=/usr/bin", "PASSWORD=\(Self.secret)", "INHERIT_ME"])
        #expect(decoded.hooks?.poststart.first?.env == ["HOOK_TOKEN=\(Self.hookSecret)"])
    }

    @Test func theValuesRemainAvailableToCallers() {
        #expect(spec().process?.env.contains("PASSWORD=\(Self.secret)") == true)
    }

    @Test func renderingIsNonMutating() {
        let s = spec()
        _ = "\(s)"
        #expect(s.process?.env == ["PATH=/usr/bin", "PASSWORD=\(Self.secret)", "INHERIT_ME"])
    }

    @Test func theOtherFieldsAreStillRendered() {
        let rendered = "\(Process(args: ["/bin/sh"], cwd: "/work", env: ["A=b"], terminal: true))"
        #expect(rendered.contains("cwd:"))
        #expect(rendered.contains("/work"))
        #expect(rendered.contains("args:"))
        #expect(rendered.contains("/bin/sh"))
        #expect(rendered.contains("terminal:"))
    }

    @Test func processEnvironmentValuesCanBeRedactedExplicitly() {
        let process = Process(
            args: ["python3", "-m", "http.server"],
            cwd: "/app",
            env: [
                "PATH=/usr/local/bin:/usr/bin",
                "MY_SUPER_SECRET_PASSWORD=guest",
                "EMPTY=",
                "TOKEN=abc=def",
                "INHERITED_NO_VALUE",
            ]
        )

        let redacted = process.redactingEnvironmentValues()

        #expect(
            redacted.env == [
                "PATH=<redacted>",
                "MY_SUPER_SECRET_PASSWORD=<redacted>",
                "EMPTY=<redacted>",
                "TOKEN=<redacted>",
                "INHERITED_NO_VALUE",
            ])
        #expect(redacted.args == process.args)
        #expect(redacted.cwd == process.cwd)
        #expect(process.env.contains("MY_SUPER_SECRET_PASSWORD=guest"))
    }

    @Test func specRedactsProcessAndHookEnvironmentsExplicitly() {
        let hook = Hook(
            path: "/usr/local/bin/hook",
            args: ["hook"],
            env: ["HOOK_SECRET=\(Self.hookSecret)"],
            timeout: nil
        )
        let spec = Spec(
            hooks: Hooks(
                prestart: [hook],
                createRuntime: [hook],
                createContainer: [hook],
                startContainer: [hook],
                poststart: [hook],
                poststop: [hook]
            ),
            process: Process(env: ["MY_SUPER_SECRET_PASSWORD=\(Self.secret)"]),
            hostname: "web",
            mounts: [Mount(type: "proc", source: "proc", destination: "/proc")]
        )

        let redacted = spec.redactingEnvironmentValues()
        let logged = "\(redacted)"

        #expect(!logged.contains(Self.secret))
        #expect(!logged.contains(Self.hookSecret))
        #expect(logged.contains("MY_SUPER_SECRET_PASSWORD"))
        #expect(logged.contains("HOOK_SECRET"))
        #expect(redacted.hostname == spec.hostname)
        #expect(redacted.mounts.count == spec.mounts.count)
        #expect(redacted.process?.env == ["MY_SUPER_SECRET_PASSWORD=<redacted>"])
        #expect(redacted.hooks?.prestart.first?.env == ["HOOK_SECRET=<redacted>"])
        #expect(redacted.hooks?.poststop.first?.env == ["HOOK_SECRET=<redacted>"])
        #expect(spec.process?.env == ["MY_SUPER_SECRET_PASSWORD=\(Self.secret)"])
    }

    @Test func specWithoutProcessOrHooksIsUnchanged() {
        let spec = Spec(version: "1.2.0")
        let redacted = spec.redactingEnvironmentValues()
        #expect(redacted.process == nil)
        #expect(redacted.hooks == nil)
        #expect(redacted.version == spec.version)
    }
}
