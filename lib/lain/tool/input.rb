# frozen_string_literal: true

require "active_model"

module Lain
  class Tool
    # A declarative description of a tool's input, from which BOTH the JSON Schema
    # the model sees and the local validation are derived. One declaration, so the
    # wire contract and the runtime check cannot drift apart -- the same reasoning
    # that makes {Lain::Canonical} serve turn hashing and cache stability at once.
    #
    # ActiveModel also gives type coercion for free: a `:integer` attribute
    # arrives as an Integer whether the model sent `30` or `"30"`.
    #
    # == Where the security boundary actually is
    #
    # These validations check *shape*, not *safety*. They exist to reject
    # malformed calls early, with a legible message the model can learn from.
    #
    # They are NOT a security control, and must never be relied on as one. A
    # validation over a shell command string is pattern-matching against an
    # adversarially flexible grammar: `$(...)`, backticks, `${IFS}`, `eval`,
    # `base64 -d | sh`, and glob expansion all defeat any allowlist regex you can
    # write. A `format:` validator that "only permits safe commands" is a comforting
    # lie.
    #
    # The real boundary lives in three other places:
    #
    #   1. Tool tier. A structured tool (`delete_file(path:)` calling `File.delete`)
    #      has no string to interpolate. Prefer it to shelling out. A pre-canned
    #      command tool passes an argv *Array* to Mixlib::ShellOut, which execs with
    #      no shell at all -- only a String command goes through `sh -c`.
    #   2. `Handler::Approving`, which gates the invocation before it happens.
    #   3. OS confinement -- landlock, seccomp, namespaces, cgroups -- in the
    #      out-of-process Rust exec boundary (M5/M6). A forked child is a process
    #      boundary, not a security boundary: it inherits our uid, filesystem, and
    #      network.
    #
    # So: validate that `timeout` is a positive integer under ten minutes. Do not
    # pretend to validate that `command` is safe.
    class Input
      include ActiveModel::Model
      include ActiveModel::Attributes

      JSON_TYPES = {
        "string" => "string",
        "integer" => "integer",
        "float" => "number",
        "decimal" => "number",
        "boolean" => "boolean"
      }.freeze

      class << self
        # ActiveModel::Naming demands a class name, and Input subclasses are often
        # anonymous (declared inline, or via Class.new in a spec). Without this,
        # `errors.full_messages` raises before it can tell you what was wrong with
        # the input -- an error path that fails is worse than no error path.
        def model_name
          @model_name ||= ActiveModel::Name.new(self, nil, name || "Input")
        end

        # Declared fields, inherited so a subclass composes rather than overwrites.
        def fields
          @fields ||= superclass.respond_to?(:fields) ? superclass.fields.dup : {}
        end

        # Declare one input field. `description` is model-facing and is the single
        # highest-leverage lever on tool-call accuracy, so it is required.
        #
        # Note on `required:` and booleans: `presence: true` rejects `false`, which
        # is virtually never what you mean. A required boolean is validated by
        # inclusion in [true, false] instead.
        def field(name, type = :string, description:, required: false, **)
          attribute(name, type, **)
          fields[name.to_s] = { type: type.to_s, description:, required: }
          require_field(name, type) if required
          name
        end

        # The property names the model must supply.
        def required_fields
          fields.select { |_, meta| meta[:required] }.keys
        end

        # Build and coerce from the model's parsed input Hash. Unknown keys are a
        # hard error rather than being silently dropped: a tool call naming a field
        # we do not have is a misunderstanding worth surfacing.
        def build(input)
          new(**symbolize(input))
        rescue ActiveModel::UnknownAttributeError => e
          raise InvalidInput, e.message
        end

        # The JSON Schema sent to the provider, derived from the same declarations.
        def to_json_schema
          {
            "type" => "object",
            "properties" => fields.keys.to_h { |name| [name, property_schema(name)] },
            "required" => required_fields,
            "additionalProperties" => false
          }
        end

        private

        def require_field(name, type)
          if type.to_s == "boolean"
            validates(name, inclusion: { in: [true, false] })
          else
            validates(name, presence: true)
          end
        end

        def symbolize(input)
          input.to_h { |key, value| [key.to_sym, value] }
        end

        def property_schema(name)
          meta = fields.fetch(name)
          schema = { "type" => JSON_TYPES.fetch(meta[:type], "string"), "description" => meta[:description] }
          validators_on(name).each { |validator| apply_constraint(schema, validator) }
          schema
        end

        # Only the constraints JSON Schema can actually express are carried across.
        # Anything else stays a local check, which is fine: the schema is a hint to
        # the model, and #build is the enforcement.
        def apply_constraint(schema, validator)
          case validator
          when ActiveModel::Validations::InclusionValidator then apply_enum(schema, validator)
          when ActiveModel::Validations::LengthValidator then apply_length(schema, validator)
          when ActiveModel::Validations::FormatValidator then apply_pattern(schema, validator)
          when ActiveModel::Validations::NumericalityValidator then apply_bounds(schema, validator)
          end
        end

        # A required boolean is expressed as inclusion in [true, false]; that is a
        # presence check, not a meaningful enum, so it is not emitted.
        def apply_enum(schema, validator)
          values = Array(validator.options[:in])
          schema["enum"] = values unless values.sort_by(&:to_s) == [false, true].sort_by(&:to_s)
        end

        def apply_length(schema, validator)
          schema["minLength"] = validator.options[:minimum] if validator.options[:minimum]
          schema["maxLength"] = validator.options[:maximum] if validator.options[:maximum]
        end

        def apply_pattern(schema, validator)
          pattern = validator.options[:with]
          schema["pattern"] = pattern.source if pattern.respond_to?(:source)
        end

        def apply_bounds(schema, validator)
          options = validator.options
          schema["minimum"] = options[:greater_than_or_equal_to] if options[:greater_than_or_equal_to]
          schema["maximum"] = options[:less_than_or_equal_to] if options[:less_than_or_equal_to]
          schema["exclusiveMinimum"] = options[:greater_than] if options[:greater_than]
          schema["exclusiveMaximum"] = options[:less_than] if options[:less_than]
        end
      end

      # The validated fields as a plain Hash, for a #perform that prefers one.
      def to_h
        self.class.fields.keys.to_h { |name| [name, public_send(name)] }
      end
    end
  end
end
