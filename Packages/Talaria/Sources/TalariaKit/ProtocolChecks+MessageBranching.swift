import Foundation

extension ProtocolChecks {
    static func messageBranching() throws {
        let first = ChatMessage(author: .bot, text: "same", rowID: 12)
        let second = ChatMessage(author: .bot, text: "same", rowID: 18)
        try expect(MessageBranching.isEligible(first, in: [first, second]),
                   "historical durable assistant is branchable")
        try expect(!MessageBranching.isEligible(second, in: [first, second]),
                   "newest assistant stays on whole-tip branch action")
        try expect(!MessageBranching.isEligible(
            ChatMessage(author: .bot, text: "local"), in: [first, second]),
            "local assistant is not a branch point")

        let history: JSONValue = .object(["messages": .array([
            .object(["role": .string("system"), "text": .string("system"),
                     "row_id": .number(9)]),
            .object(["role": .string("user"), "text": .string("first"),
                     "row_id": .number(10)]),
            .object(["role": .string("tool"), "text": .string("tool output"),
                     "row_id": .number(11)]),
            .object(["role": .string("assistant"), "text": .string("same"),
                     "row_id": .number(12)]),
            .object(["role": .string("user"), "text": .string("hidden"),
                     "display_kind": .string("hidden"), "row_id": .number(13)]),
            .object(["role": .string("assistant"), "text": .string("   "),
                     "row_id": .number(14)]),
            .object(["role": .string("user"), "text": .string("second"),
                     "row_id": .number(17)]),
            .object(["role": .string("assistant"), "text": .string("same"),
                     "row_id": .number(18)]),
        ])])
        try expect(try MessageBranching.countThroughAssistant(rowID: 12, history: history) == 2,
                   "branch count excludes hidden system tool and empty rows")
        try expect(try MessageBranching.countThroughAssistant(rowID: 18, history: history) == 4,
                   "repeated text resolves by durable row id")
    }
}
