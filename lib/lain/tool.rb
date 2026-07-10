# frozen_string_literal: true

require_relative "error"

module Lain
  # The abstract base every tool subclasses.
  #
  # A tool is a *capability*: possessing one (via a {Lain::Toolset}) is the
  # authorization to use it, so a tool carries no permission logic of its own.
  # What it carries instead is a description the model reads, a schema the input
  # is checked against, and -- optionally -- design-by-contract predicates that
  # make an invariant structurally enforceable rather than merely hoped for.
  #
  # The motivating contract is `edit_file` requiring "this file was read this
  # session": an invariant a free-form `bash` tool cannot express, but a
  # structured tool can, because it owns its own precondition. See {.requires}.
  #
  # Subclasses override {#name}, {#description}, {#input_schema}, and {#perform};
  # the public {#call} template validates input, checks preconditions, dispatches
  # to `#perform`, then checks postconditions. A tool that *fails* returns a
  # {Result} with `is_error: true` -- it does not raise as a matter of course.
  # When it does raise (a bug, a contract violation, a bad input), the executing
  # {Lain::Handler} converts that into an error {Result} so nothing propagates
  # past the loop (correctness gate 3). The two concerns are kept apart on
  # purpose: the contract mechanism stays Eiffel-honest (a violation raises),
  # while loop totality is the handler's job.
  class Tool
    class NotImplemented < Error; end
    class InvalidInput < Error; end
    class InvalidResult < Error; end
    class ContractViolation < Error; end

    # A single design-by-contract predicate paired with the message shown when it
    # is violated. Kept as data so contracts are inspectable, not just runnable.
    Contract = Data.define(:message, :predicate)

    class << self
      # Declare a precondition: something that must hold *before* the tool runs,
      # checked against `(input, context)`. This is where an invariant a tool
      # depends on but does not itself establish -- "the file was read this
      # session" -- is made enforceable. A false predicate raises
      # {ContractViolation}; the handler turns that into an error result, so the
      # model learns of the violation as a failed tool call rather than a crash.
      #
      #   requires("file was read this session") { |input, ctx| ctx.read?(input[:path]) }
      def requires(message, &predicate)
        own_preconditions << build_contract(message, predicate)
      end

      # Declare a postcondition: something that must hold *after* the tool runs,
      # checked against `(input, context, result)`. Use it to assert the tool
      # delivered what it promised (e.g. the result is non-error when the inputs
      # were valid), turning a silent wrong answer into a loud violation.
      def ensures(message, &predicate)
        own_postconditions << build_contract(message, predicate)
      end

      # Every precondition applying to this class, base-class contracts first, so
      # an inherited invariant is checked before a subclass's own. Collected
      # across the ancestry rather than stored once, so subclasses compose
      # contracts instead of overwriting them.
      def preconditions
        contracts_along_ancestry(:own_preconditions)
      end

      # Every postcondition applying to this class, base-class contracts first.
      def postconditions
        contracts_along_ancestry(:own_postconditions)
      end

      # Contracts declared directly on this class (not its ancestors).
      def own_preconditions
        @own_preconditions ||= []
      end

      # Contracts declared directly on this class (not its ancestors).
      def own_postconditions
        @own_postconditions ||= []
      end

      private

      def build_contract(message, predicate)
        raise ArgumentError, "a contract needs a predicate block" unless predicate

        Contract.new(message: message.to_s, predicate: predicate)
      end

      def contracts_along_ancestry(reader)
        ancestors
          .select { |ancestor| ancestor.is_a?(Class) && ancestor <= Tool }
          .reverse
          .flat_map { |ancestor| ancestor.public_send(reader) }
      end
    end

    # The model-facing identifier. Must be overridden; there is no sensible
    # default name for an abstract capability.
    def name
      raise NotImplemented, "#{self.class} must define #name"
    end

    # The model-facing description. This string is the single highest-leverage
    # lever on tool-call accuracy, which is the whole reason the bench exists, so
    # it is required rather than defaulted to something vacuous.
    def description
      raise NotImplemented, "#{self.class} must define #description"
    end

    # The raw JSON-schema Hash describing valid input, e.g.
    # `{ type: :object, properties: { path: { type: :string } }, required: [:path] }`.
    # Defaults to an object taking no arguments, so a nullary tool needs no
    # boilerplate. Kept as a plain Hash (no json-schema gem) and validated by a
    # small hand-rolled checker; see {#call}.
    def input_schema
      { type: :object, properties: {}, required: [] }
    end

    # Whether the provider should enforce the schema strictly. Defaults to true:
    # a loose schema is a silent source of malformed tool calls, so strictness is
    # opt-out, not opt-in.
    def strict?
      true
    end

    # Whether this tool is safe to run concurrently with others. Defaults to
    # false: nothing here executes in parallel yet (the concurrency model is
    # deliberately deferred), and opting a tool *in* to future concurrency is a
    # claim about its side effects that must be made deliberately, not inherited.
    def parallel_safe?
      false
    end

    # The public entry point: validate, check preconditions, dispatch, check
    # postconditions. Subclasses implement {#perform}, not this. Returning the
    # checked {Result} here (rather than letting `#perform` be called directly)
    # is what guarantees the contract and schema checks cannot be skipped.
    def call(input, context = nil)
      validate_input!(input)
      check_preconditions!(input, context)
      result = perform(input, context)
      unless result.is_a?(Result)
        raise InvalidResult, "#{self.class}#perform must return a Tool::Result, got #{result.class}"
      end

      check_postconditions!(input, context, result)
      result
    end

    # The provider-neutral schema for this one tool. {Lain::Toolset} sorts and
    # serializes an array of these through {Lain::Canonical} for cache stability;
    # here we only assemble the fields. Keys are stable and always present so two
    # constructions never differ by a missing optional.
    def to_schema
      {
        "name" => name,
        "description" => description,
        "input_schema" => input_schema,
        "strict" => strict?
      }
    end

    protected

    # The subclass's actual work. Receives the validated input and the runtime
    # context (read-set, channel, cwd -- whatever the caller threads through) and
    # must return a {Result}. Never call this directly; go through {#call} so the
    # checks run.
    def perform(_input, _context)
      raise NotImplemented, "#{self.class} must define #perform"
    end

    private

    def validate_input!(input)
      errors = SchemaValidator.new(input_schema).errors_for(input)
      return if errors.empty?

      raise InvalidInput, "invalid input for #{name}: #{errors.join("; ")}"
    end

    def check_preconditions!(input, context)
      self.class.preconditions.each do |contract|
        next if instance_exec(input, context, &contract.predicate)

        raise ContractViolation, "precondition failed for #{name}: #{contract.message}"
      end
    end

    def check_postconditions!(input, context, result)
      self.class.postconditions.each do |contract|
        next if instance_exec(input, context, result, &contract.predicate)

        raise ContractViolation, "postcondition failed for #{name}: #{contract.message}"
      end
    end
  end

  class Tool
    # The value a tool call resolves to: content plus an explicit error flag.
    #
    # There is deliberately NO error inference. A tool that failed says so by
    # returning `is_error: true`; success and failure are never guessed from the
    # shape of `content`. `content` is either a String or an Array of provider
    # content blocks, matching what a `tool_result` block accepts on the wire.
    # Defined in a reopened `Tool` to keep the behavioral core measurably small.
    Result = Data.define(:content, :is_error) do
      # A successful result carrying `content`.
      def self.ok(content)
        new(content: content, is_error: false)
      end

      # A failed result carrying an error message or blocks. This is what a
      # raising or contract-violating tool is turned into, and what a tool that
      # detects its own failure should return directly.
      def self.error(content)
        new(content: content, is_error: true)
      end

      def initialize(content:, is_error: false)
        unless content.is_a?(String) || content.is_a?(Array)
          raise InvalidResult, "Tool::Result content must be a String or an Array, got #{content.class}"
        end

        # Coerce to a strict Boolean so `is_error` is never a truthy-but-not-true
        # value that a `== true` check downstream would miss.
        super(content: content, is_error: is_error ? true : false)
      end

      def error?
        is_error
      end

      def ok?
        !is_error
      end
    end

    # A deliberately small type/required validator for raw JSON-schema Hashes.
    #
    # It exists so the loop never dispatches a tool on structurally wrong input
    # (a missing required key, a string where a number belongs) and so those
    # failures surface as a clear {InvalidInput} rather than a `NoMethodError`
    # deep inside `#perform`. It is NOT a full JSON-schema implementation on
    # purpose -- adding a json-schema gem would be a dependency to serve a
    # validator this loop does not need. It checks `type` and `required`,
    # recursing into object properties and array items, and is lenient about
    # extra keys (the provider's own strict-schema enforcement covers those).
    #
    # Defined in a reopened `Tool` so the validator's size is measured on its own
    # rather than inflating the main class it logically belongs to.
    class SchemaValidator
      # Maps a JSON-schema type name to a predicate over Ruby values. `integer`
      # is stricter than `number`; `boolean` and `null` are spelled out because
      # Ruby has no single class for either.
      TYPE_CHECKS = {
        "object" => ->(value) { value.is_a?(Hash) },
        "array" => ->(value) { value.is_a?(Array) },
        "string" => ->(value) { value.is_a?(String) },
        "integer" => ->(value) { value.is_a?(Integer) },
        "number" => ->(value) { value.is_a?(Numeric) },
        "boolean" => ->(value) { [true, false].include?(value) },
        "null" => lambda(&:nil?)
      }.freeze

      # The JSON-schema name for a Ruby value's type, for readable error messages.
      RUBY_TYPE_NAMES = {
        Hash => "object", Array => "array", String => "string",
        Integer => "integer", Float => "number", NilClass => "null"
      }.freeze

      def initialize(schema)
        @schema = schema || {}
      end

      # @return [Array<String>] one message per problem; empty means valid.
      def errors_for(value)
        errors = []
        validate(@schema, value, "input", errors)
        errors
      end

      private

      def validate(schema, value, path, errors)
        type = lookup(schema, :type)
        if type && !type_ok?(type, value)
          errors << "#{path} must be #{Array(type).join(" or ")}, got #{ruby_type(value)}"
          return # once the type is wrong, deeper checks would only add noise.
        end

        case scalar_type(type)
        when "object" then validate_object(schema, value, path, errors)
        when "array" then validate_array(schema, value, path, errors)
        end
      end

      def validate_object(schema, value, path, errors)
        return unless value.is_a?(Hash)

        Array(lookup(schema, :required)).each do |key|
          errors << "#{path}.#{key} is required" unless key?(value, key)
        end

        (lookup(schema, :properties) || {}).each do |name, subschema|
          next unless key?(value, name)

          validate(subschema, dig(value, name), "#{path}.#{name}", errors)
        end
      end

      def validate_array(schema, value, path, errors)
        return unless value.is_a?(Array)

        items = lookup(schema, :items)
        return unless items

        value.each_with_index { |element, i| validate(items, element, "#{path}[#{i}]", errors) }
      end

      # A schema `type` may be a single name or an array of alternatives.
      def type_ok?(type, value)
        Array(type).any? { |name| (TYPE_CHECKS[name.to_s] || ->(_) { true }).call(value) }
      end

      def scalar_type(type)
        type.is_a?(Array) ? nil : type&.to_s
      end

      # Schema keys and model-supplied input keys are each freely Symbol or
      # String (Anthropic parses tool input with `symbolize_names: true`), so
      # every lookup tries both spellings rather than assuming one.
      def lookup(schema, key)
        return nil unless schema.is_a?(Hash)

        schema.fetch(key) { schema[key.to_s] }
      end

      def key?(hash, key)
        hash.key?(key) || hash.key?(key.to_s) || hash.key?(key.to_sym)
      end

      def dig(hash, key)
        return hash[key] if hash.key?(key)
        return hash[key.to_s] if hash.key?(key.to_s)

        hash[key.to_sym]
      end

      def ruby_type(value)
        return "boolean" if [true, false].include?(value)

        RUBY_TYPE_NAMES.fetch(value.class, value.class.name)
      end
    end
  end
end
