import Foundation
import SwiftData

@Model
final class Note: Taggable, TimeBlockable, Embeddable {
    @Attribute(.unique) var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var modifiedAt: Date
    
    // Embedding for Semantic Search / RAG
    var embedding: [Float]?
    
    // Relationships
    
    // Tags: Many-to-Many
    @Relationship(inverse: \Tag.notes)
    var tags: [Tag]?
    
    // Zotero References: Many-to-Many
    @Relationship(inverse: \ZoteroReference.linkedNotes)
    var references: [ZoteroReference]?
    
    // Tasks associated with this note (e.g. action items inside the note)
    @Relationship(inverse: \Task.linkedNote)
    var tasks: [Task]?
    
    // TimeBlocks associated with this note (e.g. time spent working on this note)
    @Relationship(inverse: \TimeBlock.linkedNote)
    var timeBlocks: [TimeBlock]?
    
    // Bidirectional Linking
    // Outgoing links: Notes this note links TO
    @Relationship(inverse: \Note.backlinks)
    var linkedNotes: [Note]?
    
    // Incoming links: Notes that link TO this note
    var backlinks: [Note]?
    
    init(
        id: UUID = UUID(),
        title: String,
        content: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        embedding: [Float]? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.embedding = embedding
    }
}
