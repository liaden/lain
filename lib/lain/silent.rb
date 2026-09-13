# frozen_string_literal: true

module Lain
  # The startup-notice seam's null: a `notice:`/`notify:` keyword default
  # wherever a caller may not want to hear a component's non-fatal findings.
  # The protocol is one message, `#call(message)`, which is exactly what a
  # lambda already is -- so this stays a frozen Proc rather than a class
  # alongside {Sink::Null} and {Channel::Null}, whose protocols span several
  # methods standing in for a real collaborator (an I/O stream, an event
  # channel). One no-op, shared, so seven byte-identical definitions do not
  # drift out from under each other.
  SILENT = ->(_message) {}
end
