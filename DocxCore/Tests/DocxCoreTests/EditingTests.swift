import XCTest
@testable import DocxCore

final class EditingTests: XCTestCase {
    func edit(_ d: WordDocument, _ s: NSMutableAttributedString, _ range: NSRange, _ text: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(d.allowsEdit(s, range: range, replacement: text), "edit refused", file: file, line: line)
        let from = range.location > 0 ? range.location - 1 : range.location
        var a = from < s.length ? s.attributes(at: from, effectiveRange: nil) : [:]
        if range.location < s.length, (s.string as NSString).character(at: from) == 10 { a = s.attributes(at: range.location, effectiveRange: nil) }
        s.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: WordDocument.typingAttributes(a)))
        d.normalize(s, editedRange: NSRange(location: range.location, length: (text as NSString).length))
    }

    func reopen(_ d: WordDocument, _ s: NSAttributedString) throws -> (WordDocument, NSMutableAttributedString) {
        let d2 = try WordDocument(bytes: d.save(s))
        return (d2, d2.load(styler: nil))
    }

    func testTypingFormattingStylesListsRoundTrip() throws {
        let d = WordDocument.blank()
        let s = d.load(styler: nil)
        XCTAssertEqual(s.string, "\n")
        edit(d, s, NSRange(location: 0, length: 0), "Title line\nFirst item\nSecond item\nBody & <text>")
        XCTAssertEqual(s.string, "Title line\nFirst item\nSecond item\nBody & <text>\n")
        d.setStyle("Heading1", in: s, range: NSRange(location: 0, length: 1))
        d.toggle(.bold, in: s, range: NSRange(location: 36, length: 4))
        d.toggleList(bullet: false, in: s, range: NSRange(location: 12, length: 15))
        let (d2, s2) = try reopen(d, s)
        XCTAssertEqual(s2.string, s.string)
        let paras = d2.paragraphs(s2, NSRange(location: 0, length: s2.length))
        XCTAssertEqual(paras.map { $0.1.styleId }, ["Heading1", nil, nil, nil])
        XCTAssertEqual(paras.map { d2.listKind($0.1) }, [nil, false, false, nil])
        XCTAssertTrue(d2.allOn(.bold, in: s2, range: NSRange(location: 36, length: 4)))
        XCTAssertFalse(d2.allOn(.bold, in: s2, range: NSRange(location: 35, length: 4)))
        var counters: [Int: [Int]] = [:]
        let labels = paras.compactMap { p in p.1.format.numId.flatMap { d2.numbering.label(numId: $0, ilvl: 0, counters: &counters) } }
        XCTAssertEqual(labels, ["1.", "2."])
    }

    func testBoldToggleOffInsideHeadingRemovesOverride() throws {
        let d = WordDocument.blank()
        let s = d.load(styler: nil)
        edit(d, s, NSRange(location: 0, length: 0), "Heading")
        d.setStyle("Heading1", in: s, range: NSRange(location: 0, length: 1))
        XCTAssertTrue(d.allOn(.bold, in: s, range: NSRange(location: 0, length: 7)))
        d.toggle(.bold, in: s, range: NSRange(location: 0, length: 3))
        XCTAssertFalse(d.allOn(.bold, in: s, range: NSRange(location: 0, length: 3)))
        d.toggle(.bold, in: s, range: NSRange(location: 0, length: 3))
        let run = s.attribute(.docxRun, at: 0, effectiveRange: nil) as! RunProps
        XCTAssertFalse(run.rPr.contains { $0.name == "w:b" }, "bold back on should defer to the style")
    }

    func testCommentsThreadResolveAndAnchorDeletion() throws {
        let d = WordDocument.blank()
        let s = d.load(styler: nil)
        edit(d, s, NSRange(location: 0, length: 0), "The budget is £40m this year\nNext")
        let c = d.addComment("Check this", author: "A P", initials: "AP", in: s, range: NSRange(location: 14, length: 4))
        d.reply(to: c, "Checked", author: "B", initials: "B", in: s)
        d.comments.setDone(c, true)
        var (d2, s2) = try reopen(d, s)
        XCTAssertEqual(d2.comments.comments.count, 2)
        let top = try XCTUnwrap(d2.comments.comments.first { $0.parentParaId == nil })
        XCTAssertEqual(top.text, "Check this")
        XCTAssertTrue(top.done)
        XCTAssertEqual(d2.comments.replies(to: top).map(\.text), ["Checked"])
        XCTAssertEqual(d2.commentAnchors(s2).first?.range, NSRange(location: 14, length: 4))

        // Shrinking the anchor keeps the thread; deleting all of it removes the thread, as Word does.
        edit(d2, s2, NSRange(location: 15, length: 3), "")
        (d2, s2) = try reopen(d2, s2)
        XCTAssertEqual(d2.comments.comments.count, 2)
        edit(d2, s2, NSRange(location: 0, length: 25), "")
        (d2, s2) = try reopen(d2, s2)
        XCTAssertEqual(d2.comments.comments.count, 0)
        XCTAssertEqual(s2.string, "\nNext\n")
    }

    func testSealedBlockStaysAlone() throws {
        let d = WordDocument.blank()
        let s = d.load(styler: nil)
        edit(d, s, NSRange(location: 0, length: 0), "before\nafter")
        let p = ParaProps.sealedBlock()
        let table = Sealed(xml: "<w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w=\"100\"/></w:tblGrid><w:tr><w:tc><w:p/></w:tc></w:tr></w:tbl>",
                           isBlock: true, display: .paragraphs([""]))
        s.insert(NSAttributedString(string: "\u{FFFC}\n", attributes: [.docxPara: p, .docxSealed: table]), at: 7)
        XCTAssertEqual(s.string, "before\n\u{FFFC}\nafter\n")
        XCTAssertFalse(d.allowsEdit(s, range: NSRange(location: 7, length: 0), replacement: "x"))
        XCTAssertFalse(d.allowsEdit(s, range: NSRange(location: 8, length: 0), replacement: "x"))
        XCTAssertFalse(d.allowsEdit(s, range: NSRange(location: 6, length: 1), replacement: ""), "backspace into block from before")
        XCTAssertFalse(d.allowsEdit(s, range: NSRange(location: 8, length: 1), replacement: ""), "join next paragraph into block")
        XCTAssertTrue(d.allowsEdit(s, range: NSRange(location: 7, length: 2), replacement: ""), "delete block")
        XCTAssertTrue(d.allowsEdit(s, range: NSRange(location: 3, length: 7), replacement: ""), "delete across block")
        XCTAssertTrue(d.allowsEdit(s, range: NSRange(location: 7, length: 0), replacement: "new\n"), "insert paragraph before block")
        d.markAllEdited(s)
        let (_, s2) = try reopen(d, s)
        XCTAssertEqual(s2.string, s.string)
        XCTAssertNotNil(s2.attribute(.docxSealed, at: 7, effectiveRange: nil))
    }

    func testSplitParagraphDoesNotDuplicateParaIdsOrSections() throws {
        let xml = """
        <w:p w14:paraId="11111111" w14:textId="22222222"><w:pPr><w:sectPr><w:pgSz w:w="100" w:h="100"/></w:sectPr></w:pPr><w:r><w:t>ab</w:t></w:r></w:p>
        """
        let d = try document(body: xml)
        let s = d.load(styler: nil)
        edit(d, s, NSRange(location: 1, length: 0), "\n")
        XCTAssertEqual(s.string, "a\nb\n")
        let out = String(decoding: try XCTUnwrap(try WordDocument(bytes: d.save(s)).package.part("word/document.xml")), as: UTF8.self)
        XCTAssertEqual(out.components(separatedBy: "11111111").count, 2)
        XCTAssertEqual(out.components(separatedBy: "<w:sectPr>").count, 2)
        XCTAssertTrue(out.range(of: "<w:t>a</w:t>")!.lowerBound < out.range(of: "<w:sectPr>")!.lowerBound, "section break stays on the last part")
    }

    func testBookmarksAcrossParagraphsSurviveEdits() throws {
        let xml = """
        <w:p><w:bookmarkStart w:id="0" w:name="bm"/><w:r><w:t>one</w:t></w:r></w:p><w:p><w:r><w:t>two</w:t></w:r><w:bookmarkEnd w:id="0"/></w:p>
        """
        let d = try document(body: xml)
        let s = d.load(styler: nil)
        edit(d, s, NSRange(location: 1, length: 0), "X")
        let out = String(decoding: try WordDocument(bytes: d.save(s)).package.part("word/document.xml")!, as: UTF8.self)
        XCTAssertEqual(out.components(separatedBy: "<w:bookmarkStart").count, 2)
        XCTAssertEqual(out.components(separatedBy: "<w:bookmarkEnd").count, 2)
        XCTAssertTrue(out.range(of: "bookmarkStart")!.lowerBound < out.range(of: "oXne")?.lowerBound ?? out.startIndex)
        XCTAssertTrue(out.range(of: "two")!.upperBound < out.range(of: "bookmarkEnd")!.lowerBound)
    }

    func document(body: String) throws -> WordDocument {
        let blank = WordDocument.blank()
        let main = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"><w:body>\(body)</w:body></w:document>
        """
        blank.package.setPart("word/document.xml", Array(main.utf8))
        return try WordDocument(bytes: blank.package.write())
    }
}

extension EditingTests {
    func testDeletingFromParagraphStartRewritesIt() throws {
        let d = try document(body: "<w:p><w:r><w:t>first</w:t></w:r></w:p><w:p><w:r><w:t>second para</w:t></w:r></w:p>")
        let s = d.load(styler: nil)
        edit(d, s, NSRange(location: 6, length: 7), "")
        let (_, s2) = try reopen(d, s)
        XCTAssertEqual(s2.string, "first\npara\n")
    }
}

extension EditingTests {
    func testFontFamilyAndSize() throws {
        let d = WordDocument.blank()
        let s = d.load(styler: nil)
        edit(d, s, NSRange(location: 0, length: 0), "Some text")
        d.setFont(family: "Georgia", size: 18, in: s, range: NSRange(location: 0, length: 4))
        let (d2, s2) = try reopen(d, s)
        let run = s2.attribute(.docxRun, at: 0, effectiveRange: nil) as! RunProps
        XCTAssertEqual(run.format.font, "Georgia")
        XCTAssertEqual(run.format.size, 18)
        XCTAssertEqual(d2.commonFont(in: s2, range: NSRange(location: 0, length: 4)).size, 18)
        XCTAssertNil(d2.commonFont(in: s2, range: NSRange(location: 0, length: 9)).size, "mixed sizes")
        // Setting the style's own size removes the override.
        d2.setFont(size: 12, in: s2, range: NSRange(location: 0, length: 4))
        XCTAssertFalse((s2.attribute(.docxRun, at: 0, effectiveRange: nil) as! RunProps).rPr.contains { $0.name == "w:sz" })
    }

    func testInsertImage() throws {
        let d = WordDocument.blank()
        let s = d.load(styler: nil)
        edit(d, s, NSRange(location: 0, length: 0), "ab")
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0,
                            0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 13, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0, 0x1F, 0, 5, 0,
                            1, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        let img = d.makeImage(png, ext: "png", width: 900, height: 450)
        var a = s.attributes(at: 0, effectiveRange: nil)
        a[.docxSealed] = img
        s.insert(NSAttributedString(string: "\u{FFFC}", attributes: a), at: 1)
        d.normalize(s, editedRange: NSRange(location: 1, length: 1))
        let bytes = d.save(s)
        if let out = ProcessInfo.processInfo.environment["DOCX_TEST_OUT"] { try Data(bytes).write(to: URL(fileURLWithPath: out)) }
        let d2 = try WordDocument(bytes: bytes)
        let s2 = d2.load(styler: nil)
        guard case .image(let rel, let w, let h)? = (s2.attribute(.docxSealed, at: 1, effectiveRange: nil) as? Sealed)?.display else {
            return XCTFail("no image")
        }
        XCTAssertEqual(w, d.textWidth, accuracy: 0.5)
        XCTAssertEqual(h, d.textWidth / 2, accuracy: 0.5)
        XCTAssertEqual(d2.package.partPath(forRelationship: rel).flatMap { d2.package.part($0) }, png)
    }
}
