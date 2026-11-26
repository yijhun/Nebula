import Foundation

/// `Nebula --library-selftest`: runs the Zotero import planner on a small
/// synthetic Zotero database (built here, no user data) and checks the plan.
/// Exits non-zero on any failure, like `--save-selftest`.
enum LibrarySelfTest {

    static func run() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("  \(ok ? "PASS" : "FAIL")  \(what)")
            if !ok { failures += 1 }
        }
        do {
            let fx = try Fixture.make()
            defer { try? FileManager.default.removeItem(at: fx.root) }
            let lib = try ZoteroSnapshot.read(dbPath: fx.db, storageDir: fx.root.appendingPathComponent("storage"))
            let plan = ZoteroImportPlanner.plan(lib, zoteroDir: fx.root)
            let byKey = Dictionary(uniqueKeysWithValues: plan.papers.map { ($0.citekey, $0) })
            let t = plan.totals

            print("Every live item is planned, nothing else")
            check(t.papers == 16 && t.trashedItems == 1, "16 papers planned, 1 trashed item left out (got \(t.papers), \(t.trashedItems))")
            check(t.invariantFailures.isEmpty, "invariants hold \(t.invariantFailures)")

            print("Identifiers and duplicates")
            check(plan.duplicates.contains { Set($0.citekeys).isSuperset(of: ["smithDisks2020", "smithDisks2020a"]) },
                  "same DOI in different case and form is one duplicate group")
            check(byKey["arxivOnly2021"]?.ids.arxiv == "2101.00001", "arXiv id read from the arXiv DOI / extra field")
            check(byKey["smithDisks2020"]?.ids.doi == "10.1/abc", "DOI normalised")
            check(byKey["pinned2022"]?.folder == "pinned2022", "citekey pinned in extra (\"Citation Key: …\") is used")
            check(!plan.duplicates.contains { $0.citekeys.contains("chapterOne2014") },
                  "chapters sharing a book title but not a DOI are not duplicates")
            check(plan.duplicates.contains { Set($0.citekeys) == ["preprintSame2020", "publishedSame2020"] },
                  "a preprint and its journal version with the same title are duplicates")
            check(byKey["preprintSame2020"]?.ids.arxiv == "2202.00002", "arXiv id read from an arxiv.org/abs URL")

            print("Folder names")
            check(byKey["Odd Key/1"]?.folder == "Odd_Key_1", "unsafe citekey characters replaced")
            check(byKey["SMITHDISKS2020A"]?.folder.hasSuffix("-2") == true
                  || byKey["smithDisks2020a"]?.folder.hasSuffix("-2") == true,
                  "case-insensitive folder clash gets a suffix")

            print("Attachments")
            let a = byKey["smithDisks2020"]
            check(a?.pdf?.exists == true, "stored PDF resolves to the file in storage/")
            check(a?.otherAttachments == 1, "linked URL counted as another attachment")
            check(byKey["twoPdfs2019"]?.issues.contains { $0.contains("2 PDFs") } == true, "two PDFs flagged")
            check(t.orphanPDFs == 1 && t.orphanNotes == 1, "parentless PDF and note listed, not dropped")
            check(plan.collections["Proposal files"]?.files == 1
                  && plan.orphans.first { $0.kind == .pdf }?.collections == ["Proposal files"],
                  "a standalone PDF's collection is counted and listed")

            print("Annotations")
            check(a?.annotations.highlight == 1 && a?.annotations.ink == 1 && a?.annotations.figureRegions == 1,
                  "highlight, ink and image annotation counted; image becomes a figure region")
            check(t.annotationsOnOrphans == 1 && t.annotationsSkipped == 1,
                  "annotation on a parentless PDF kept with it; one in the trash skipped")

            print("Tags and collections")
            check(a?.status == "unread", "\"unread\" tag becomes reading status")
            check(a?.keywords.contains("stars: formation") == true && a?.keywords.contains("accretion") == true,
                  "journal keyword and automatic tag become keywords")
            check(a?.tags == ["favourite"], "only the user's own tag stays a tag (got \(a?.tags ?? []))")
            check(a?.projects == ["Proj project"], "project-like collection becomes a project")
            check(plan.collections["BigBucket"]?.action == .drop, "collection holding most papers is proposed for dropping")

            print("Mapping file overrides the proposal")
            let remapped = ZoteroImportPlanner.plan(lib, zoteroDir: fx.root, mapping: ["Proj project": .tag])
            check(remapped.papers.first { $0.citekey == "smithDisks2020" }?.tags.contains("Proj project") == true,
                  "a project collection mapped to tag becomes a tag")

            print("Vault citations")
            let v = ZoteroImportReport.checkVault(fx.vault, plan: plan)
            check(v.unresolved == ["eDisk2021", "latexOnly2003", "missingKey2001", "trashed2018"],
                  "unresolved keys found incl. \\autocite/\\textcite, email address ignored (got \(v.unresolved))")
            check(v.inZoteroTrash == ["trashed2018"], "a cited key in Zotero's trash is called out")
            check(v.onlyInVaultBib == ["eDisk2021"], "a cited key only in a vault .bib file is called out")
            check(v.notFound == ["latexOnly2003", "missingKey2001"], "a cited key found nowhere is called out")

            print("Report files")
            let out = fx.root.appendingPathComponent("out")
            _ = try ZoteroImportReport.generate(zoteroDir: fx.root, outDir: out, vault: fx.vault,
                                                mappingFile: nil, dbPathOverride: fx.db)
            let written = ["report.md", "plan.json", "collection-mapping.json"].allSatisfy {
                FileManager.default.fileExists(atPath: out.appendingPathComponent($0).path)
            }
            check(written, "report.md, plan.json and collection-mapping.json written")
            let mapping = out.appendingPathComponent("collection-mapping.json")
            let reread = try? JSONDecoder().decode([String: CollectionRule].self, from: Data(contentsOf: mapping))
            check(reread?["BigBucket"]?.action == .drop, "collection-mapping.json reads back as a mapping")
        } catch {
            print("  FAIL  fixture: \(error)")
            failures += 1
        }
        print(failures == 0 ? "\nLibrary self-test passed." : "\nLibrary self-test FAILED (\(failures)).")
        exit(failures == 0 ? 0 : 1)
    }

    /// A Zotero-schema subset with one example of each case the planner handles.
    struct Fixture {
        let root: URL, db: URL, vault: URL

        static func make() throws -> Fixture {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("nebula-lib-selftest-\(UUID().uuidString)")
            let storage = root.appendingPathComponent("storage")
            let vault = root.appendingPathComponent("vault")
            for d in [storage.appendingPathComponent("PDFA0001"), storage.appendingPathComponent("PDFORPH1"), vault] {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
            }
            try Data("%PDF-1.4\n".utf8).write(to: storage.appendingPathComponent("PDFA0001/a.pdf"))
            try Data("%PDF-1.4\n".utf8).write(to: storage.appendingPathComponent("PDFORPH1/orphan.pdf"))
            try """
            Disks [@smithDisks2020; @missingKey2001] and more \\citep{smithDisks2020a, eDisk2021}.
            Mail me@example.com, not a citation. Old one [@trashed2018].
            """.write(to: vault.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
            try "Cited as \\autocite{pinned2022}, \\textcite[p.~3]{chapterOne2014} and \\autocite{latexOnly2003}.\n"
                .write(to: vault.appendingPathComponent("paper.tex"), atomically: true, encoding: .utf8)
            try "@article{eDisk2021,\n  title={A disk}\n}\n"
                .write(to: vault.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)

            let dbURL = root.appendingPathComponent("zotero.sqlite")
            let db = try SQLiteDB(path: dbURL.path, create: true)
            try db.exec(schema + rows)
            return Fixture(root: root, db: dbURL, vault: vault)
        }

        static let schema = """
        CREATE TABLE items (itemID INTEGER PRIMARY KEY, itemTypeID INT, key TEXT);
        CREATE TABLE itemTypes (itemTypeID INTEGER PRIMARY KEY, typeName TEXT);
        CREATE TABLE fields (fieldID INTEGER PRIMARY KEY, fieldName TEXT);
        CREATE TABLE itemDataValues (valueID INTEGER PRIMARY KEY, value TEXT);
        CREATE TABLE itemData (itemID INT, fieldID INT, valueID INT);
        CREATE TABLE creators (creatorID INTEGER PRIMARY KEY, firstName TEXT, lastName TEXT);
        CREATE TABLE itemCreators (itemID INT, creatorID INT, orderIndex INT);
        CREATE TABLE tags (tagID INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE itemTags (itemID INT, tagID INT, type INT);
        CREATE TABLE collections (collectionID INTEGER PRIMARY KEY, collectionName TEXT, parentCollectionID INT);
        CREATE TABLE collectionItems (collectionID INT, itemID INT);
        CREATE TABLE itemAttachments (itemID INT, parentItemID INT, linkMode INT, contentType TEXT, path TEXT);
        CREATE TABLE itemNotes (itemID INT, parentItemID INT, title TEXT);
        CREATE TABLE itemAnnotations (itemID INT, parentItemID INT, type INT, authorName TEXT);
        CREATE TABLE deletedItems (itemID INT);
        INSERT INTO itemTypes VALUES (1,'journalArticle'),(2,'attachment'),(3,'note'),(4,'annotation');
        INSERT INTO fields VALUES (1,'citationKey'),(2,'title'),(3,'DOI'),(4,'date'),(5,'extra'),(6,'url');

        """

        // Item ids: 1 A, 2 B (dup of A), 3 unsafe key, 4 case clash with B,
        // 5 arXiv-only, 6 trashed (its attachment 22 and annotation 43 go
        // with it, as in Zotero, where only the parent is in deletedItems),
        // 7 two PDFs, 8–12 fillers, 13–14 book chapters sharing a title,
        // 15–16 a preprint and its journal version, 17 citekey pinned in extra.
        // Attachments 20–25, annotations 40–44, notes 60–61.
        static let rows: String = {
            var s = ""
            var v = 0
            func item(_ id: Int, _ key: String, _ cite: String, _ title: String,
                      doi: String? = nil, extra: String? = nil, url: String? = nil) {
                s += "INSERT INTO items VALUES (\(id),1,'\(key)');\n"
                let optional: [(Int, String)] = (doi.map { [(3, $0)] } ?? []) + (extra.map { [(5, $0)] } ?? [])
                    + (url.map { [(6, $0)] } ?? [])
                for (f, val) in [(1, cite), (2, title), (4, "2020-01-01")] + optional {
                    v += 1
                    s += "INSERT INTO itemDataValues VALUES (\(v),'\(val)'); INSERT INTO itemData VALUES (\(id),\(f),\(v));\n"
                }
            }
            item(1, "ITEMA001", "smithDisks2020", "Disks around young massive stars", doi: "10.1/abc")
            item(2, "ITEMB002", "smithDisks2020a", "Disks around young massive stars", doi: "https://doi.org/10.1/ABC")
            item(3, "ITEMC003", "Odd Key/1", "A paper with an odd key")
            item(4, "ITEMD004", "SMITHDISKS2020A", "Another paper entirely")
            item(5, "ITEME005", "arxivOnly2021", "A preprint", doi: "10.48550/arxiv.2101.00001", extra: "arXiv:2101.00001 [astro-ph]")
            item(6, "ITEMF006", "trashed2018", "Deleted paper")
            item(7, "ITEMG007", "twoPdfs2019", "Paper with two PDFs")
            for i in 8...12 { item(i, "FILL000\(i % 10)", "filler\(i)", "Filler paper number \(i)") }
            item(13, "CHAP0013", "chapterOne2014", "Protostars and Planets VI", doi: "10.2458/one")
            item(14, "CHAP0014", "chapterTwo2014", "Protostars and Planets VI", doi: "10.2458/two")
            item(15, "PREP0015", "preprintSame2020", "A result first posted on arXiv", url: "http://arxiv.org/abs/2202.00002")
            item(16, "PUBL0016", "publishedSame2020", "A result first posted on arXiv", doi: "10.9/pub")
            item(17, "PINN0017", "", "Paper whose key is pinned in extra", extra: "Citation Key: pinned2022")
            s += """
            INSERT INTO items VALUES (20,2,'PDFA0001'),(21,2,'LINKA001'),(22,2,'PDFF0001'),(23,2,'PDFG0001'),(24,2,'PDFG0002'),(25,2,'PDFORPH1');
            INSERT INTO itemAttachments VALUES (20,1,0,'application/pdf','storage:a.pdf'),
              (21,1,3,'text/html',NULL),
              (22,6,0,'application/pdf','storage:f.pdf'),
              (23,7,0,'application/pdf','storage:g1.pdf'),(24,7,0,'application/pdf','storage:g2.pdf'),
              (25,NULL,0,'application/pdf','storage:orphan.pdf');
            INSERT INTO items VALUES (40,4,'ANN00040'),(41,4,'ANN00041'),(42,4,'ANN00042'),(43,4,'ANN00043'),(44,4,'ANN00044');
            INSERT INTO itemAnnotations VALUES (40,20,1,''),(41,20,3,'tool'),(42,20,4,''),(43,22,1,''),(44,25,1,'');
            INSERT INTO items VALUES (60,3,'NOTE0060'),(61,3,'NOTE0061');
            INSERT INTO itemNotes VALUES (60,1,'Child note'),(61,NULL,'Standalone note');
            INSERT INTO deletedItems VALUES (6);
            INSERT INTO tags VALUES (1,'unread'),(2,'stars: formation'),(3,'Accretion'),(4,'favourite');
            INSERT INTO itemTags VALUES (1,1,0),(1,2,0),(1,3,1),(1,4,0);
            INSERT INTO collections VALUES (1,'Proj project',NULL),(2,'BigBucket',NULL),(3,'Proposal files',NULL);
            INSERT INTO collectionItems VALUES (3,25),(1,1),(2,1),(2,2),(2,3),(2,4),(2,5),(2,7),(2,8),(2,9),(2,10),(2,11),(2,12);
            INSERT INTO creators VALUES (1,'Ann','Smith');
            INSERT INTO itemCreators VALUES (1,1,0),(2,1,0);

            """
            return s
        }()
    }
}
