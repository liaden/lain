; Hand-authored for lain (MIT). Node patterns referenced from tree-sitter-rust
; v0.24.2 queries (MIT). tree-sitter-rust ships no locals.scm, so these were
; authored from scratch against tags.scm's node names and Ext::AstGrep.dump.
;
; Each capture binds the NAME node DIRECTLY to a role, because Ext::TreeSitter
; returns FLAT captures with no per-match grouping (see the ruby query header).

; A module (`mod foo`) is Rust's namespace construct.
(mod_item name: (identifier) @definition.namespace)

; The ADT family -- struct, enum, union -- are all "class"-shaped definitions.
(struct_item name: (type_identifier) @definition.class)
(enum_item name: (type_identifier) @definition.class)
(union_item name: (type_identifier) @definition.class)

; A trait is an interface; a type alias is its own kind.
(trait_item name: (type_identifier) @definition.interface)
(type_item name: (type_identifier) @definition.type)

; A free `fn` and an `impl`/`trait` method are both `function_item`. Binding the
; kind uniformly as a function keeps the flat surface honest -- the grammar draws
; no method-vs-function node distinction, only a nesting one we do not walk here.
(function_item name: (identifier) @definition.function)

; A body-less signature -- a trait-required method or an `extern` fn declaration
; (`fn required(&self);`) -- is a `function_signature_item`, a different node than
; `function_item`, so it needs its own pattern or trait APIs go unlisted.
(function_signature_item name: (identifier) @definition.function)

; A bare call (`helper(...)`) and a macro invocation (`println!(...)`). A method
; call (`x.method(...)`) or path call (`Type::assoc(...)`) has a non-identifier
; callee, so it is left to a later, receiver-aware pattern.
(call_expression function: (identifier) @reference.call)
(macro_invocation macro: (identifier) @reference.call)
