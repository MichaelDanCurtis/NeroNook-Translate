import Foundation

// Engine protocol framing, shared by TranslateEngine and TranslateASR. The same codec lives in
// Sources/TranslateEngineClient/EngineFrames.swift; keep the two in step (docs/PROTOCOL.md).
//
// Frame = u32 big-endian header length · JSON header · u32 big-endian payload length · payload bytes.
// Headers are small JSON objects with a "type" field; payloads carry raw Float32 little-endian PCM.

public enum Frame {
    public static let maxHeaderBytes = 64 * 1024
    public static let maxPayloadBytes = 64 * 1024 * 1024   // ten minutes of 16 kHz Float32 is 38 MiB

    public struct Message {
        public let header: [String: Any]
        public let payload: Data
        public var type: String { header["type"] as? String ?? "" }
    }

    public static func encode(_ header: [String: Any], payload: Data = Data()) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        guard json.count <= maxHeaderBytes, payload.count <= maxPayloadBytes else { throw EngineProblem("Frame exceeds its limit.") }
        var data = Data(capacity: 8 + json.count + payload.count)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(json.count).bigEndian, Array.init))
        data.append(json)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        data.append(payload)
        return data
    }

    /// Incremental decoder; feed bytes as they arrive and take complete messages.
    public final class Reader {
        public init() {}
        private var buffer = Data()

        public func feed(_ bytes: Data) throws -> [Message] {
            buffer.append(bytes)
            var messages: [Message] = []
            while true {
                guard buffer.count >= 4 else { break }
                let headerLength = Int(UInt32(bigEndian: buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                guard headerLength <= Frame.maxHeaderBytes else { throw EngineProblem("Frame header exceeds its limit.") }
                guard buffer.count >= 4 + headerLength + 4 else { break }
                let payloadStart = 4 + headerLength + 4
                let payloadLength = Int(UInt32(bigEndian: buffer[buffer.startIndex + 4 + headerLength ..< buffer.startIndex + payloadStart].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                guard payloadLength <= Frame.maxPayloadBytes else { throw EngineProblem("Frame payload exceeds its limit.") }
                guard buffer.count >= payloadStart + payloadLength else { break }
                let headerData = buffer[buffer.startIndex + 4 ..< buffer.startIndex + 4 + headerLength]
                guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else { throw EngineProblem("Frame header is not an object.") }
                let payload = Data(buffer[buffer.startIndex + payloadStart ..< buffer.startIndex + payloadStart + payloadLength])
                buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + payloadStart + payloadLength)
                messages.append(Message(header: header, payload: payload))
            }
            return messages
        }
    }
}

public struct EngineProblem: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
