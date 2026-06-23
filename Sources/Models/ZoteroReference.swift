import Foundation
import SwiftData

@Model
final class ZoteroReference: Taggable, Embeddable {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var zoteroID: String
    
    var title: String
    var authors: [String]
    var abstract: String?
    var publicationYear: Int?
    var url: URL?
    
    // Embedding for Semantic Search
    var embedding: [Float]?
    
    // Relationships
    // Assuming Note has a property `references: [ZoteroReference]?`
    @Relationship(inverse: \Note.references)
    var linkedNotes: [Note]?
    
    // Assuming Tag has a property `references: [ZoteroReference]?`
    @Relationship(inverse: \Tag.references)
    var tags: [Tag]?

    init(
        id: UUID = UUID(),
        zoteroID: String,
        title: String,
        authors: [String] = [],
        abstract: String? = nil,
        publicationYear: Int? = nil,
        url: URL? = nil,
        embedding: [Float]? = nil
    ) {
        self.id = id
        self.zoteroID = zoteroID
        self.title = title
        self.authors = authors
        self.abstract = abstract
        self.publicationYear = publicationYear
        self.url = url
        self.embedding = embedding
    }
}
