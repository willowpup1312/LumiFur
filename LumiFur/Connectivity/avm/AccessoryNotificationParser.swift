import Foundation

// MARK: - OTA Response

struct AccessoryOTAResponse: Equatable, Sendable {
    let statusMessage: String
    let resetsProgress: Bool
}

// ADD VideoList at file scope (not inside the enum)
struct VideoList: Equatable, Sendable {
    let currentIndex: Int
    let names: [String]
}

// MARK: - AccessoryNotificationParser

enum AccessoryNotificationParser {
    static func deviceInfo(from data: Data) -> DeviceInfo? {
        // ... existing code ...
    }

    // ... all other existing static funcs ...

    static func otaResponse(from data: Data) -> AccessoryOTAResponse? {
        guard data.count == 2 else { return nil }

        let code = data[0]
        let detail = data[1]

        switch (code, detail) {
        case (0x01, 0x00):
            return AccessoryOTAResponse(statusMessage: "OTA Started", resetsProgress: false)
        case (0x03, 0x00):
            return AccessoryOTAResponse(statusMessage: "OTA Complete - Rebooting...", resetsProgress: false)
        case (0x04, 0x00):
            return AccessoryOTAResponse(statusMessage: "OTA Aborted", resetsProgress: true)
        case (0xFF, _):
            return AccessoryOTAResponse(statusMessage: "OTA Error \(detail)", resetsProgress: true)
        default:
            return AccessoryOTAResponse(statusMessage: "OTA Unknown Response", resetsProgress: false)
        }
    }

    static func videoList(from data: Data) -> VideoList? {
        guard data.count >= 2 else { return nil }
        let count = Int(data[0])
        let current = Int(data[1])
        var names: [String] = []
        var offset = 2

        while offset < data.count && names.count < count {
            guard let end = data[offset...].firstIndex(of: 0) else { break }
            let nameData = data[offset..<end]
            if let name = String(data: nameData, encoding: .utf8), !name.isEmpty {
                names.append(name)
            }
            offset = end + 1
        }

        return VideoList(currentIndex: current, names: names)
    }
} // ← this closes the enum

// MARK: - TemperatureHistoryAssembler

/// Reassembles streamed history packets on the BLE queue before crossing to the main actor.
struct TemperatureHistoryAssembler {
    enum Result: Sendable {
        case finished([TemperatureData])
        case failed(String)
    }

    private struct State {
        var totalChunks: Int = 0
        var receivedChunks: Int = 0
        var totalPoints: Int = 0
        var processedPoints: Int = 0
        var interval: TimeInterval = 60
        var oldestTimestamp: Date = .distantPast
        var points: [TemperatureData] = []
    }

    private let maxPoints: Int
    private var state: State?

    init(maxPoints: Int = 600) {
        self.maxPoints = maxPoints
    }

    var isDownloading: Bool {
        state != nil
    }

    mutating func reset() {
        state = nil
    }

    mutating func process(_ data: Data, now: Date = Date()) -> Result? {
        guard let type = data.first else { return nil }

        switch type {
        case 0xA0:
            guard data.count >= 8 else {
                state = nil
                return .failed("History start packet was truncated.")
            }

            let intervalSeconds = Int(data[2])
            let totalPoints: UInt16 = data.withUnsafeBytes { raw in
                raw.load(fromByteOffset: 4, as: UInt16.self)
            }
            let startAgeMinutes: UInt16 = data.withUnsafeBytes { raw in
                raw.load(fromByteOffset: 6, as: UInt16.self)
            }

            let oldest = now.addingTimeInterval(-TimeInterval(UInt16(littleEndian: startAgeMinutes)) * 60)

            let advertisedTotalPoints = Int(UInt16(littleEndian: totalPoints))

            var newState = State(
                totalChunks: 0,
                receivedChunks: 0,
                totalPoints: advertisedTotalPoints,
                processedPoints: 0,
                interval: TimeInterval(intervalSeconds),
                oldestTimestamp: oldest,
                points: []
            )
            newState.points.reserveCapacity(min(advertisedTotalPoints, maxPoints))
            state = newState
            return nil

        case 0xA1:
            guard data.count >= 4 else {
                state = nil
                return .failed("History data packet was truncated.")
            }
            guard var currentState = state else {
                return .failed("History data arrived before history start.")
            }

            let totalChunks = Int(data[2])
            let pointsInChunk = Int(data[3])

            if currentState.totalChunks == 0 {
                currentState.totalChunks = totalChunks
            } else if currentState.totalChunks != totalChunks {
                state = nil
                return .failed("History packet count changed mid-transfer.")
            }

            let requiredBytes = 4 + (pointsInChunk * MemoryLayout<Int16>.size)
            guard data.count >= requiredBytes else {
                state = nil
                return .failed("History packet length did not match the advertised point count.")
            }

            let baseIndex = currentState.processedPoints
            let firstRetainedIndex = max(0, currentState.totalPoints - maxPoints)

            data.withUnsafeBytes { raw in
                for index in 0..<pointsInChunk {
                    let absoluteIndex = baseIndex + index
                    let offset = 4 + (index * MemoryLayout<Int16>.size)
                    let rawValue = raw.load(fromByteOffset: offset, as: Int16.self)
                    let celsius = Double(Int16(littleEndian: rawValue)) / 10.0
                    let timestamp = currentState.oldestTimestamp.addingTimeInterval(
                        Double(absoluteIndex) * currentState.interval
                    )

                    if absoluteIndex >= firstRetainedIndex {
                        currentState.points.append(TemperatureData(timestamp: timestamp, temperature: celsius))
                    }
                }
            }

            currentState.receivedChunks += 1
            currentState.processedPoints += pointsInChunk

            if currentState.points.count > maxPoints {
                currentState.points.removeFirst(currentState.points.count - maxPoints)
            }

            if currentState.receivedChunks == currentState.totalChunks {
                state = nil
                return .finished(currentState.points)
            }

            state = currentState
            return nil

        default:
            return nil
        }
    }
}
