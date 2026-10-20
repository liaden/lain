# frozen_string_literal: true

module Lain
  Requester = Data.define(:name, :label, :role, :skill)

  # Who an acting agent is: the chat's own agent or a child it spawned. The
  # one value approvals, questions and remembered denials name an actor by.
  #
  # `name` is the identity a remembered denial is keyed on, and the journal
  # edge, so it stays a String there. `label` is what a surface shows, and
  # defaults to the name.
  #
  # Every member is refused at construction unless it is one bare word, because
  # each is rendered raw into the terminal and the nvim buffers. A newline
  # forges a whole second approval question in front of the real one, and in
  # {Frontend::Neovim::ApprovalView} it splits one row across two lines, so a
  # cursor resolves to the wrong pending. A blank one deletes the
  # approval_pending record downstream, where the presence check's raise is
  # rescued and degraded. A whitelist, since the escapes worth refusing are
  # not a set anyone can finish enumerating.
  #
  # The attributes are untyped so the refusal can `inspect` what the caller
  # really passed: a typed one would report the cast String and lose the
  # difference between nil and `""`.
  class Requester
    include Declarative

    NAME = /\A[\w-]+\z/

    REFUSAL = lambda { |_record, error|
      "must name who is asking in one bare word, got #{error[:value].inspect}"
    }
    private_constant :REFUSAL

    declare do
      attribute :name
      attribute :label
      attribute :role
      attribute :skill
      validates :name, format: { with: NAME, message: REFUSAL }
      validates :label, :role, :skill, format: { with: NAME, message: REFUSAL }, allow_nil: true
    end

    # @return [Requester] the chat's own agent
    def self.main = MAIN

    # @param requester [Requester, #to_s] a requester, or the bare word naming one
    # @return [Requester]
    def self.of(requester) = requester.is_a?(Requester) ? requester : new(name: requester)

    def initialize(name:, label: nil, role: nil, skill: nil)
      self.class.check!(name:, **{ label:, role:, skill: }.compact)

      super(name: -name.to_s, label: -(label || name).to_s, role: role && -role.to_s, skill: skill && -skill.to_s)
    end

    # Unvalidated, for a reader of a session file it did not write.
    #
    # @return [String] the label, with the role and skill it runs under when they add anything
    def self.shown(label:, role: nil, skill: nil)
      qualifiers = [(role unless role == label), skill].compact
      qualifiers.empty? ? label : "#{label} (#{qualifiers.join(", ")})"
    end

    # @return [String] {.shown} of this requester
    def to_s = self.class.shown(label:, role:, skill:)

    MAIN = new(name: "agent")
    private_constant :MAIN
  end
end
