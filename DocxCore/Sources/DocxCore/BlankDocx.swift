import Foundation

enum BlankDocx {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let xmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static var bytes: [UInt8] {
        let parts: [(String, String)] = [
            ("[Content_Types].xml", xmlHead + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
            </Types>
            """),
            ("_rels/.rels", xmlHead + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
            </Relationships>
            """),
            ("word/_rels/document.xml.rels", xmlHead + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
            </Relationships>
            """),
            ("word/document.xml", xmlHead + """
            <w:document xmlns:w="\(w)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <w:body><w:p/><w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
            <w:pgMar w:top="1134" w:right="850" w:bottom="1134" w:left="1701" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body>\
            </w:document>
            """),
            ("word/styles.xml", xmlHead + styles),
        ]
        return ZipWriter.write(parts.map { .data($0.0, Array($0.1.utf8)) }, source: nil)
    }

    static func heading(_ n: Int, size: Int) -> String {
        """
        <w:style w:type="paragraph" w:styleId="Heading\(n)"><w:name w:val="heading \(n)"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/>\
        <w:outlineLvl w:val="\(n - 1)"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr></w:style>
        """
    }

    static let styles = """
    <w:styles xmlns:w="\(w)"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/>\
    <w:sz w:val="24"/><w:szCs w:val="24"/><w:lang w:val="ru-RU" w:eastAsia="en-US" w:bidi="ar-SA"/></w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
    <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/></w:style>\
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="10"/><w:qFormat/>\
    <w:pPr><w:spacing w:after="160"/></w:pPr><w:rPr><w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr></w:style>\
    \(heading(1, size: 36))\(heading(2, size: 30))\(heading(3, size: 26))\
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/>\
    <w:pPr><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="CommentText"><w:name w:val="annotation text"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="99"/><w:semiHidden/>\
    <w:rPr><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>\
    <w:style w:type="character" w:styleId="CommentReference"><w:name w:val="annotation reference"/><w:basedOn w:val="DefaultParagraphFont"/>\
    <w:uiPriority w:val="99"/><w:semiHidden/><w:rPr><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr></w:style>\
    <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/>\
    <w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style></w:styles>
    """
}
