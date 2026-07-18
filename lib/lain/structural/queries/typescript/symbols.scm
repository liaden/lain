; Hand-authored for lain (MIT). Node patterns referenced from tree-sitter-typescript
; v0.23.2 queries (MIT).
;
; Each capture binds the NAME node DIRECTLY to a role, because Ext::TreeSitter
; returns FLAT captures with no per-match grouping (see the ruby query header).
; tags.scm ships here only covers `.d.ts` *_signature nodes; these patterns cover
; the concrete declaration nodes a real `.ts` source parses to (discovered via
; Ext::AstGrep.dump), which tags.scm does not.

; A namespace is an `internal_module` node (`namespace NS { ... }`).
(internal_module name: (identifier) @definition.namespace)

; A class, an abstract class, and an interface.
(class_declaration name: (type_identifier) @definition.class)
(abstract_class_declaration name: (type_identifier) @definition.class)
(interface_declaration name: (type_identifier) @definition.interface)

; A top-level function and a class/object method.
(function_declaration name: (identifier) @definition.function)
(method_definition name: (property_identifier) @definition.method)

; A type alias (`type Id = string`).
(type_alias_declaration name: (type_identifier) @definition.type)

; A bare call target (`doThing(...)`). A method call through a member expression
; (`obj.method(...)`) is left out here: its callee is a `member_expression`, not a
; plain identifier, so capturing it needs a separate pattern the flat surface
; would report only by the member name, losing the receiver.
(call_expression function: (identifier) @reference.call)
