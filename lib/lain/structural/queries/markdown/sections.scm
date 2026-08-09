; Hand-authored for lain (MIT). Node patterns referenced from tree-sitter-md
; v0.5.3 (MIT), the block grammar ast-grep bundles as "markdown".
;
; Not a symbols query. Where <lang>/symbols.scm binds an identifier to a ROLE,
; this binds the two nodes a section chunker needs: the section itself, for its
; extent, and its ATX heading, for its text. Ext::TreeSitter returns FLAT
; captures with byte offsets and no per-match grouping, so the two are
; correlated by POSITION -- a heading whose start byte equals a section's is
; that section's heading -- which is why they are captured separately rather
; than as a heading nested inside a section pattern.

; Sections nest by heading level, so these arrive as OVERLAPPING ranges: an H2's
; section is contained in its H1's. Containment IS the hierarchy, and rebuilding
; it is the caller's job.
(section) @section

; ATX only, and deliberately so. A setext_heading node exists but opens NO
; section -- a document of two setext headings parses as one section holding
; both -- so capturing it would name a heading for a boundary the tree does not
; have. Setext-authored documents take the paragraph floor instead.
;
; The MIXED document is the case to know about, because an ordinary README is
; one: setext headings under ATX ones are absorbed into the enclosing ATX
; section. Every line is still covered exactly once and an oversized section
; still descends -- what is missing is only the LABEL, which names the ATX
; ancestry and never the setext heading a reader can see in the body. Capturing
; setext_heading here would not fix that; it would attach a heading to a section
; that does not exist.
;
; This is also the whole reason the grammar beats a regex: a `#` line inside a
; fenced code block is code_fence_content, never an atx_heading, so no boundary
; falls inside a fence and no unit is labelled by someone's example.
(atx_heading) @heading
