import Foundation

extension ProtocolChecks {
    static func transcriptActing() throws {
        let first = ChatMessage(author: .user, text: "hello", rowID: 11)
        let reply = ChatMessage(author: .bot, text: "hi", rowID: 12)
        let second = ChatMessage(author: .user, text: "typo", rowID: 13)
        let later = ChatMessage(author: .bot, text: "ok", rowID: 14)
        let messages = [first, reply, second, later]

        let restore = TranscriptActing.planRestore(messages, from: second.id)
        try expect(restore?.sourceText == "typo", "restore source")
        try expect(restore?.truncate.rowID == 13, "restore row id")
        try expect(restore?.truncate.ordinal == 1, "restore ordinal skips first user")
        try expect(restore?.truncate.confirmEmpty == false, "second turn is not empty")

        let reload = TranscriptActing.planReload(messages, from: later.id)
        try expect(reload?.sourceIndex == 2, "reload walks back to user")
        try expect(reload?.text == "typo", "reload resubmits user text")

        let edited = TranscriptActing.planEdit(messages, from: second.id, text: "fixed")
        try expect(edited?.text == "fixed", "edit uses new text")
        try expect(edited?.sourceText == "typo", "edit keeps source")
        try expect(TranscriptActing.planEdit(messages, from: second.id, text: "typo") == nil,
                   "identical edit is a no-op")

        let firstRestore = TranscriptActing.planRestore(messages, from: first.id)
        try expect(firstRestore?.truncate.confirmEmpty == true, "first-turn restore confirms empty")
        try expect(firstRestore?.truncate.ordinal == 0, "first-turn ordinal is 0")

        let localOnly = ChatMessage(author: .user, text: "never sent")
        let failed = TranscriptActing.planRestore([first, reply, localOnly], from: localOnly.id)
        try expect(failed?.truncate.isEmpty == true, "undurable user turn does not truncate")

        let params = TranscriptActing.truncateParams(restore!.truncate)
        try expect(params["confirm_truncate"]?.boolValue == true, "confirm_truncate required")
        try expect(params["truncate_before_row_id"]?.intValue == 13, "row id address")
        try expect(params["truncate_before_user_ordinal"] == nil, "row id suppresses ordinal")

        let rebound = TranscriptActing.rebindSurvivorRowIDs(
            [first, reply, ChatMessage(author: .user, text: "typo")],
            survivorRowIDs: [21, nil])
        try expect(rebound[0].rowID == 21, "first survivor rebound")
        try expect(rebound[2].rowID == nil, "resubmitted turn drops stale id")

        let ordinary = TranscriptActing.truncateParams(.init())
        try expect(ordinary.isEmpty, "ordinary send carries no truncate keys")
    }
}
