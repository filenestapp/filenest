import Foundation

struct OMPRPCFrame: Equatable, Sendable {
    let payload: AgentJSONValue

    var type: String? { payload["type"]?.stringValue }
    var id: String? { payload["id"]?.stringValue }
    var success: Bool? { payload["success"]?.boolValue }

    subscript(key: String) -> AgentJSONValue? { payload[key] }
}

enum OMPRPCFrameDecoderError: LocalizedError, Equatable {
    case physicalFrameTooLarge
    case invalidJSON
    case expectedObject
    case invalidChunkMetadata
    case invalidChunkData
    case interruptedChunkSequence
    case chunkSequenceMismatch
    case reassembledFrameTooLarge
    case reassembledLengthMismatch
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .physicalFrameTooLarge: return "The OMP RPC frame exceeded the physical frame limit."
        case .invalidJSON: return "The OMP RPC frame was not valid JSON."
        case .expectedObject: return "The OMP RPC frame must be a JSON object."
        case .invalidChunkMetadata: return "The OMP RPC chunk metadata was invalid."
        case .invalidChunkData: return "The OMP RPC chunk data was invalid."
        case .interruptedChunkSequence: return "The OMP RPC chunk sequence was interrupted."
        case .chunkSequenceMismatch: return "The OMP RPC chunk sequence did not match the pending frame."
        case .reassembledFrameTooLarge: return "The reassembled OMP RPC frame exceeded the configured limit."
        case .reassembledLengthMismatch: return "The reassembled OMP RPC frame length did not match its declaration."
        case .invalidUTF8: return "The reassembled OMP RPC frame was not valid UTF-8."
        }
    }
}

/// Decodes OMP RPC v1 frames and the lossless v2 chunk transport.
final class OMPRPCFrameDecoder {
    static let defaultMaximumPhysicalFrameBytes = 1_048_576
    static let defaultMaximumReassembledFrameBytes = 67_108_864

    private struct PendingChunks {
        let id: String
        let count: Int
        let byteLength: Int
        var nextIndex: Int
        var data: Data
    }

    private let maximumPhysicalFrameBytes: Int
    private let maximumReassembledFrameBytes: Int
    private var pending: PendingChunks?

    init(
        maximumPhysicalFrameBytes: Int = OMPRPCFrameDecoder.defaultMaximumPhysicalFrameBytes,
        maximumReassembledFrameBytes: Int = OMPRPCFrameDecoder.defaultMaximumReassembledFrameBytes
    ) {
        self.maximumPhysicalFrameBytes = maximumPhysicalFrameBytes
        self.maximumReassembledFrameBytes = maximumReassembledFrameBytes
    }

    func decode(line: Data) throws -> OMPRPCFrame? {
        guard line.count <= maximumPhysicalFrameBytes else {
            throw OMPRPCFrameDecoderError.physicalFrameTooLarge
        }
        let value = try decodeJSON(line)
        guard value.objectValue != nil else {
            throw OMPRPCFrameDecoderError.expectedObject
        }

        guard value["type"]?.stringValue == "rpc_chunk" else {
            guard pending == nil else {
                throw OMPRPCFrameDecoderError.interruptedChunkSequence
            }
            return OMPRPCFrame(payload: value)
        }

        return try decodeChunk(value)
    }

    func reset() {
        pending = nil
    }

    private func decodeChunk(_ value: AgentJSONValue) throws -> OMPRPCFrame? {
        guard let chunkID = value["chunkId"]?.stringValue,
              !chunkID.isEmpty,
              let index = value["index"]?.integerValue,
              let count = value["count"]?.integerValue,
              let byteLength = value["byteLength"]?.integerValue,
              let encodedData = value["data"]?.stringValue,
              index >= 0,
              count > 0,
              index < count,
              byteLength >= 0 else {
            throw OMPRPCFrameDecoderError.invalidChunkMetadata
        }
        guard byteLength <= maximumReassembledFrameBytes else {
            throw OMPRPCFrameDecoderError.reassembledFrameTooLarge
        }
        guard let chunkData = Data(base64Encoded: encodedData),
              chunkData.base64EncodedString() == encodedData else {
            throw OMPRPCFrameDecoderError.invalidChunkData
        }

        if pending == nil {
            guard index == 0 else {
                throw OMPRPCFrameDecoderError.invalidChunkMetadata
            }
            pending = PendingChunks(
                id: chunkID,
                count: count,
                byteLength: byteLength,
                nextIndex: 0,
                data: Data(capacity: byteLength)
            )
        }

        guard var current = pending,
              current.id == chunkID,
              current.count == count,
              current.byteLength == byteLength,
              current.nextIndex == index else {
            throw OMPRPCFrameDecoderError.chunkSequenceMismatch
        }

        current.data.append(chunkData)
        current.nextIndex += 1
        guard current.data.count <= current.byteLength,
              current.data.count <= maximumReassembledFrameBytes else {
            pending = nil
            throw OMPRPCFrameDecoderError.reassembledLengthMismatch
        }

        guard current.nextIndex == current.count else {
            pending = current
            return nil
        }

        pending = nil
        guard current.data.count == current.byteLength else {
            throw OMPRPCFrameDecoderError.reassembledLengthMismatch
        }
        guard String(data: current.data, encoding: .utf8) != nil else {
            throw OMPRPCFrameDecoderError.invalidUTF8
        }
        let reassembled = try decodeJSON(current.data)
        guard reassembled.objectValue != nil,
              reassembled["type"]?.stringValue != "rpc_chunk" else {
            throw OMPRPCFrameDecoderError.expectedObject
        }
        return OMPRPCFrame(payload: reassembled)
    }

    private func decodeJSON(_ data: Data) throws -> AgentJSONValue {
        do {
            return try JSONDecoder().decode(AgentJSONValue.self, from: data)
        } catch {
            throw OMPRPCFrameDecoderError.invalidJSON
        }
    }
}
