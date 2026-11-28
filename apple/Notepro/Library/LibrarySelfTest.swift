import Foundation
import PDFKit

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
            check(t.orphanPDFs == 2 && t.orphanNotes == 1, "parentless PDFs and note listed, not dropped")
            check(plan.collections["Proposal files"]?.files == 1
                  && plan.orphans.contains { $0.kind == .pdf && $0.collections == ["Proposal files"] },
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

            print("Import into a library folder")
            let libRoot = fx.root.appendingPathComponent("library")
            // A folder that is not a library paper must never be overwritten.
            try FileManager.default.createDirectory(at: libRoot.appendingPathComponent("filler9"), withIntermediateDirectories: true)
            try "mine".write(to: libRoot.appendingPathComponent("filler9/keep.txt"), atomically: true, encoding: .utf8)
            var opts = LibraryImporter.Options()
            opts.zoteroDir = fx.root; opts.library = libRoot; opts.vault = fx.vault
            opts.restoreCited = true; opts.dbPathOverride = fx.db
            let r1 = try LibraryImporter.run(opts)
            let store = PaperLibraryStore(root: libRoot)
            check(r1.created == 16 && r1.skipped.count == 1 && r1.skipped[0].hasPrefix("filler9"),
                  "16 papers created; the foreign filler9 folder skipped (got \(r1.created), \(r1.skipped))")
            check(r1.restoredFromTrash == ["trashed2018"], "the trashed paper the vault cites is restored")
            check(store.meta(folder: "trashed2018") != nil, "restored paper has its folder")
            let am = store.meta(folder: "smithDisks2020")
            check(am?.status == "unread" && am?.pdf == "paper.pdf" && am?.bibliographic.creators.first?.family == "Smith",
                  "meta.json has status, PDF and creators")
            check(FileManager.default.fileExists(atPath: libRoot.appendingPathComponent("smithDisks2020/paper.pdf").path),
                  "PDF copied into the paper folder")
            let anns = store.read([LibraryAnnotation].self, from: libRoot.appendingPathComponent("smithDisks2020/annotations.json")) ?? []
            check(anns.count == 2 && anns.contains { $0.kind == .highlight && $0.text == "disk mass" && $0.rects?.first == [100, 200, 300, 212] }
                  && anns.contains { $0.kind == .ink && $0.paths?.first == [10, 10, 20, 20] },
                  "highlight and ink converted with their coordinates")
            let figs = store.read([LibraryFigure].self, from: libRoot.appendingPathComponent("smithDisks2020/figures.json")) ?? []
            check(figs == [LibraryFigure(label: "Figure 2", page: 3, rect: [50, 300, 550, 700], source: "zotero-figure")],
                  "image annotation became a labelled figure region")
            let note = try? String(contentsOf: libRoot.appendingPathComponent("smithDisks2020/notes/zotero-NOTE0060.md"), encoding: .utf8)
            check(note?.contains("# Child note") == true && note?.contains("**section 3**") == true, "child note converted to Markdown")
            let files = store.read([FileEntry].self, from: store.filesDir.appendingPathComponent("files.json")) ?? []
            check(files.count == 2 && files.contains { $0.name == "Proposal_files/orphan.pdf" }
                  && files.contains { $0.paperCandidate == "1994A&A...291..943O" },
                  "parentless PDFs copied to _files, the bibcode-named one marked to look up")

            print("Running the import again")
            var edited = anns
            edited.append(LibraryAnnotation(id: "c:1", kind: .highlight, page: 0, rects: [[0, 0, 1, 1]], color: "#000", author: "claude"))
            try store.write(edited, to: libRoot.appendingPathComponent("smithDisks2020/annotations.json"))
            var m = am!; m.lastPage = 7
            try store.write(m, to: libRoot.appendingPathComponent("smithDisks2020/meta.json"))
            let r2 = try LibraryImporter.run(opts)
            check(r2.created == 0 && r2.updated == 16 && r2.pdfsCopied == 0, "second run updates in place, copies nothing")
            let anns2 = store.read([LibraryAnnotation].self, from: libRoot.appendingPathComponent("smithDisks2020/annotations.json")) ?? []
            check(anns2.count == 3 && anns2.contains { $0.author == "claude" }, "annotations added in Nebula survive a re-import")
            check(store.meta(folder: "smithDisks2020")?.lastPage == 7, "reading position survives a re-import")
            check((try? String(contentsOf: libRoot.appendingPathComponent("filler9/keep.txt"), encoding: .utf8)) == "mine",
                  "the foreign folder is untouched")

            print("ADS check (offline, canned answers)")
            let fake: LibraryADS.Fetch = { q, _, _ in
                if q.contains("arXiv:2101.00001") {
                    return [["bibcode": "2021ApJ...900....1X", "doi": ["10.3847/X"], "pub": "ApJ", "volume": "900",
                             "page": ["1"], "year": "2021", "doctype": "article",
                             "identifier": ["arXiv:2101.00001", "2021ApJ...900....1X"]]]
                }
                if q == "bibcode:\"1994A&A...291..943O\"" {
                    return [["bibcode": "1994A&A...291..943O", "title": ["One"]]]
                }
                if q.contains("bibstem") {
                    return [["bibcode": "1994A&A...291..943O", "title": ["One"]], ["bibcode": "1994A&A...291..943P", "title": ["Two"]]]
                }
                return []
            }
            let dry = try LibraryADS.run(store: store, apply: false, fetch: fake)
            let up = dry.updates.first { $0.citekey == "arxivOnly2021" }
            check(up?.nowPublished == true && up?.journal == "ApJ" && up?.bibcode == "2021ApJ...900....1X",
                  "a preprint with a journal version is found")
            check(store.meta(folder: "arxivOnly2021")?.version == "preprint", "dry run changes nothing")
            check(dry.arxivPDFs["arxivOnly2021"] == "https://arxiv.org/pdf/2101.00001", "missing PDF offered from arXiv")
            check(dry.files.first { $0.hint == "1994A&A...291..943O" }?.matches.count == 1,
                  "a full bibcode file name matches exactly one paper")
            check(LibraryADS.bibcodeQuery("1987A&A...186.") == "year:1987 bibstem:\"A&A\" volume:186",
                  "a cut-short bibcode becomes a year/journal/volume query")
            _ = try LibraryADS.run(store: store, apply: true, fetch: fake)
            let pm = store.meta(folder: "arxivOnly2021")
            check(pm?.version == "published" && pm?.citekey == "arxivOnly2021" && pm?.ids.doi == "10.3847/x"
                  && pm?.bibliographic.fields["publicationTitle"] == "ApJ",
                  "--apply updates the journal data and keeps the citekey")

            print("arXiv PDFs (offline)")
            let onePage: Data = {
                let d = PDFDocument(); d.insert(PDFPage(), at: 0); return d.dataRepresentation() ?? Data()
            }()
            var asked: [URL] = []
            let pdfPlan = LibraryADS.Plan(arxivPDFs: ["arxivOnly2021": "https://arxiv.org/pdf/2101.00001",
                                                   "smithDisks2020": "https://arxiv.org/pdf/2001.00001"])
            let got = try LibraryADS.downloadArxiv(store: store, plan: pdfPlan, download: { asked.append($0); return onePage }, pause: 0)
            check(got.added == ["arxivOnly2021"] && store.meta(folder: "arxivOnly2021")?.pdf == "paper.pdf"
                  && FileManager.default.fileExists(atPath: libRoot.appendingPathComponent("arxivOnly2021/paper.pdf").path),
                  "a missing PDF is saved as paper.pdf and recorded in meta.json")
            check(got.skipped == ["smithDisks2020"] && asked.count == 1, "a paper that has a PDF is not downloaded again")
            if var m = store.meta(folder: "arxivOnly2021") {          // pretend it is missing again
                m.pdf = nil; try store.write(m, to: libRoot.appendingPathComponent("arxivOnly2021/meta.json"))
                try FileManager.default.removeItem(at: libRoot.appendingPathComponent("arxivOnly2021/paper.pdf"))
            }
            let bad = try LibraryADS.downloadArxiv(store: store, plan: pdfPlan, download: { _ in Data("<html>".utf8) }, pause: 0)
            check(bad.failed.count == 1 && store.meta(folder: "arxivOnly2021")?.pdf == nil
                  && !FileManager.default.fileExists(atPath: libRoot.appendingPathComponent("arxivOnly2021/paper.pdf").path),
                  "a page that is not a PDF is not kept")

            print("Merging duplicates")
            let fm = FileManager.default
            func folderOf(_ key: String) -> String? { store.allPapers().first { $0.meta.citekey == key }?.folder }
            guard let dupA = folderOf("smithDisks2020a") else { throw ZoteroImportError.missing("smithDisks2020a") }
            let dupDir = libRoot.appendingPathComponent(dupA)
            try onePage.write(to: dupDir.appendingPathComponent("paper.pdf"))          // a different PDF
            if var m = store.meta(folder: dupA) {
                m.pdf = "paper.pdf"; m.tags.append("from-duplicate")
                try store.write(m, to: dupDir.appendingPathComponent("meta.json"))
            }
            try fm.createDirectory(at: dupDir.appendingPathComponent("notes"), withIntermediateDirectories: true)
            try "dup note".write(to: dupDir.appendingPathComponent("notes/mine.md"), atomically: true, encoding: .utf8)
            var mp = LibraryMerge.makePlan(store: store, vault: fx.vault)
            let smith = mp.groups.first { $0.keep == "smithDisks2020" }
            check(smith?.merge == [dupA] && smith?.citekey == "smithDisks2020" && smith?.titleOnly == false && smith?.why.contains("annotations") == true,
                  "the annotated copy is the one kept (got \(String(describing: smith)))")
            let byTitle = mp.groups.first { Set($0.citekeys.values) == ["preprintSame2020", "publishedSame2020"] }
            check(byTitle?.titleOnly == true, "a title-only match is flagged for checking")
            for i in mp.groups.indices where mp.groups[i].titleOnly { mp.groups[i].skip = true }
            check(store.meta(folder: dupA) != nil, "planning changes nothing")
            let mr = try LibraryMerge.apply(mp, store: store)
            let kept = store.meta(folder: "smithDisks2020")
            check(mr.problems.isEmpty && store.meta(folder: dupA) == nil
                  && fm.fileExists(atPath: libRoot.appendingPathComponent(".merged/\(dupA)/meta.json").path),
                  "the merged-away folder moves whole to .merged (problems: \(mr.problems))")
            check(kept?.aliases.contains("smithDisks2020a") == true && kept?.tags.contains("from-duplicate") == true
                  && kept?.mergedZoteroKeys == ["ITEMB002"], "its citekey becomes an alias; tags and Zotero key carried over")
            check(fm.fileExists(atPath: libRoot.appendingPathComponent("smithDisks2020/paper-2.pdf").path)
                  && (store.read([LibraryAnnotation].self, from: libRoot.appendingPathComponent("smithDisks2020/annotations.json")) ?? []).count == 3,
                  "the other PDF is kept beside it; annotations untouched")
            check((try? String(contentsOf: libRoot.appendingPathComponent("smithDisks2020/notes/mine.md"), encoding: .utf8)) == "dup note",
                  "its notes are copied over")
            check(store.meta(folder: byTitle?.keep ?? "") != nil && byTitle?.merge.allSatisfy({ store.meta(folder: $0) != nil }) == true,
                  "a skipped group is left alone")
            let r3 = try LibraryImporter.run(opts)
            check(r3.mergedAway == 1 && folderOf("smithDisks2020a") == nil
                  && store.meta(folder: "smithDisks2020")?.aliases.contains("smithDisks2020a") == true,
                  "a re-import does not bring a merged paper back")

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
            for d in [storage.appendingPathComponent("PDFA0001"), storage.appendingPathComponent("PDFORPH1"),
                      storage.appendingPathComponent("PDFORPH2"), vault] {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
            }
            try Data("%PDF-1.4\n".utf8).write(to: storage.appendingPathComponent("PDFA0001/a.pdf"))
            try Data("%PDF-1.4\n".utf8).write(to: storage.appendingPathComponent("PDFORPH1/orphan.pdf"))
            try Data("%PDF-1.4\n".utf8).write(to: storage.appendingPathComponent("PDFORPH2/1994A&A...291..943O.pdf"))
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
        CREATE TABLE itemNotes (itemID INT, parentItemID INT, title TEXT, note TEXT);
        CREATE TABLE itemAnnotations (itemID INT, parentItemID INT, type INT, authorName TEXT,
          text TEXT, comment TEXT, color TEXT, pageLabel TEXT, position TEXT);
        CREATE TABLE deletedItems (itemID INT);
        INSERT INTO itemTypes VALUES (1,'journalArticle'),(2,'attachment'),(3,'note'),(4,'annotation');
        INSERT INTO fields VALUES (1,'citationKey'),(2,'title'),(3,'DOI'),(4,'date'),(5,'extra'),(6,'url');

        """

        // Item ids: 1 A, 2 B (dup of A), 3 unsafe key, 4 case clash with B,
        // 5 arXiv-only, 6 trashed (its attachment 22 and annotation 43 go
        // with it, as in Zotero, where only the parent is in deletedItems),
        // 7 two PDFs, 8–12 fillers, 13–14 book chapters sharing a title,
        // 15–16 a preprint and its journal version, 17 citekey pinned in extra.
        // Attachments 20–26 (25, 26 have no parent), annotations 40–44, notes 60–61.
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
            INSERT INTO items VALUES (20,2,'PDFA0001'),(21,2,'LINKA001'),(22,2,'PDFF0001'),(23,2,'PDFG0001'),(24,2,'PDFG0002'),(25,2,'PDFORPH1'),(26,2,'PDFORPH2');
            INSERT INTO itemAttachments VALUES (20,1,0,'application/pdf','storage:a.pdf'),
              (21,1,3,'text/html',NULL),
              (22,6,0,'application/pdf','storage:f.pdf'),
              (23,7,0,'application/pdf','storage:g1.pdf'),(24,7,0,'application/pdf','storage:g2.pdf'),
              (25,NULL,0,'application/pdf','storage:orphan.pdf'),
              (26,NULL,0,'application/pdf','storage:1994A&A...291..943O.pdf');
            INSERT INTO items VALUES (40,4,'ANN00040'),(41,4,'ANN00041'),(42,4,'ANN00042'),(43,4,'ANN00043'),(44,4,'ANN00044');
            INSERT INTO itemAnnotations VALUES
              (40,20,1,'','disk mass','key number','#ffd400','3','{"pageIndex":2,"rects":[[100,200,300,212]]}'),
              (41,20,3,'tool','','','#ffd400','4','{"pageIndex":3,"rects":[[50,300,550,700]]}'),
              (42,20,4,'','','','#2ea8e5','1','{"pageIndex":0,"width":1,"paths":[[10,10,20,20]]}'),
              (43,22,1,'','gone','','#ffd400','1','{"pageIndex":0,"rects":[[1,1,2,2]]}'),
              (44,25,1,'','loose','','#ffd400','1','{"pageIndex":0,"rects":[[1,1,2,2]]}');
            INSERT INTO items VALUES (60,3,'NOTE0060'),(61,3,'NOTE0061');
            INSERT INTO itemNotes VALUES (60,1,'Child note','<h1>Child note</h1><p>Read <b>section 3</b>.</p>'),
              (61,NULL,'Standalone note','<p>Hello</p>');
            INSERT INTO deletedItems VALUES (6);
            INSERT INTO tags VALUES (1,'unread'),(2,'stars: formation'),(3,'Accretion'),(4,'favourite'),(5,'Figure 2');
            INSERT INTO itemTags VALUES (1,1,0),(1,2,0),(1,3,1),(1,4,0),(41,5,0);
            INSERT INTO collections VALUES (1,'Proj project',NULL),(2,'BigBucket',NULL),(3,'Proposal files',NULL);
            INSERT INTO collectionItems VALUES (3,25),(1,1),(2,1),(2,2),(2,3),(2,4),(2,5),(2,7),(2,8),(2,9),(2,10),(2,11),(2,12);
            INSERT INTO creators VALUES (1,'Ann','Smith');
            INSERT INTO itemCreators VALUES (1,1,0),(2,1,0);

            """
            return s
        }()
    }
}
