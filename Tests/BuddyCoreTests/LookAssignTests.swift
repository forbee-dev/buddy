import Foundation
import Testing
@testable import BuddyCore

@Suite struct LookAssignTests {
    /// 10 palettes, 2 outfits (3 outfit choices with "none").
    static let sheet: SpriteSheet = {
        let palettes = (0..<10).map { ##""p\##($0)":{"outline":"#000000"}"## }.joined(separator: ",")
        let json = ##"""
        {"version":1,"grid":{"w":1,"h":1},"fps":8,"legend":{"K":"outline"},"palettes":{\##(palettes)},
         "bases":{"clawd":{"states":{"idle":{"loop":true,"frames":[{"rows":["K"]}]}}}},
         "outfits":{"hat":{"rows":["."]},"bow":{"rows":["."]}}}
        """##
        return try! SpriteSheet.load(Data(json.utf8))
    }()

    static func assign(_ book: inout LookBook, _ key: String, cwd: String, visible: Set<String>) -> Look {
        book.look(for: key, preferred: LookPicker.pick(cwd: cwd, sheet: sheet), seed: cwd, visible: visible, sheet: sheet)
    }

    @Test func sameProjectGetsNewColorFirstKeepsProjectLook() {
        var book = LookBook()
        let a = Self.assign(&book, "a", cwd: "/w/api", visible: ["a", "b"])
        let b = Self.assign(&book, "b", cwd: "/w/api", visible: ["a", "b"])
        #expect(a == LookPicker.pick(cwd: "/w/api", sheet: Self.sheet))
        #expect(a.palette != b.palette)
        #expect(a.outfit != b.outfit)  // a free outfit is preferred too
    }

    @Test func hashCollisionResolved() throws {
        let first = LookPicker.pick(cwd: "/w/0", sheet: Self.sheet).palette
        let other = try #require((1..<500).map { "/w/\($0)" }.first { LookPicker.pick(cwd: $0, sheet: Self.sheet).palette == first })
        var book = LookBook()
        let a = Self.assign(&book, "a", cwd: "/w/0", visible: ["a", "b"])
        let b = Self.assign(&book, "b", cwd: other, visible: ["a", "b"])
        #expect(a.palette == first && b.palette != first)
    }

    @Test func stableWhenAnotherEnds() {
        var book = LookBook()
        let looks = ["a", "b", "c"].map { Self.assign(&book, $0, cwd: "/w/x", visible: ["a", "b", "c"]) }
        book.keep(["a", "c"])
        #expect(Self.assign(&book, "a", cwd: "/w/x", visible: ["a", "c"]) == looks[0])
        #expect(Self.assign(&book, "c", cwd: "/w/x", visible: ["a", "c"]) == looks[2])
        let d = Self.assign(&book, "d", cwd: "/w/x", visible: ["a", "c", "d"])
        #expect(d.palette != looks[0].palette && d.palette != looks[2].palette)
    }

    @Test func moreThanTenKeepPairsUnique() {
        var book = LookBook()
        let keys = (0..<25).map { "k\($0)" }
        let looks = keys.map { Self.assign(&book, $0, cwd: "/w/same", visible: Set(keys)) }
        #expect(Set(looks.prefix(10).map(\.palette)).count == 10)  // colors first
        #expect(Set(looks.map { "\($0.palette)|\($0.outfit ?? "")" }).count == 25)
    }

    @Test func rekeyKeepsLook() {
        var store = SessionStore()
        _ = store.apply(hook("SessionStart", session: "s1", pid: 4242))
        var book = LookBook()
        let key1 = store.sessions["s1"]?.mascotKey ?? ""
        let before = Self.assign(&book, key1, cwd: "/tmp/proj", visible: [key1])
        _ = store.apply(hook("SessionStart", session: "s2", pid: 4242), isAlive: { _ in true })
        let key2 = store.sessions["s2"]?.mascotKey ?? ""
        #expect(store.sessions["s1"] == nil && key2 == key1)
        #expect(Self.assign(&book, key2, cwd: "/tmp/proj", visible: [key2, "other"]) == before)
    }

    @Test func rerollGivesUnusedCombination() {
        var rng = SystemRandomNumberGenerator()
        let current = Look(base: "clawd", palette: "p0", outfit: nil)
        let taken = (1..<9).map { Look(base: "clawd", palette: "p\($0)", outfit: nil) }
        for _ in 0..<20 {
            let r = LookAssigner.reroll(current: current, taken: taken, sheet: Self.sheet, using: &rng)
            #expect(r.palette == "p9" || r.palette == "p0")
            #expect(r != current)
        }
        let full = Self.sheet.paletteNames.flatMap { p in [nil, "hat"].map { Look(base: "clawd", palette: p, outfit: $0) } }
        for _ in 0..<20 {
            let r = LookAssigner.reroll(current: current, taken: full, sheet: Self.sheet, using: &rng)
            #expect(r.outfit == "bow")
        }
    }
}

@Suite struct LookRefreshTests {
    static let sheet: SpriteSheet = {
        let json = ##"""
        {"version":1,"grid":{"w":1,"h":1},"fps":8,"legend":{"K":"outline"},"palettes":{"p0":{"outline":"#000000"},"p1":{"outline":"#111111"}},
         "bases":{"clawd":{"states":{"idle":{"loop":true,"frames":[{"rows":["K"]}]}}},
                  "crate/crate":{"states":{"idle":{"loop":true,"frames":[{"rows":["K"]}]}}}},
         "outfits":{"hat":{"rows":["."]},"box":{"fits":["crate/crate"],"rows":["."]}}}
        """##
        return try! SpriteSheet.load(Data(json.utf8))
    }()

    let looks = ["a": Look(base: "clawd", palette: "p0", outfit: "hat"), "b": Look(base: "crate/crate", palette: "p1", outfit: "box"),
                 "c": Look(base: "bee/bee", palette: "p0", outfit: nil), "d": Look(base: "clawd", palette: "gone", outfit: nil)]

    /// One character: every buddy switches to it; an outfit that does not fit it comes off.
    @Test func singleCharacterReplaces() {
        let r = LookRefresh.refresh(looks, sheet: Self.sheet, bases: ["clawd"], mix: false)
        #expect(r == ["a": Look(base: "clawd", palette: "p0", outfit: "hat"), "b": Look(base: "clawd", palette: "p1", outfit: nil),
                      "c": Look(base: "clawd", palette: "p0", outfit: nil)])
    }

    /// Mix: a buddy whose character is gone loses its look (it gets a new one); the others keep theirs.
    @Test func mixKeepsValidLooks() {
        let r = LookRefresh.refresh(looks, sheet: Self.sheet, bases: ["clawd", "crate/crate"], mix: true)
        #expect(r == looks.filter { $0.key == "a" || $0.key == "b" })
    }

    @Test func noCharacterDropsAll() {
        #expect(LookRefresh.refresh(looks, sheet: Self.sheet, bases: [], mix: false).isEmpty)
    }
}
