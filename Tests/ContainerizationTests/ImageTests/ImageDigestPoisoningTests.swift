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

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
@preconcurrency import Crypto
import Foundation
import Testing

@testable import Containerization

/// Regression tests for a registry supplied digest reaching the filesystem.
///
/// A platform specific pull walks an index, drops the entries whose platform does
/// not match, and only then fetches and digest verifies what is left. An entry for
/// a platform the caller never asked for is therefore never content verified, yet
/// the index that lists it is stored and re-read on later operations. These tests
/// pin that a traversing digest cannot survive that path, and that a store already
/// carrying one fails closed rather than reading or deleting outside itself.
@Suite
struct ImageDigestPoisoningTests {
    private static let traversal = "sha256:../../secret.txt"
    private static let healthyIndexJSON = "{\"schemaVersion\":2,\"manifests\":[]}"

    private struct Fixture {
        let dir: URL
        let store: ImageStore
        let contentStore: LocalContentStore
        let sentinel: URL
        let sentinelContents = "do not read me"
    }

    private func makeFixture() throws -> Fixture {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        let cs = try LocalContentStore(path: dir)
        let store = try ImageStore(path: dir, contentStore: cs)

        // Blobs live at <dir>/blobs/sha256, so "../../secret.txt" lands here.
        let sentinel = dir.appendingPathComponent("secret.txt")
        let fixture = Fixture(dir: dir, store: store, contentStore: cs, sentinel: sentinel)
        try Data(fixture.sentinelContents.utf8).write(to: sentinel)
        return fixture
    }

    /// Builds the index a poisoned multi-arch pull would leave behind, using the
    /// memberwise initializer to bypass decode validation the way a store
    /// poisoned before this fix would have.
    private func seedPoisonedImage(_ fixture: Fixture, reference: String) async throws -> Containerization.Image {
        let manifestData = Data("{\"schemaVersion\":2}".utf8)
        let manifestDigest = SHA256.hash(data: manifestData)

        let matching = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestDigest.digestString,
            size: Int64(manifestData.count),
            platform: Platform(arch: "arm64", os: "linux"))
        let poisoned = Descriptor(
            mediaType: "application/vnd.test.opaque.v1+json",
            digest: Self.traversal,
            size: 1,
            platform: Platform(arch: "ppc64le", os: "linux"))

        let index = Index(manifests: [matching, poisoned])
        let indexData = try JSONEncoder().encode(index)
        let indexDigest = SHA256.hash(data: indexData)

        try await fixture.contentStore.ingest { ingestDir in
            try manifestData.write(to: ingestDir.appendingPathComponent(manifestDigest.encoded))
            try indexData.write(to: ingestDir.appendingPathComponent(indexDigest.encoded))
        }

        let indexDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: indexDigest.digestString,
            size: Int64(indexData.count))
        return try await fixture.store.create(
            description: Containerization.Image.Description(reference: reference, descriptor: indexDescriptor))
    }

    @Test func poisonedIndexFailsClosedInsteadOfReadingOutsideTheStore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let image = try await seedPoisonedImage(fixture, reference: "test/poison:v1")

        // The index blob is content addressed and intact, but it lists a digest
        // that cannot be a blob name, so decoding it must fail rather than
        // resolve the traversal.
        await #expect(throws: (any Swift.Error).self) {
            try await image.index()
        }
        await #expect(throws: (any Swift.Error).self) {
            try await image.referencedDigests()
        }

        #expect(FileManager.default.fileExists(atPath: fixture.sentinel.path))
        let contents = try String(contentsOf: fixture.sentinel, encoding: .utf8)
        #expect(contents == fixture.sentinelContents)
    }

    @Test func getContentRejectsTraversingDigest() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let image = try await seedPoisonedImage(fixture, reference: "test/poison:v2")

        // The referencedDigests membership check is not validation: a digest the
        // attacker listed is trivially in its own allow list. The digest itself
        // has to be rejected.
        do {
            _ = try await image.getContent(digest: Self.traversal)
            Issue.record("expected a traversing digest to be rejected")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidArgument)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.sentinel.path))
    }

    /// Garbage collection has to fail closed. If it treated an unreadable index
    /// as "this image references nothing", every blob belonging to it would be
    /// deleted as orphaned.
    @Test func cleanupFailsClosedAndDeletesNothing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        _ = try await seedPoisonedImage(fixture, reference: "test/poison:v3")

        let blobs = fixture.dir.appendingPathComponent("blobs/sha256")
        let before = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        #expect(before.count == 2)

        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.cleanUpOrphanedBlobs()
        }

        let after = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        #expect(after == before)
        #expect(FileManager.default.fileExists(atPath: fixture.sentinel.path))
    }

    /// A poisoned index blob must not take the rest of the store down with it.
    @Test func storeRemainsUsableAlongsideAPoisonedRecord() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        _ = try await seedPoisonedImage(fixture, reference: "test/poison:v4")
        let healthyDigest = try await seedHealthyImage(fixture, reference: "test/healthy:v1")

        let listed = try await fixture.store.list().map { $0.reference }.sorted()
        #expect(listed.contains("test/healthy:v1"))

        let healthy = try await fixture.store.get(reference: "test/healthy:v1")
        let referenced = try await healthy.referencedDigests()
        #expect(referenced == [healthyDigest.encoded])
    }

    /// The state file is decoded per record, so a record whose own descriptor
    /// digest is malformed is skipped instead of making every image in the store
    /// unreachable. Without this, adding decode validation would turn a poisoned
    /// or legacy record into a total outage: listing, pulling and deleting all
    /// load this file.
    @Test func stateFileSkipsUnreadableRecords() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let healthyDigest = try await seedHealthyImage(fixture, reference: "test/healthy:v1")

        let state = """
            {
              "test/healthy:v1": {"mediaType":"application/vnd.oci.image.index.v1+json","digest":"\(healthyDigest.digestString)","size":\(Self.healthyIndexJSON.utf8.count)},
              "test/broken:v1": {"mediaType":"application/vnd.oci.image.index.v1+json","digest":"\(Self.traversal)","size":1}
            }
            """
        try Data(state.utf8).write(to: fixture.dir.appendingPathComponent("state.json"))

        let listed = try await fixture.store.list().map { $0.reference }
        #expect(listed == ["test/healthy:v1"])

        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.get(reference: "test/broken:v1")
        }
    }

    /// A descriptor whose root digest is valid can still reference live content
    /// even when another field is unreadable. Loading must fail closed instead of
    /// omitting that digest from garbage collection's keep set.
    @Test(arguments: [false, true])
    func cleanupPreservesContentForRecordWithValidDigestAndInvalidMetadata(usesBareDigest: Bool) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let healthyDigest = try await seedHealthyImage(fixture, reference: "test/healthy:v1")
        let persistedDigest = usesBareDigest ? healthyDigest.encoded : healthyDigest.digestString
        let persistedSize = usesBareDigest ? Self.healthyIndexJSON.utf8.count : -1
        let state = """
            {
              "test/broken:v1": {"mediaType":"application/vnd.oci.image.index.v1+json","digest":"\(persistedDigest)","size":\(persistedSize)}
            }
            """
        let statePath = fixture.dir.appendingPathComponent("state.json")
        try Data(state.utf8).write(to: statePath)

        let blobs = fixture.dir.appendingPathComponent("blobs/sha256")
        let before = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.cleanUpOrphanedBlobs()
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()

        #expect(after == before)
        #expect(after.contains(healthyDigest.encoded))
        #expect(try Data(contentsOf: statePath) == Data(state.utf8))
    }

    /// Pre-validation releases resolved any single-colon digest prefix to the
    /// same stored blob. Migration must fail closed for those records rather
    /// than silently removing their live roots from garbage collection.
    @Test(arguments: ["SHA256", "legacy"])
    func cleanupPreservesContentForLegacyDigestPrefix(prefix: String) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let healthyDigest = try await seedHealthyImage(fixture, reference: "test/healthy:v1")
        let persistedDigest = "\(prefix):\(healthyDigest.encoded)"
        let state = """
            {
              "test/legacy:v1": {"mediaType":"application/vnd.oci.image.index.v1+json","digest":"\(persistedDigest)","size":\(Self.healthyIndexJSON.utf8.count)}
            }
            """
        let statePath = fixture.dir.appendingPathComponent("state.json")
        try Data(state.utf8).write(to: statePath)

        let blobs = fixture.dir.appendingPathComponent("blobs/sha256")
        let before = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.cleanUpOrphanedBlobs()
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()

        #expect(after == before)
        #expect(after.contains(healthyDigest.encoded))
        #expect(try Data(contentsOf: statePath) == Data(state.utf8))
    }

    /// A case-folding filesystem resolves uppercase hex aliases to the same
    /// lowercase blob filename used by current releases. Migration must treat
    /// those predecessor spellings as capable of naming live content too.
    @Test(arguments: ["bare", "canonical", "legacy-prefix"])
    func cleanupPreservesContentForCaseFoldedLegacyDigest(spelling: String) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let healthyDigest = try await seedHealthyImage(fixture, reference: "test/healthy:v1")
        let uppercaseHex = healthyDigest.encoded.uppercased()
        let persistedDigest =
            switch spelling {
            case "bare": uppercaseHex
            case "canonical": "sha256:\(uppercaseHex)"
            default: "legacy:\(uppercaseHex)"
            }
        let state = """
            {
              "test/legacy:v1": {"mediaType":"application/vnd.oci.image.index.v1+json","digest":"\(persistedDigest)","size":\(Self.healthyIndexJSON.utf8.count)}
            }
            """
        let statePath = fixture.dir.appendingPathComponent("state.json")
        try Data(state.utf8).write(to: statePath)

        let blobs = fixture.dir.appendingPathComponent("blobs/sha256")
        let before = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.cleanUpOrphanedBlobs()
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()

        #expect(after == before)
        #expect(after.contains(healthyDigest.encoded))
        #expect(try Data(contentsOf: statePath) == Data(state.utf8))
    }

    /// Pre-validation releases used the suffix after a single colon as the
    /// blob filename without constraining the algorithm or encoding. Every safe
    /// filename that could still name content must stop migration from deleting
    /// that root.
    @Test(arguments: [
        ("sha512:\(String(repeating: "a", count: 128))", String(repeating: "a", count: 128)),
        ("legacy:blob-name", "blob-name"),
        ("multi:colon:blob", "multi:colon:blob"),
    ])
    func cleanupPreservesContentForLegacyBlobFilename(persistedDigest: String, blobName: String) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let blob = fixture.dir.appendingPathComponent("blobs/sha256/\(blobName)")
        let contents = Data("legacy content".utf8)
        try contents.write(to: blob)
        let state = """
            {
              "test/legacy:v1": {"mediaType":"application/vnd.oci.image.index.v1+json","digest":"\(persistedDigest)","size":\(contents.count)}
            }
            """
        let statePath = fixture.dir.appendingPathComponent("state.json")
        try Data(state.utf8).write(to: statePath)

        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.cleanUpOrphanedBlobs()
        }

        #expect(FileManager.default.fileExists(atPath: blob.path))
        #expect(try Data(contentsOf: blob) == contents)
        #expect(try Data(contentsOf: statePath) == Data(state.utf8))
    }

    /// A manifest rejected for one descriptor's metadata can still name other
    /// live blobs. It must stop garbage collection rather than become an empty
    /// child list that permits those blobs to be deleted.
    @Test func manifestWithInvalidDescriptorMetadataDoesNotDropValidChildren() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let configData = Data("config".utf8)
        let configDigest = SHA256.hash(data: configData)
        let layerData = Data("valid layer".utf8)
        let layerDigest = SHA256.hash(data: layerData)
        let malformedLayerData = Data("malformed layer metadata".utf8)
        let malformedLayerDigest = SHA256.hash(data: malformedLayerData)
        let manifest = Manifest(
            config: Descriptor(
                mediaType: MediaTypes.imageConfig,
                digest: configDigest.digestString,
                size: Int64(configData.count)),
            layers: [
                Descriptor(
                    mediaType: MediaTypes.imageLayer,
                    digest: layerDigest.digestString,
                    size: Int64(layerData.count)),
                Descriptor(
                    mediaType: MediaTypes.imageLayer,
                    digest: malformedLayerDigest.digestString,
                    size: -1),
            ])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestDigest = SHA256.hash(data: manifestData)
        let index = Index(manifests: [
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: manifestDigest.digestString,
                size: Int64(manifestData.count),
                platform: Platform(arch: "arm64", os: "linux"))
        ])
        let indexData = try JSONEncoder().encode(index)
        let indexDigest = SHA256.hash(data: indexData)

        try await fixture.contentStore.ingest { ingestDir in
            try configData.write(to: ingestDir.appendingPathComponent(configDigest.encoded))
            try layerData.write(to: ingestDir.appendingPathComponent(layerDigest.encoded))
            try malformedLayerData.write(to: ingestDir.appendingPathComponent(malformedLayerDigest.encoded))
            try manifestData.write(to: ingestDir.appendingPathComponent(manifestDigest.encoded))
            try indexData.write(to: ingestDir.appendingPathComponent(indexDigest.encoded))
        }
        let image = try await fixture.store.create(
            description: Containerization.Image.Description(
                reference: "test/invalid-manifest-metadata:v1",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: indexDigest.digestString,
                    size: Int64(indexData.count))))

        await #expect(throws: (any Swift.Error).self) {
            try await image.referencedDigests()
        }
        let blobs = fixture.dir.appendingPathComponent("blobs/sha256")
        let before = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.cleanUpOrphanedBlobs()
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()

        #expect(after == before)
        #expect(after.contains(configDigest.encoded))
        #expect(after.contains(layerDigest.encoded))
    }

    /// An unreadable manifest must not be treated as a childless one. If it were,
    /// its layers would be missing from the keep set and garbage collection would
    /// delete the live blobs of a healthy image.
    @Test func oversizedManifestDoesNotSilentlyDropItsLayers() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        // A syntactically valid manifest that exceeds the decode limit, padded via
        // an annotation so it stays parseable JSON.
        let padding = String(repeating: "0", count: LocalContent.maxDecodedSize)
        let layerData = Data("layer".utf8)
        let layerDigest = SHA256.hash(data: layerData)
        let configData = Data("config".utf8)
        let configDigest = SHA256.hash(data: configData)
        let manifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: configDigest.digestString, size: Int64(configData.count)),
            layers: [Descriptor(mediaType: MediaTypes.imageLayer, digest: layerDigest.digestString, size: Int64(layerData.count))],
            annotations: ["pad": padding])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestDigest = SHA256.hash(data: manifestData)
        #expect(manifestData.count > LocalContent.maxDecodedSize)

        let index = Index(manifests: [
            Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: manifestDigest.digestString,
                size: Int64(manifestData.count),
                platform: Platform(arch: "arm64", os: "linux"))
        ])
        let indexData = try JSONEncoder().encode(index)
        let indexDigest = SHA256.hash(data: indexData)

        try await fixture.contentStore.ingest { ingestDir in
            try layerData.write(to: ingestDir.appendingPathComponent(layerDigest.encoded))
            try configData.write(to: ingestDir.appendingPathComponent(configDigest.encoded))
            try manifestData.write(to: ingestDir.appendingPathComponent(manifestDigest.encoded))
            try indexData.write(to: ingestDir.appendingPathComponent(indexDigest.encoded))
        }

        let image = try await fixture.store.create(
            description: Containerization.Image.Description(
                reference: "test/oversized:v1",
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: indexDigest.digestString,
                    size: Int64(indexData.count))))

        // Fail closed rather than report an incomplete keep set.
        await #expect(throws: (any Swift.Error).self) {
            try await image.referencedDigests()
        }

        let blobs = fixture.dir.appendingPathComponent("blobs/sha256")
        let before = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        await #expect(throws: (any Swift.Error).self) {
            try await fixture.store.cleanUpOrphanedBlobs()
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        #expect(after == before)
        #expect(after.contains(layerDigest.encoded))
    }

    @discardableResult
    private func seedHealthyImage(_ fixture: Fixture, reference: String) async throws -> SHA256.Digest {
        let data = Data(Self.healthyIndexJSON.utf8)
        let digest = SHA256.hash(data: data)
        try await fixture.contentStore.ingest { ingestDir in
            try data.write(to: ingestDir.appendingPathComponent(digest.encoded))
        }
        _ = try await fixture.store.create(
            description: Containerization.Image.Description(
                reference: reference,
                descriptor: Descriptor(
                    mediaType: MediaTypes.index,
                    digest: digest.digestString,
                    size: Int64(data.count))))
        return digest
    }
}
