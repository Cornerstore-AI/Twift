import Foundation

public struct DirectMessage: Codable, Identifiable {
    public let id: String
    public let text: String
    public let senderId: String
    public let senderHandle: String?
    public let senderAvatar: String?
    public let createdAt: Date
    public let conversationId: String
    public let participantIds: [String]?
}

public extension Twift {
    func getDMConversations() async throws -> TwitterAPIDataAndMeta<[DirectMessage], Meta> {
        try await call(route: .dmConversations)
    }

    func sendDM(conversationId: String, text: String) async throws {
        struct Body: Codable { let text: String }
        let body = try JSONEncoder().encode(Body(text: text))
        let _: TwitterAPIData<DirectMessage> = try await call(route: .sendDM(conversationId: conversationId), method: .POST, body: body)
    }
}
