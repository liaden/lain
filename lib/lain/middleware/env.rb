# frozen_string_literal: true

module Lain
  module Middleware
    # The environment threaded through a {Stack}, as a read-only whole value
    # rather than a bare Hash passed hand to hand.
    #
    # Same wrap/`to_h` philosophy as {Lain::Context::MessageEnvelope}: {Stack#call} wraps
    # its input ONCE at the boundary, so every caller keeps passing plain hashes
    # and every hash-duck middleware (fetch/[]/merge) keeps working unchanged.
    # `merge` is functional -- it returns a NEW Env, never mutating in place --
    # which is safe precisely because no middleware in the tree mutates env by
    # `env[k] = v` (they all merge); the value carries that discipline in its type.
    #
    # == Per-phase key contract (pinned by the phase specs)
    #
    # Each phase's Stack agrees on which keys are present going in and coming out;
    # the reader sugar below names the ones that pay:
    #
    #   model phase (ModelCaller):  :request in  -> :response out
    #   tool  phase (ToolRunner):   :effect, :context in -> :result out
    #   turn  phase (Agent#run):    :iteration, :timeline in -> :response, :settled out
    #   repl  phase (exe/lain):     :text, :agent in -> :response out
    #
    # A reader for an absent key raises KeyError (it is {#fetch}), so a phase that
    # forgets to populate its out-key fails loudly rather than reading a silent nil.
    class Env
      # Idempotent: an Env passes through untouched (so a Stack nested inside a
      # Stack does not double-wrap), a Hash is adopted as the backing store.
      def self.wrap(env) = env.is_a?(self) ? env : new(env)

      def initialize(hash)
        @hash = hash
        freeze
      end

      def fetch(...) = @hash.fetch(...)

      def [](key) = @hash[key]

      # A NEW Env over the merged entries. Accepts a Hash or another Env.
      def merge(other) = self.class.new(@hash.merge(other.is_a?(self.class) ? other.to_h : other))

      def to_h = @hash

      def request = fetch(:request)
      def response = fetch(:response)
      def effect = fetch(:effect)
      def result = fetch(:result)
    end
  end
end
