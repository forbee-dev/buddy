import Foundation

public enum WireError: Error, Equatable {
    case lineTooLong
    case badJSON
}

public let wireMaxLine = 1 << 20

/// Environment that buddy-hook adds to each hook event.
public struct HookEnv: Codable, Sendable, Equatable, CustomStringConvertible {
    public var claudePid: Int32?
    public var shellPid: Int32?
    public var tty: String?
    public var termProgram: String?
    public var bundleId: String?
    public var askpassMain: String?
    public var itermSessionId: String?
    public var termSessionId: String?
    public var messagingSocket: String?
    public var messagingToken: String?
    public var attended: String?
    /// `CLAUDE_CODE_ENTRYPOINT`, e.g. "cli", "sdk-cli", "claude-desktop" (sanitized, max 32 chars).
    public var entrypoint: String?

    public init(claudePid: Int32? = nil, shellPid: Int32? = nil, tty: String? = nil, termProgram: String? = nil,
                bundleId: String? = nil, askpassMain: String? = nil, itermSessionId: String? = nil,
                termSessionId: String? = nil, messagingSocket: String? = nil, messagingToken: String? = nil,
                attended: String? = nil, entrypoint: String? = nil) {
        self.claudePid = claudePid; self.shellPid = shellPid; self.tty = tty; self.termProgram = termProgram
        self.bundleId = bundleId; self.askpassMain = askpassMain; self.itermSessionId = itermSessionId
        self.termSessionId = termSessionId; self.messagingSocket = messagingSocket
        self.messagingToken = messagingToken; self.attended = attended
        self.entrypoint = entrypoint.map(HookEnv.sanitizeEntrypoint)
    }

    /// Keeps only [a-z0-9-_.], max 32 chars.
    public static func sanitizeEntrypoint(_ s: String) -> String {
        String(s.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }.prefix(32))
    }

    // Keeps the messaging token out of logs and debug prints.
    public var description: String {
        "HookEnv(claudePid: \(claudePid.map(String.init) ?? "nil"), tty: \(tty ?? "nil"), termProgram: \(termProgram ?? "nil"), token: <redacted>)"
    }
}

public struct HookMessage: Codable, Sendable, Equatable {
    public var kind = "hook"
    public var id: String
    public var wantsReply: Bool
    public var payload: JSONValue
    public var env: HookEnv
    public init(id: String, wantsReply: Bool, payload: JSONValue, env: HookEnv) {
        self.id = id; self.wantsReply = wantsReply; self.payload = payload; self.env = env
    }
}

/// `output == .null` means "defer to the terminal".
public struct ReplyMessage: Codable, Sendable, Equatable {
    public var kind = "reply"
    public var id: String
    public var output: JSONValue
    public init(id: String, output: JSONValue) { self.id = id; self.output = output }
}

public struct ExtTerminal: Codable, Sendable, Equatable {
    public var shellPid: Int32
    public var name: String?
    public init(shellPid: Int32, name: String?) { self.shellPid = shellPid; self.name = name }
}

public struct ExtHelloMessage: Codable, Sendable, Equatable {
    public var kind = "ext-hello"
    public var editor: String
    public var appPid: Int32
    public var version: String
    public var terminals: [ExtTerminal]
    /// Absent from extensions older than 0.1.2.
    public var workspaceFolders: [String]?
}

public struct ExtTerminalsMessage: Codable, Sendable, Equatable {
    public var kind = "ext-terminals"
    public var terminals: [ExtTerminal]
    public var workspaceFolders: [String]?
}

public struct SendMessage: Codable, Sendable, Equatable {
    public var kind = "send"
    public var reqId: String
    public var shellPid: Int32
    public var text: String
    public var submit: Bool
    public init(reqId: String, shellPid: Int32, text: String, submit: Bool) {
        self.reqId = reqId; self.shellPid = shellPid; self.text = text; self.submit = submit
    }
}

public struct FocusMessage: Codable, Sendable, Equatable {
    public var kind = "focus"
    public var reqId: String
    public var shellPid: Int32
    public init(reqId: String, shellPid: Int32) { self.reqId = reqId; self.shellPid = shellPid }
}

public struct AckMessage: Codable, Sendable, Equatable {
    public var kind = "ack"
    public var reqId: String
    public var ok: Bool
    public var error: String?
    public init(reqId: String, ok: Bool, error: String?) { self.reqId = reqId; self.ok = ok; self.error = error }
}

public enum WireMessage: Sendable, Equatable {
    case hook(HookMessage)
    case reply(ReplyMessage)
    case extHello(ExtHelloMessage)
    case extTerminals(ExtTerminalsMessage)
    case send(SendMessage)
    case focus(FocusMessage)
    case ack(AckMessage)
    case unknown(String)

    private struct Kind: Decodable { var kind: String }

    public static func decode(_ line: Data) throws -> WireMessage {
        guard line.count <= wireMaxLine else { throw WireError.lineTooLong }
        let d = JSONDecoder()
        do {
            switch try d.decode(Kind.self, from: line).kind {
            case "hook": return .hook(try d.decode(HookMessage.self, from: line))
            case "reply": return .reply(try d.decode(ReplyMessage.self, from: line))
            case "ext-hello": return .extHello(try d.decode(ExtHelloMessage.self, from: line))
            case "ext-terminals": return .extTerminals(try d.decode(ExtTerminalsMessage.self, from: line))
            case "send": return .send(try d.decode(SendMessage.self, from: line))
            case "focus": return .focus(try d.decode(FocusMessage.self, from: line))
            case "ack": return .ack(try d.decode(AckMessage.self, from: line))
            case let other: return .unknown(other)
            }
        } catch {
            throw WireError.badJSON
        }
    }

    /// One JSON line with a trailing newline.
    public static func encode<T: Encodable>(_ message: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        var data = try enc.encode(message)
        data.append(0x0A)
        return data
    }
}

/// Splits a byte stream into lines and enforces the 1 MB limit.
public struct LineBuffer: Sendable {
    private var buffer = Data()
    /// Bytes already searched for a newline, so a long line is not rescanned on every chunk.
    private var scanned = 0
    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            guard line.count <= wireMaxLine else { throw WireError.lineTooLong }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...nl)
            scanned = 0
        }
        scanned = buffer.count
        if buffer.count > wireMaxLine { throw WireError.lineTooLong }
        return lines
    }
}
