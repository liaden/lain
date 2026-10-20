# frozen_string_literal: true

module Lain
  OutputCeiling = Data.define(:tokens, :source) do
    # @param model [String] the model the ceiling is for
    # @param window [ContextWindow::WindowResolution] that model's window
    # @param typed [Integer, nil] a validated `--max-tokens`, which wins
    # @return [OutputCeiling]
    def self.for(model:, window:, typed: nil)
      return OutputCeiling.typed(typed) unless typed.nil?

      table = OutputCeiling.table_tokens(model)
      return new(tokens: table, source: :table) if table
      return new(tokens: window.window_tokens, source: :served_window) if window.provenance == ContextWindow::PROBED

      new(tokens: OutputCeiling::FALLBACK_TOKENS, source: :fallback)
    end

    # @param tokens [Integer] a ceiling the operator typed
    # @return [OutputCeiling]
    def self.typed(tokens) = new(tokens: Integer(tokens), source: :typed)

    # @param tokens [Integer] the ceiling a command declares for itself, nobody typed
    # @return [OutputCeiling]
    def self.command_default(tokens) = new(tokens: Integer(tokens), source: :command_default)

    # @param tokens [Integer] a ceiling nobody resolved, which records no source
    # @return [OutputCeiling]
    def self.fixed(tokens) = new(tokens: Integer(tokens), source: nil)

    # The slot duck {Context} reads: a resolved ceiling is the same for every model.
    #
    # @return [OutputCeiling] self
    def ceiling_for(_model) = self

    # @return [Hash{String=>String}] the source for a session header; empty when unrecorded
    def to_header = source.nil? ? {} : { "max_tokens_source" => source.to_s }
  end

  # The most a reply may cost, sent as `max_tokens`. It is a wire ceiling, not
  # the room a reply is planned for ({ReplyReserve} is that), and both wires
  # enforce the window apart from it, so a generous value breaks nothing on a
  # current model.
  #
  # Source is one of `:typed`, `:command_default`, `:table`, `:served_window`
  # and `:fallback`, or nil for a bare number nobody resolved. A guessed window
  # never sets it: clamping to an 8,192 guess would cut replies on a runner
  # serving far more.
  #
  # @!attribute [r] tokens
  #   @return [Integer]
  # @!attribute [r] source
  #   @return [Symbol, nil]
  class OutputCeiling
    # Anthropic's published output maximums, matched like {ContextWindow}'s
    # table: an exact key, else the longest key the name contains.
    #
    # The models before 4.5 refuse a request whose input plus `max_tokens`
    # passes the window, so their own larger maximum would 400 a long chat;
    # they keep the 16,384 they always had, or their own maximum when that is
    # lower. Their ids get rows because the bare tier words would give them
    # the current generation's maximum.
    TABLE = {
      "opus" => 128_000,
      "sonnet" => 64_000,
      "haiku" => 64_000,
      "claude-opus-4-5" => 64_000,
      "claude-sonnet-4-5" => 64_000,
      "claude-opus-4-1" => 16_384,
      "claude-opus-4-0" => 16_384,
      "claude-opus-4-20250514" => 16_384,
      "claude-sonnet-4-0" => 16_384,
      "claude-sonnet-4-20250514" => 16_384,
      "claude-3-7-sonnet" => 16_384,
      "claude-3-5-sonnet" => 8_192,
      "claude-3-5-haiku" => 8_192
    }.freeze

    KEYS = ModelTable.new(TABLE.keys)
    private_constant :KEYS

    # For a model the table does not carry and no server measured: an ollama
    # cloud model, a local one whose window was only guessed, or a first-party
    # id the table has no row for yet.
    FALLBACK_TOKENS = 32_768

    # @param model [String]
    # @return [Integer, nil]
    def self.table_tokens(model)
      key = KEYS.key_for(model.to_s)
      key && TABLE.fetch(key)
    end

    # An untyped ceiling, resolved for whichever model a {Context} renders, so
    # a `/model` switch moves it.
    class PerModel
      # @param window [#call] model name to {ContextWindow::WindowResolution}
      def initialize(window:)
        @window = window
        freeze
      end

      # @param model [String]
      # @return [OutputCeiling]
      def ceiling_for(model) = OutputCeiling.for(model:, window: @window.call(model))
    end
  end
end
