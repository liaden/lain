# frozen_string_literal: true

require "msgpack"

module Lain
  module Remote
    # The messages lain, the relay and the phone exchange, as `crates/lain-wire`
    # defines them. rmp-serde writes a struct as a map of its fields in
    # declaration order and an enum as a one-key map naming the variant, so
    # each type here lists its fields in the Rust order and the bytes match.
    #
    # Decoding checks every field's type and refuses what Rust would refuse: a
    # positional array, an unknown variant, a missing required field. A key
    # Rust ignores, Ruby ignores too.
    module Wire
      VERSION = 2

      class Malformed < Error; end

      Scalar = Data.define(:classes) do
        def decode(value, field)
          return value if classes.any? { value.is_a?(_1) }

          raise Malformed, "#{field} must be #{classes.map(&:name).join(" or ")}, got #{value.inspect}"
        end
      end

      List = Data.define(:of) do
        def decode(value, field)
          raise Malformed, "#{field} must be a list, got #{value.inspect}" unless value.is_a?(Array)

          value.map { of.decode(_1, field) }
        end
      end

      Pair = Data.define(:first, :second) do
        def decode(value, field)
          raise Malformed, "#{field} must be a pair, got #{value.inspect}" unless value.is_a?(Array) && value.size == 2

          [first.decode(value[0], field), second.decode(value[1], field)]
        end
      end

      # An `Option`: absent or nil reads as nil. `skipped` is serde's
      # skip_serializing_if, which leaves a nil out of the map entirely.
      Optional = Data.define(:of, :skipped) do
        def decode(value, field) = value.nil? ? nil : of.decode(value, field)
      end

      TEXT = Scalar.new([String])
      COUNT = Scalar.new([Integer])
      FLAG = Scalar.new([TrueClass, FalseClass])

      def self.optional(of, skipped: false) = Optional.new(of:, skipped:)

      # A struct: a map of its fields, in order. A variant of an enum is wrapped
      # in a one-key map naming it.
      module Message
        def self.define(**fields)
          Data.define(*fields.keys) do
            extend ClassMethods
            include Message

            const_set(:FIELDS, fields.freeze)
          end
        end

        def to_wire
          tag = self.class.tag
          tag ? { tag => fields_to_wire } : fields_to_wire
        end

        private

        def fields_to_wire
          self.class::FIELDS.each_with_object({}) do |(name, type), map|
            value = public_send(name)
            map[name.to_s] = Wire.wired(value) unless value.nil? && type.is_a?(Optional) && type.skipped
          end
        end

        # How a message class reads itself off the wire.
        module ClassMethods
          def tagged(tag) = tap { const_set(:TAG, -tag) }

          # The variant name a message wears when it is one, nil for a plain struct.
          def tag = const_defined?(:TAG, false) ? self::TAG : nil

          def from_wire(map)
            raise Malformed, "#{name} must be a msgpack map, got #{map.class}" unless map.is_a?(Hash)

            new(**self::FIELDS.to_h { |field, type| [field, type.decode(field_of(map, field, type), field)] })
          end

          def decode(value, _field) = from_wire(value)

          private

          def field_of(map, field, type)
            map.fetch(field.to_s) do
              raise Malformed, "#{name} has no #{field}" unless type.is_a?(Optional)
            end
          end
        end
      end

      # An enum: a one-key map from the variant's name to its fields.
      module Enum
        def from_wire(map)
          unless map.is_a?(Hash) && map.size == 1
            raise Malformed, "#{name} is a one-key msgpack map naming its variant, got #{map.inspect[0, 64]}"
          end

          tag, fields = map.first
          variant(tag).from_wire(fields)
        end

        def decode(value, _field) = from_wire(value)

        private

        def variant(tag) = variants.fetch(tag) { raise Malformed, "#{name} has no variant #{tag.inspect}" }
      end

      # Approval's own verdicts travel as they are, so an answer needs no translation.
      module Verdict
        extend Enum

        VARIANTS = { "Approve" => Approval::Verdict::Approve, "Hold" => Approval::Verdict::Hold,
                     "Deny" => Approval::Verdict::Deny }.freeze
        NOTE = Optional.new(of: TEXT, skipped: false)

        def self.variants = VARIANTS

        def self.to_wire(verdict) = { VARIANTS.key(verdict.class) => { "note" => verdict.note } }

        # A verdict's fields are its note alone.
        Fields = Struct.new(:variant) do
          def from_wire(map)
            raise Malformed, "a verdict's fields must be a msgpack map, got #{map.class}" unless map.is_a?(Hash)

            variant.new(note: NOTE.decode(map["note"], :note))
          end
        end

        def self.variant(tag) = Fields.new(super)
        private_class_method :variant
      end

      Hello = Message.define(wire_version: COUNT, token: TEXT, cursor: COUNT)
      Welcome = Message.define(wire_version: COUNT, head: COUNT, epoch: COUNT)
      Cursor = Message.define(cursor: COUNT, epoch: optional(COUNT))

      # One thing waiting on a human, as the phone is shown it, with the session and project it waits in.
      module Item
        SOURCE = { session: TEXT, project: TEXT }.freeze

        ParkedCall = Message.define(id: TEXT, requester: TEXT, tool: TEXT, input: TEXT, cwd: TEXT, why: TEXT,
                                    postponed: FLAG, asked_at: COUNT, **SOURCE)
        GateQuestion = Message.define(id: TEXT, requester: TEXT, epic: TEXT, stage: TEXT, issues: List.new(TEXT),
                                      question: TEXT, asked_at: COUNT, **SOURCE)
        Question = Message.define(id: TEXT, requester: TEXT, question: TEXT, options: List.new(TEXT), asked_at: COUNT,
                                  **SOURCE)

        extend Enum

        VARIANTS = { "ParkedCall" => ParkedCall.tagged("ParkedCall"),
                     "GateQuestion" => GateQuestion.tagged("GateQuestion"),
                     "Question" => Question.tagged("Question") }.freeze

        def self.variants = VARIANTS
      end

      # The phone's reply to one item, stamped by the relay with the device that gave it.
      module Answer
        Call = Message.define(id: TEXT, verdict: Verdict, device: Wire.optional(TEXT, skipped: true))
        Gate = Message.define(id: TEXT, verdicts: List.new(Pair.new(TEXT, Verdict)),
                              device: Wire.optional(TEXT, skipped: true))
        Question = Message.define(id: TEXT, option: Wire.optional(TEXT), text: Wire.optional(TEXT),
                                  device: Wire.optional(TEXT, skipped: true))

        extend Enum

        VARIANTS = { "Call" => Call.tagged("Call"), "Gate" => Gate.tagged("Gate"),
                     "Question" => Question.tagged("Question") }.freeze

        def self.variants = VARIANTS
      end

      Delta = Message.define(cursor: COUNT, added: List.new(Item), settled: List.new(TEXT))
      AgendaPage = Message.define(epoch: COUNT, cursor: COUNT, reset: FLAG, deltas: List.new(Delta))
      AnswersPage = Message.define(epoch: COUNT, cursor: COUNT, reset: FLAG, answers: List.new(Answer))

      # @param message [Message, Approval::Verdict::Approve, Approval::Verdict::Hold, Approval::Verdict::Deny]
      # @return [String] the msgpack bytes rmp-serde writes for the same message
      def self.pack(message) = MessagePack.pack(wired(message))

      # @param bytes [String]
      # @param as [#from_wire] the message type or enum to read
      # @return [Object] the decoded message
      # @raise [Malformed] for bytes the Rust decoder would refuse
      def self.unpack(bytes, as:)
        as.from_wire(MessagePack.unpack(bytes))
      rescue MessagePack::MalformedFormatError, EOFError => e
        raise Malformed, "not msgpack: #{e.message}"
      end

      # @param value [Object] a message, a verdict, a list of them, or a scalar
      # @return [Object] the plain value msgpack packs
      def self.wired(value)
        case value
        when Message then value.to_wire
        when *Verdict::VARIANTS.values then Verdict.to_wire(value)
        when Array then value.map { wired(_1) }
        when String then value.encoding == Encoding::UTF_8 ? value : value.dup.force_encoding(Encoding::UTF_8)
        else value
        end
      end
    end
  end
end
