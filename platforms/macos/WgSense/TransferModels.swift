import Foundation

struct TransferDevice: Codable, Identifiable {
    let id: String
    let alias: String
    let ip: String?
    let port: Int?
    let deviceModel: String?
    let fingerprint: String?
    let deviceType: String?
    let version: String?
    let protocolName: String
    let download: Bool
    let source: String?

    enum CodingKeys: String, CodingKey {
        case id, alias, ip, port, deviceModel, fingerprint, deviceType, version, download, source
        case protocolName = "protocol"
    }
}

struct TransferReceiveState: Codable {
    let alias: String
    let downloads: String
    let port: Int
    let running: Bool
    let pending: [TransferPendingRequest]
    let active: [TransferFileProgress]?
    let history: [TransferFileProgress]?
}

struct TransferFileProgress: Codable, Identifiable {
    let id: String
    let sessionID: String
    let fileID: String
    let sender: String
    let senderIP: String
    let fileName: String
    let fileType: String
    let totalBytes: Int64
    let doneBytes: Int64
    let status: String
    let error: String?
    let startedAt: String
    let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, sender, status, error
        case sessionID = "session_id"
        case fileID = "file_id"
        case senderIP = "sender_ip"
        case fileName = "file_name"
        case fileType = "file_type"
        case totalBytes = "total_bytes"
        case doneBytes = "done_bytes"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

struct TransferSendFileProgress: Codable, Identifiable {
    let id: String
    let name: String
    let totalBytes: Int64
    let doneBytes: Int64
    let status: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, error
        case totalBytes = "total_bytes"
        case doneBytes = "done_bytes"
    }
}

struct TransferSendTask: Codable, Identifiable {
    let id: String
    let deviceID: String
    let deviceAlias: String
    let totalBytes: Int64
    let doneBytes: Int64
    let status: String
    let error: String?
    let files: [TransferSendFileProgress]
    let startedAt: String
    let finishedAt: String?
    let completedFiles: Int

    enum CodingKeys: String, CodingKey {
        case id, status, error, files
        case deviceID = "device_id"
        case deviceAlias = "device_alias"
        case totalBytes = "total_bytes"
        case doneBytes = "done_bytes"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case completedFiles = "completed_files"
    }
}

struct TransferSendTasksState: Codable {
    let active: [TransferSendTask]
    let history: [TransferSendTask]
}

struct TransferPendingFile: Codable, Identifiable {
    var id: String { "\(name)|\(size)" }
    let name: String
    let size: Int64
    let type: String
}

struct TransferPendingRequest: Codable, Identifiable {
    let id: String
    let alias: String
    let ip: String
    let files: [TransferPendingFile]
    let totalSize: Int64
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, alias, ip, files
        case totalSize = "total_size"
        case createdAt = "created_at"
    }
}
