import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTools
import Testing

/// Live fix 3: on-device, "Find Mum" was answered with no tool call. A message about a person
/// is now always offered find_contact, next after the pinned tools.
@Suite("Local tool choice offers find_contact for people (live fix 3)")
struct LocalToolRankerPersonTests {
    @Test func aPersonOrRelationBringsFindContactRightAfterThePinnedTools() async {
        for text in ["Find Mum", "call my brother", "what's Sarah's number"] {
            let s = await LocalToolRankerTests.select(text)
            #expect(s.tier == .ranked)
            #expect(Array(s.names.prefix(4)) == LocalToolRankerTests.pinned + ["find_contact"], "\(text)")
        }
    }

    @Test func otherMessagesAreRankedAsBefore() async {
        let s = await LocalToolRankerTests.select("what is the weather like in London")
        #expect(s.names.dropFirst(3).first != "find_contact")
    }
}
