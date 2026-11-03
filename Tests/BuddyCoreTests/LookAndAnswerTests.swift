import Foundation
import Testing
@testable import BuddyCore

@Suite struct LookAndAnswerTests {
    static let sheetJSON = #"""
    {"version":1,"grid":{"w":4,"h":2},"fps":8,"legend":{".":null,"K":"outline","Q":"newSlot","A":"accent"},
     "palettes":{"p1":{"outline":"#010203","accent":"#FF0000"},"p2":{"outline":"#000000"}},
     "bases":{"clawd":{"states":{"idle":{"loop":true,"frames":[{"rows":["K...","Q.X."],"head":[1,0]}]},
                                  "question":{"loop":true,"frames":[{"rows":["....","...."],"head":[0,0],"fx":[".K..","...."]}]}}}},
     "outfits":{"hat":{"label":"Hat","rows":["A...","...."]},"bow":{"rows":["....","A..."]}}}
    """#

    @Test func fnvIsStable() {
        // Known FNV-1a 64 test vector.
        #expect(LookPicker.fnv1a("a") == 0xaf63dc4c8601ec8c)
        #expect(LookPicker.fnv1a("/Users/x/proj") == LookPicker.fnv1a("/Users/x/proj"))
    }

    @Test func lookDeterministic() throws {
        let sheet = try SpriteSheet.load(Data(Self.sheetJSON.utf8))
        let a = LookPicker.pick(cwd: "/Users/x/proj", sheet: sheet)
        #expect(a == LookPicker.pick(cwd: "/Users/x/proj", sheet: sheet))
        #expect(a.base == "clawd")
        #expect(["p1", "p2"].contains(a.palette))
    }

    @Test func renderOutfitShiftAndMissing() throws {
        let sheet = try SpriteSheet.load(Data(Self.sheetJSON.utf8))
        let frame = try #require(sheet.anim(base: "clawd", chain: ["idle"])?.frames.first)
        let r = SpriteRenderer.render(sheet: sheet, frame: frame, look: Look(base: "clawd", palette: "p1", outfit: "hat"), mirrored: false)
        #expect(Array(r.rgba[0..<4]) == [1, 2, 3, 255])
        #expect(Array(r.rgba[4..<8]) == [255, 0, 0, 255]) // hat shifted by head dx=1
        #expect(r.missing == ["key newSlot", "char X"])
        let m = SpriteRenderer.render(sheet: sheet, frame: frame, look: Look(base: "clawd", palette: "p1", outfit: nil), mirrored: true)
        #expect(m.isOpaque(x: 3, y: 0) && !m.isOpaque(x: 0, y: 0))
    }

    @Test func fxDrawnUnshiftedOnTop() throws {
        let sheet = try SpriteSheet.load(Data(Self.sheetJSON.utf8))
        let frame = try #require(sheet.anim(base: "clawd", chain: ["question"])?.frames.first)
        var shifted = frame
        shifted.head = [2, 1]
        let r = SpriteRenderer.render(sheet: sheet, frame: shifted, look: Look(base: "clawd", palette: "p1", outfit: nil), mirrored: false)
        #expect(r.isOpaque(x: 1, y: 0))
        #expect(!r.isOpaque(x: 3, y: 1))
    }

    @Test func stateFallbackChain() throws {
        let sheet = try SpriteSheet.load(Data(Self.sheetJSON.utf8))
        #expect(sheet.anim(base: "clawd", chain: ["permission", "question"])?.frames.first?.rows.first == "....")
        #expect(sheet.anim(base: "clawd", chain: ["error"])?.frames.first?.rows.first == "K...")
        #expect(sheet.anim(base: "missing", chain: ["idle"]) != nil)
    }

    @Test func askAnswerShape() throws {
        let input = json(#"{"questions":[{"question":"Pick a color","header":"Color","options":[{"label":"Red"},{"label":"Blue"}],"multiSelect":false},{"question":"Pick fruits","header":"Fruits","options":[{"label":"Pear"},{"label":"Plum"}],"multiSelect":true}]}"#)
        let qs = AskQuestion.parse(input)
        #expect(qs.count == 2 && qs[1].multiSelect)
        let multi = HookOutput.answerText(selected: ["Pear", "Plum"], other: " ")
        #expect(multi == "Pear, Plum")
        let out = HookOutput.answer(toolInput: input, answers: ["Pick a color": "Blue", "Pick fruits": multi])
        let expected = json(#"""
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow",
         "updatedInput":{"questions":[{"question":"Pick a color","header":"Color","options":[{"label":"Red"},{"label":"Blue"}],"multiSelect":false},{"question":"Pick fruits","header":"Fruits","options":[{"label":"Pear"},{"label":"Plum"}],"multiSelect":true}],
         "answers":{"Pick a color":"Blue","Pick fruits":"Pear, Plum"}}}}}
        """#)
        #expect(out == expected)
    }

    @Test func permissionOutputs() {
        #expect(HookOutput.allow() == json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#))
        #expect(HookOutput.deny("")["hookSpecificOutput"]?["decision"]?["message"]?.string == "The user denied this in Buddy.")
        let sug = json(#"{"type":"addDirectories","directories":["/tmp"],"destination":"session"}"#)
        #expect(HookOutput.suggestionLabel(sug) == "Always allow access to /tmp")
        #expect(HookOutput.allowAlways(sug)["hookSpecificOutput"]?["decision"]?["updatedPermissions"] == .array([sug]))
    }
}
