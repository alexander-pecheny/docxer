# Docxer

A fast macOS viewer and editor for Word `.docx` files.

## Language

**Package**:
The `.docx` file as a whole: a zip archive of XML and binary parts.
_Avoid_: file, archive

**Part**:
One entry inside a **Package**, such as the main document, the styles or an embedded image.

**Round-trip**:
Opening and saving a **Package** without losing or altering anything the user did not edit. A **Package** opened and saved with no edits comes out identical.

**Locked Region**:
The smallest span of the document that holds content the app does not understand. The app shows it but cannot edit it, and it survives saving unchanged. A block Locked Region is a table, a text box or a paragraph with a tracked change. An inline Locked Region is a field, a footnote reference or a shape, shown as its last displayed value.
_Avoid_: placeholder, unsupported block

**Bookmark**:
An invisible named marker in the text. It moves with its text, and deleting all its text deletes it.

**Sealed Object**:
An image or **Locked Region** that behaves as one character. The user can select, delete, cut and paste it within the same **Package**, but cannot edit inside it. Pasting it elsewhere yields only its text.
_Avoid_: embed, atom

**Outline**:
The list of **Outline Entries** shown beside the document, used to jump between sections.

**Outline Entry**:
A paragraph that has a heading style, or whose text starts with an **Outline Pattern**.

**Outline Pattern**:
A user-editable text pattern, such as "Вопрос N" or "Тур N", that marks a paragraph as an **Outline Entry** when the document uses no heading styles for it.

**Comment**:
A note attached to a range of document text, written by an **Author**. A **Comment** is either open or resolved.

**Anchor**:
The range of document text a **Comment** is attached to.

**Thread**:
A top-level **Comment** and its **Replies**, in order.

**Reply**:
A **Comment** that answers another **Comment** in the same **Thread**. It has no **Anchor** of its own.

**Author**:
The name and initials recorded on a **Comment**. The local user is the **Author** of any **Comment** they write.

## Relationships

- A **Package** contains one or more **Parts**
- Every **Locked Region** is preserved through a **Round-trip**
- A **Thread** has exactly one **Anchor**, owned by its top-level **Comment**
- Resolving a **Thread** resolves all its **Replies**
- Deleting all the text in an **Anchor** deletes its **Thread**, as Word does
