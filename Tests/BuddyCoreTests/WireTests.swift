import Foundation
import Testing
@testable import BuddyCore

@Suite struct WireTests {
    @Test func hookRoundTrip() throws {
        var env = HookEnv(claudePid: 123, shellPid: 122, tty: "ttys004", termProgram: "vscode")
        env.messagingToken = "secret"
        let m = HookMessage(id: "abc", wantsReply: true, payload: json(#"{"a":[1,true,null,"x"]}"#), env: env)
        let line = try WireMessage.encode(m)
        #expect(line.last == 0x0A)
        #expect(try WireMessage.decode(line.dropLast()) == .hook(m))
        #expect(!env.description.contains("secret"))
    }

    @Test func replyNullEncodesExplicitNull() throws {
        let line = try WireMessage.encode(ReplyMessage(id: "x", output: .null))
        #expect(String(decoding: line, as: UTF8.self).contains(#""output":null"#))
        #expect(try WireMessage.decode(line) == .reply(ReplyMessage(id: "x", output: .null)))
    }

    @Test func extensionMessages() throws {
        let hello = #"{"kind":"ext-hello","editor":"cursor","appPid":5,"version":"0.1.0","terminals":[{"shellPid":122,"name":"zsh"}]}"#
        guard case .extHello(let h) = try WireMessage.decode(Data(hello.utf8)) else { Issue.record("not hello"); return }
        #expect(h.terminals == [ExtTerminal(shellPid: 122, name: "zsh")])
        let ack = #"{"kind":"ack","reqId":"r","ok":false,"error":"no-terminal"}"#
        #expect(try WireMessage.decode(Data(ack.utf8)) == .ack(AckMessage(reqId: "r", ok: false, error: "no-terminal")))
        let send = SendMessage(reqId: "r", shellPid: 1, text: "hi", submit: true)
        #expect(try WireMessage.decode(WireMessage.encode(send)) == .send(send))
        #expect(try WireMessage.decode(Data(#"{"kind":"future"}"#.utf8)) == .unknown("future"))
    }

    @Test func badAndOversizeRejected() throws {
        #expect(throws: WireError.badJSON) { try WireMessage.decode(Data("{nope".utf8)) }
        #expect(throws: WireError.badJSON) { try WireMessage.decode(Data(#"{"kind":"hook"}"#.utf8)) }
        var buf = LineBuffer()
        #expect(throws: WireError.lineTooLong) { try buf.append(Data(repeating: 0x41, count: wireMaxLine + 1)) }
        var ok = LineBuffer()
        #expect(try ok.append(Data("a\nb".utf8)) == [Data("a".utf8)])
        #expect(try ok.append(Data("c\n".utf8)) == [Data("bc".utf8)])
    }
}

@Suite struct WireLimitTests {
    @Test func lineOfExactlyTheLimitPasses() throws {
        var buf = LineBuffer()
        let line = Data(repeating: 0x41, count: wireMaxLine)
        #expect(try buf.append(line + Data([0x0A])) == [line])
    }

    @Test func longLineOverChunksFailsBeforeItsNewline() throws {
        var buf = LineBuffer()
        let half = Data(repeating: 0x41, count: wireMaxLine / 2)
        #expect(try buf.append(half).isEmpty)
        #expect(try buf.append(half).isEmpty)
        #expect(throws: WireError.lineTooLong) { try buf.append(Data([0x41])) }
    }

    @Test func emptyLinesAreSkipped() throws {
        var buf = LineBuffer()
        #expect(try buf.append(Data("\n\na\n\nb\n".utf8)) == [Data("a".utf8), Data("b".utf8)])
    }

    @Test func decodeOverTheLimitFails() {
        #expect(throws: WireError.lineTooLong) { try WireMessage.decode(Data(repeating: 0x20, count: wireMaxLine + 1)) }
    }
}
