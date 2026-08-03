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
    #   2. `Effect::Handler::Gate`, which gates the invocation before it happens.
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
        "boolean" => "boolean",
        "array" => "array"
      }.freeze

      class << self
        # ActiveModel::Naming demands a class name, and Input subclasses are often
        # anonymous (declared inline, or via Class.new in a spec). Without this,
        # `errors.full_messages` raises before it can tell you what was wrong with
        # the input -- an error path that fails is worse than no error path.
        def model_name
          @model_name ||= ActiveModel::Name.new(self, nil, name || "Input")
        end

        # Declared fields, inherited so a subclass composes rather than
        # overwrites. The entries are duped too: a shallow `dup` would share
        # each field's meta Hash with the superclass, so a child touching one
        # would rewrite its parent's schema.
        def fields
          @fields ||= superclass.respond_to?(:fields) ? superclass.fields.transform_values(&:dup) : {}
        end

        # Declare one input field. `description` is model-facing and is the single
        # highest-leverage lever on tool-call accuracy, so it is required.
        #
        # Note on `required:` and booleans: `presence: true` rejects `false`, which
        # is virtually never what you mean. A required boolean is validated by
        # inclusion in [true, false] instead.
        #
        # `blank_ok:` is the same kind of carve-out for a required field whose
        # legitimate value can be `""` or `[]` -- a whole-file writer's `content`
        # and a todo list being CLEARED are the motivating cases: the model must
        # still SUPPLY the key (it stays in the JSON Schema's `required`), but an
        # empty file and an empty list are real, first-class things to send, and
        # `presence: true` treats both as absent. `blank_ok` keeps the "key must
        # be present" check (nil is still rejected) and drops the rest.
        #
        # An `:array` field names its element shape with `of:` -- a scalar type
        # (`of: :string`) or an Input subclass -- or declares one inline with a
        # block of `field` calls, which is the readable form for the nested
        # objects a list-carrying tool actually wants.
        def field(name, type = :string, description:, required: false, blank_ok: false, of: nil, **, &block)
          raise ArgumentError, "#{name}: `blank_ok:` carves out an undeclared `required:`" if blank_ok && !required

          element = element_for(name, type, of, &block)
          attribute(name, element ? ArrayOf.new(element) : type, **)
          fields[name.to_s] = { type: element ? "array" : type.to_s, description:, required:, element: }.compact
          require_field(name, type, blank_ok:) if required
          name
        end

        # The property names the model must supply.
        def required_fields
          fields.select { |_, meta| meta[:required] }.keys
        end

        # Build and coerce from the model's parsed input Hash.
        #
        # This RAISES {InvalidInput} -- it does not merely return an invalid
        # model -- for everything it cannot express as a per-attribute error: an
        # unknown key, a key spelled both String and Symbol, a non-Array given
        # to an array field, and any element a declared element shape refuses.
        # The element cases raise because ActiveModel's error set is flat and
        # per-attribute, with no home for "element 1 of `people`", and an index
        # that never reaches the model makes a twenty-item list unfixable. A
        # field's OWN validity is still deferred to `valid?` as usual, so a
        # caller writing `model = build(h); model.valid?` must be ready for both.
        def build(input)
          new(**symbolize(elements_of(input)))
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

        def element_for(name, type, of, &block)
          declares_elements = of || block
          refuse_contradiction(name, type, declares_elements:, both: of && block)

          declares_elements && Element.for(block ? element_class(name, &block) : of)
        end

        # A declaration that says two contradictory things is a mistake at the
        # one moment it is cheap to catch, so each is refused rather than
        # resolved by a precedence rule nobody would remember.
        def refuse_contradiction(name, type, declares_elements:, both:)
          raise ArgumentError, "#{name}: give `of:` or a block of element fields, not both" if both
          raise ArgumentError, "#{name}: an :array field needs `of:` or a block of element fields" if
            !declares_elements && type.to_s == "array"
          raise ArgumentError, "#{name}: a field declaring elements is an :array, not #{type.inspect}" if
            declares_elements && type.to_s != "array"
        end

        # An anonymous element class reports a bad member as "unknown attribute
        # 'age' for #<Class:0x00007f...>". Naming it after the field it belongs
        # to is the difference between a message a model can act on and a heap
        # address. Only `to_s` is overridden -- `name` staying nil is what
        # {.model_name} already handles.
        def element_class(name, &block)
          label = "#{model_name.name}::#{name}"
          Class.new(Input, &block).tap { |klass| klass.define_singleton_method(:to_s) { label } }
        end

        # Elements are coerced and checked HERE rather than inside ArrayOf#cast
        # because a type's cast is lazy -- nothing would run until something
        # read the attribute, and a malformed element has to be refused at the
        # door, while the raw wire input is still in hand to name.
        def elements_of(input)
          input.to_h { |key, value| [key, element_values(key, value)] }
        end

        def element_values(key, value)
          element = fields.dig(key.to_s, :element)
          return value if element.nil? || value.nil?

          raise InvalidInput, "#{key} must be an array" unless value.is_a?(Array)

          value.map.with_index { |raw, index| element.build(raw, "#{key}[#{index}]") }
        end

        def require_field(name, type, blank_ok: false)
          if type.to_s == "boolean"
            validates(name, inclusion: { in: [true, false] })
          elsif blank_ok
            # A direct nil check, and NOT `exclusion: { in: [nil] }`: Clusivity
            # special-cases an Array value and tests it ELEMENT-WISE, so `[].all?`
            # is vacuously true and the empty list gets reported "can't be nil" --
            # rejecting the one value blank_ok exists to admit. `presence: true`
            # is no help either, since `[]` and `""` are both blank, and blank is
            # precisely the rejection being lifted. So: the key must be supplied,
            # and nothing else is asked.
            validates_each(name) do |record, attribute, value|
              record.errors.add(attribute, "can't be nil") if value.nil?
            end
          else
            validates(name, presence: true)
          end
        end

        # Duplicate String and Symbol spellings of one key are genuinely
        # ambiguous -- nothing justifies preferring either -- and
        # {Lain::Canonical} already refuses exactly this rather than letting the
        # last one win.
        def symbolize(input)
          input.each_with_object({}) do |(key, value), attributes|
            symbol = key.to_sym
            raise InvalidInput, "#{symbol.inspect} is both a String and a Symbol key" if attributes.key?(symbol)

            attributes[symbol] = value
          end
        end

        def property_schema(name)
          Property.new(name, fields.fetch(name), validators_on(name)).to_json_schema
        end
      end

      # The validated fields as a plain Hash, all the way down: an element that
      # is itself an Input becomes its own Hash, and a list of them maps.
      #
      # The ATTRIBUTE readers keep handing back the elements themselves --
      # `item.content` is the message a #perform should depend on, not a key
      # spelling. `to_h` is the other shape, the one a caller serializes, and an
      # Input reaching `to_json` neither fails nor renders: it writes a heap
      # address into what may be a Journal line, and the Journal is the
      # experiment record.
      def to_h
        self.class.fields.keys.to_h { |name| [name, plain(public_send(name))] }
      end

      private

      def plain(value)
        case value
        when Input then value.to_h
        when Array then value.map { |item| plain(item) }
        else value
        end
      end
    end

    # The machinery `field` is built from, in a REOPENED Input so the
    # behavioural core above stays measurably small -- the same reason
    # {Tool::Result} lives in a reopened {Tool}. None of it is DSL a tool author
    # writes, so all of it is private.
    class Input
      # One element of an array field. Both shapes answer the same three
      # messages -- `cast` for a single raw value, `checked` for one vetted as
      # well as coerced, and `to_json_schema` for the `items` fragment -- so
      # neither the array type nor the schema emitter ever asks which it holds.
      class Element
        # An Input subclass answers `to_json_schema`; anything else names a
        # scalar ActiveModel type.
        def self.for(kind)
          kind.respond_to?(:to_json_schema) ? Record.new(kind) : Scalar.new(kind)
        end

        # Coerce and check one element, re-raising ANY failure with `label`
        # prepended. Two reasons the rescue is this wide: a list of twenty todos
        # is only fixable if the message says WHICH one was wrong, and a cast
        # fails in ways ActiveModel never wraps (`Object#to_f` is a
        # NoMethodError), which would otherwise reach the model as Ruby
        # internals carrying neither field name nor index.
        def build(raw, label)
          checked(raw)
        rescue StandardError => e
          raise InvalidInput, "#{label}: #{e.message}"
        end

        def cast(_raw) = raise(NotImplemented, "#{self.class} must define #cast")
        def checked(_raw) = raise(NotImplemented, "#{self.class} must define #checked")
        def to_json_schema = raise(NotImplemented, "#{self.class} must define #to_json_schema")

        # A scalar element, cast exactly as a top-level field of that type is.
        class Scalar < Element
          # ActiveModel's cast is forgiving by design: at the top level "30" and
          # 30 are one integer, which is the whole point. Inside a list the same
          # forgiveness is a hole -- `"abc".to_i` is 0, `{}` casts to nil, and
          # every value that is not `false` is a true Boolean -- so garbage lands
          # in an array whose `items` schema promised the model something else,
          # which is exactly the drift this class exists to stop. These admit the
          # JSON type `items` names, plus a String that converts to it without
          # anything being invented, and nothing more.
          CASTABLE = {
            "string" => ->(raw) { raw.is_a?(::String) || raw.is_a?(::Symbol) || raw.is_a?(::Numeric) },
            # Decimal-only on purpose: `Integer("0x1f")` is 31 but ActiveModel casts
            # it to 0, so `Kernel::Integer` as the gate would admit a value and then
            # store a DIFFERENT one. The gate has to agree with the cast, not with Ruby.
            "integer" => ->(raw) { raw.to_s.match?(/\A\s*[-+]?\d+\s*\z/) },
            "number" => ->(raw) { raw.to_s.match?(/\A\s*[-+]?\d+(\.\d+)?([eE][-+]?\d+)?\s*\z/) },
            "boolean" => ->(raw) { [true, false, "true", "false"].include?(raw) }
          }.freeze
          private_constant :CASTABLE

          def initialize(name)
            @json_type = JSON_TYPES.fetch(name.to_s, "string")
            @castable = CASTABLE.fetch(@json_type) do
              raise ArgumentError, "`of: #{name.inspect}` has no element shape of its own; nest an Input instead"
            end
            @type = ActiveModel::Type.lookup(name)
            super()
          end

          def cast(raw) = @type.cast(raw)

          def checked(raw)
            raise InvalidInput, "must be a JSON #{@json_type}" unless @castable.call(raw)

            cast(raw)
          end

          def to_json_schema = { "type" => @json_type }
        end

        # An object element, described by a nested Input subclass -- so its
        # items schema and its own validation come from one declaration, exactly
        # as they do at the top level.
        class Record < Element
          def initialize(model)
            @model = model
            super()
          end

          def cast(raw)
            return raw if raw.is_a?(@model)
            raise InvalidInput, "must be an object" unless raw.is_a?(Hash)

            @model.build(raw)
          end

          def checked(raw)
            element = cast(raw)
            raise InvalidInput, element.errors.full_messages.join(", ") unless element.valid?

            element
          end

          def to_json_schema = @model.to_json_schema
        end
      end

      # ActiveModel has no `:array` type, and registering one would leak into
      # every ActiveModel in the process. An array field is declared with a type
      # INSTANCE built per declaration instead; `attribute` takes one as readily
      # as a registered symbol.
      class ArrayOf < ActiveModel::Type::Value
        def initialize(element)
          @element = element
          super()
        end

        def type = :array

        # A non-Array passes through untouched: an omitted array must stay nil
        # rather than become `[]`, which is blank and would satisfy the very
        # presence check `required` exists to make.
        def cast(value)
          value.is_a?(Array) ? value.map { |raw| @element.cast(raw) } : value
        end
      end

      # One field's JSON Schema, derived from the same declaration that drives
      # its validation. It is its own object because the mapping from ActiveModel
      # validators to JSON Schema keywords is its own subject -- above all,
      # WHERE a keyword belongs once a field describes a list rather than a value.
      class Property
        def initialize(name, meta, validators)
          @name = name
          @meta = meta
          @validators = validators
        end

        def to_json_schema
          schema = { "type" => JSON_TYPES.fetch(@meta[:type], "string"), "description" => @meta[:description] }
          schema["items"] = @meta[:element].to_json_schema if @meta[:element]
          @validators.each { |validator| apply(schema, validator) }
          schema
        end

        private

        # Only the constraints JSON Schema can actually express are carried
        # across. Anything else stays a local check, which is fine: the schema is
        # a hint to the model, and #build is the enforcement.
        def apply(schema, validator)
          case validator
          when ActiveModel::Validations::InclusionValidator
            apply_enum(per_value_schema(schema), validator)
          when ActiveModel::Validations::LengthValidator
            apply_length(schema, validator)
          when ActiveModel::Validations::FormatValidator
            apply_pattern(scalar_only(schema, "a pattern"), validator)
          when ActiveModel::Validations::NumericalityValidator
            apply_bounds(scalar_only(schema, "numeric bounds"), validator)
          end
        end

        # Where a constraint on a single VALUE belongs. Clusivity walks an Array
        # value element by element, so on an array field the enum describes the
        # elements and goes in `items`; an enum on the array itself would tell
        # the model the whole list must equal one member.
        def per_value_schema(schema) = list?(schema) ? schema.fetch("items") : schema

        # `pattern` and the numeric bounds have no faithful array form:
        # ActiveModel applies both to the Array ITSELF -- matching a regexp
        # against `["a"].to_s` -- so neither `items` nor the array level would
        # mean what the local check does. Refusing beats emitting a keyword that
        # lies, and this raises while a Toolset is being assembled, long before
        # any turn could carry it.
        def scalar_only(schema, keyword)
          raise ArgumentError, "#{@name}: #{keyword} has no array form; constrain the elements instead" if list?(schema)

          schema
        end

        def list?(schema) = schema["type"] == "array"

        # A required boolean is expressed as inclusion in [true, false]; that is
        # a presence check, not a meaningful enum, so it is not emitted. The
        # values are copied because the emitted schema outlives this call and
        # must not alias -- let alone let anyone mutate -- a tool's own constant.
        def apply_enum(schema, validator)
          values = Array(validator.options[:in])
          schema["enum"] = values.dup.freeze unless values.sort_by(&:to_s) == [false, true].sort_by(&:to_s)
        end

        # LengthValidator counts an Array's ELEMENTS, so minItems/maxItems is
        # what it actually enforces there; minLength describes a string and would
        # constrain nothing.
        def apply_length(schema, validator)
          minimum, maximum = list?(schema) ? %w[minItems maxItems] : %w[minLength maxLength]
          schema[minimum] = validator.options[:minimum] if validator.options[:minimum]
          schema[maximum] = validator.options[:maximum] if validator.options[:maximum]
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

      private_constant :Element, :ArrayOf, :Property
    end
  end
end
