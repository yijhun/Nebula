import Foundation
import SwiftData

@Model
final class Task: Taggable, TimeBlockable, Embeddable {
    @Attribute(.unique) var id: UUID
    var title: String
    var isCompleted: Bool
    var dueDate: Date?
    var priority: Int // 0: None, 1: Low, 2: Medium, 3: High
    var createdAt: Date
    
    // Embedding for Semantic Search / RAG (Optional)
    var embedding: [Float]?

    // Timer State Persistence
    var timerStartTime: Date? // If not nil, timer is running since this date
    var accumulatedTime: TimeInterval // Total time tracked before current session
    
    // Relationships
    
    // Linked Note (e.g. if task is created within a note)
    @Relationship(inverse: \Note.tasks)
    var linkedNote: Note?
    
    // Tags: Many-to-Many
    @Relationship(inverse: \Tag.tasks)
    var tags: [Tag]?
    
    // TimeBlocks associated with this task (e.g. focused work sessions)
    @Relationship(inverse: \TimeBlock.linkedTask)
    var timeBlocks: [TimeBlock]?
    
    init(
        id: UUID = UUID(),
        title: String,
        isCompleted: Bool = false,
        dueDate: Date? = nil,
        priority: Int = 0,
        createdAt: Date = Date(),
        embedding: [Float]? = nil,
        timerStartTime: Date? = nil,
        accumulatedTime: TimeInterval = 0
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.priority = priority
        self.createdAt = createdAt
        self.embedding = embedding
        self.timerStartTime = timerStartTime
        self.accumulatedTime = accumulatedTime
    }
}
