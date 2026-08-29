//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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
import ContainerizationOCI
import Foundation

extension ImageStore {
    /// A ReferenceManager handles the mappings between an image's
    /// reference and the underlying descriptor inside of a content store.
    internal actor ReferenceManager {
        private let path: URL

        private typealias State = [String: Descriptor]
        private var images: State

        public init(path: URL) throws {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

            self.path = path
            self.images = [:]
        }

        private func load() throws -> State {
            let statePath = self.path.appendingPathComponent("state.json")
            guard FileManager.default.fileExists(atPath: statePath.absolutePath()) else {
                return [:]
            }
            do {
                let data = try Data(contentsOf: statePath)
                let entries = try JSONDecoder().decode([String: SkippableDescriptor].self, from: data)
                return entries.compactMapValues { $0.descriptor }
            } catch {
                throw ContainerizationError(.internalError, message: "failed to load image state \(error.localizedDescription)")
            }
        }

        /// Decodes one state entry, tolerating only a record whose digest cannot
        /// name content in the store.
        ///
        /// `Descriptor` rejects malformed digests at decode time, so without this
        /// a single unreadable record would make `load()` throw and take every
        /// other image in the store with it — listing, pulling and deleting all
        /// go through here.
        ///
        /// A record with a valid digest but another invalid field must still fail
        /// the load. Silently dropping it would remove its root digest from the
        /// garbage-collection keep set and could delete live content. A skipped
        /// digest-invalid record cannot reference content safely and is removed
        /// by the next successful state mutation.
        private struct SkippableDescriptor: Decodable {
            let descriptor: Descriptor?

            private enum CodingKeys: String, CodingKey {
                case digest
            }

            /// Before digest validation, state lookup stripped any single-colon
            /// prefix. Treat those legacy spellings as capable of naming their
            /// validated suffix so migration fails closed instead of dropping a
            /// live root from the garbage-collection keep set.
            private static func canNameStoredContent(_ digest: String) -> Bool {
                if (try? ParsedDigest(parsingPathComponent: digest)) != nil {
                    return true
                }
                let components = digest.split(separator: ":")
                guard components.count == 2 else {
                    return false
                }
                return (try? ParsedDigest(parsingPathComponent: String(components[1]))) != nil
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                guard let digest = try? container.decode(String.self, forKey: .digest),
                    Self.canNameStoredContent(digest)
                else {
                    self.descriptor = nil
                    return
                }
                self.descriptor = try Descriptor(from: decoder)
            }
        }

        private func save(_ state: State) throws {
            let statePath = self.path.appendingPathComponent("state.json")
            try JSONEncoder().encode(state).write(to: statePath, options: .atomic)
        }

        public func delete(reference: String) throws {
            var state = try self.load()
            state.removeValue(forKey: reference)
            try self.save(state)
        }

        public func delete(image: Image.Description) throws {
            try self.delete(reference: image.reference)
        }

        public func create(description: Image.Description) throws {
            var state = try self.load()
            state[description.reference] = description.descriptor
            try self.save(state)
        }

        public func list() throws -> [Image.Description] {
            let state = try self.load()
            return state.map { key, val in
                let description = Image.Description(reference: key, descriptor: val)
                return description
            }
        }

        public func get(reference: String) throws -> Image.Description {
            let images = try self.list()
            let hit = images.first(where: { image in
                image.reference == reference
            })
            guard let hit else {
                throw ContainerizationError(.notFound, message: "image \(reference) not found")
            }
            return hit
        }
    }
}
