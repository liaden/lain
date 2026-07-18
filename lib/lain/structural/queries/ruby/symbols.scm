; Hand-authored for lain (MIT). Node patterns referenced from tree-sitter-ruby
; v0.23.1 queries (MIT).
;
; Each capture binds the NAME node DIRECTLY to a role, because Ext::TreeSitter
; returns FLAT captures with no per-match grouping: a @definition.method capture
; is already {name: <text>, role: "definition.method"}, needing no @name-vs-@def
; correlation. This is why we author our own rather than reuse tags.scm, whose
; @definition.* binds the whole node plus a SEPARATE @name.

; A module is Ruby's only namespace construct.
(module name: (constant) @definition.namespace)

; A class, and a singleton class (`class << self`) named by its value.
(class name: (constant) @definition.class)
(singleton_class value: (constant) @definition.class)

; An instance method and a singleton method (`def self.x`) -- distinct CST nodes,
; so both patterns are load-bearing, not redundant.
(method name: (identifier) @definition.method)
(singleton_method name: (identifier) @definition.method)

; A constant assignment (`MAX = 5`, `Config = Struct.new(...)`). The left side is
; a `constant` node, distinct from the `identifier` of a local assignment.
(assignment left: (constant) @definition.constant)

; A method call with an explicit receiver method name. A bare identifier is NOT
; captured as a reference: at this grammar level a local read and a paren-less
; call are indistinguishable, so binding it would flood definitions' own names.
(call method: (identifier) @reference.call)
