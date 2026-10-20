import Foundation

// Engine protocol framing: the client-side copy of Engine/Sources/TranslateEngine/Frames.swift.
// Keep the two in step (docs/PROTOCOL.md).
//
// Frame = u32 big-endian header length · JSON header · u32 big-endian payload length · payload bytes.

public enum EngineFrame {
    public static let maxHeaderBytes = 64 * 1024
    public static let maxPayloadBytes = 4 * 1024 * 1024

    public struct Message: Sendable {
        public let header: [String: any Sendable]
        public let payload: Data
        public var type: String { header["type"] as? String ?? "" }
        public var id: String? { header["id"] as? String }
        public func int(_ key: String) -> Int? {
            if let value = header[key] as? Int { return value }
            if let value = header[key] as? Double { return Int(value) }
            return nil
        }
        public func double(_ key: String) -> Double? {
            if let value = header[key] as? Double { return value }
            if let value = header[key] as? Int { return Double(value) }
            return nil
        }
        public func string(_ key: String) -> String? { header[key] as? String }
        public func bool(_ key: String) -> Bool? { header[key] as? Bool }
    }

    public static func encode(_ header: [String: Any], payload: Data = Data()) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        guard json.count <= maxHeaderBytes, payload.count <= maxPayloadBytes else { throw EngineClientProblem("Frame exceeds its limit.") }
        var data = Data(capacity: 8 + json.count + payload.count)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(json.count).bigEndian, Array.init))
        data.append(json)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        data.append(payload)
        return data
    }

    public final class Reader {
        private var buffer = Data()
        public init() {}

        public func feed(_ bytes: Data) throws -> [Message] {
            buffer.append(bytes)
            var messages: [Message] = []
            while true {
                guard buffer.count >= 4 else { break }
                let headerLength = Int(UInt32(bigEndian: buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                guard headerLength <= EngineFrame.maxHeaderBytes else { throw EngineClientProblem("Frame header exceeds its limit.") }
                guard buffer.count >= 4 + headerLength + 4 else { break }
                let payloadStart = 4 + headerLength + 4
                let payloadLength = Int(UInt32(bigEndian: buffer[buffer.startIndex + 4 + headerLength ..< buffer.startIndex + payloadStart].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                guard payloadLength <= EngineFrame.maxPayloadBytes else { throw EngineClientProblem("Frame payload exceeds its limit.") }
                guard buffer.count >= payloadStart + payloadLength else { break }
                let headerData = buffer[buffer.startIndex + 4 ..< buffer.startIndex + 4 + headerLength]
                guard let raw = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else { throw EngineClientProblem("Frame header is not an object.") }
                // JSON numbers arrive as NSNumber, which also bridges to Bool for 0 and 1; decide by the
                // number's real type so `seq: 0` stays an integer and `discarded: true` stays a boolean.
                var header: [String: any Sendable] = [:]
                for (key, value) in raw {
                    if let string = value as? String { header[key] = string }
                    else if let number = value as? NSNumber {
                        if CFGetTypeID(number) == CFBooleanGetTypeID() { header[key] = number.boolValue }
                        else if let integer = Int(exactly: number) { header[key] = integer }
                        else { header[key] = number.doubleValue }
                    }
                }
                let payload = Data(buffer[buffer.startIndex + payloadStart ..< buffer.startIndex + payloadStart + payloadLength])
                buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + payloadStart + payloadLength)
                messages.append(Message(header: header, payload: payload))
            }
            return messages
        }
    }
}

public struct EngineClientProblem: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
