# Show documents as one continuous column, not pages

Version 1 has no pagination: text flows in one column at the document's text width, and headers, footers and page numbers are not shown, though they survive saving. Matching Word's page breaks is a long-running sink (LibreOffice still differs after 15 years), and paginating forces layout of everything above the visible page, which breaks the 200ms budget for opening 500-page documents. A read-only page preview may come later as a separate pass; it must not slow the editor.
