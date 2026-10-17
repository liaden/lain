# frozen_string_literal: true

module Lain
  class Config
    # The `middleware` table: what a user or project config asks to run in each
    # phase. A registration is a recipe rather than an instance, because two
    # agents sharing one middleware would share its state; only `http` is built
    # once, by Faraday, and so only it can be asked to be thread-safe rather
    # than fresh.
    class Middleware
      AREAS = %i[model tool turn repl http].freeze
      TABLE = "`middleware`"

      # The `Data.define` block holds methods only: constants declared there
      # would belong to the enclosing module.
      Registration = Data.define(:factory, :args, :kwargs, :block, :at) do
        # @return [Object] a new middleware; a block becomes {Lain::Middleware::Inline}
        # @raise [Refusal] at `at`, when the constructor rejects its arguments
        def build
          block ? Lain::Middleware::Inline.new(block) : factory.new(*args, **kwargs)
        rescue ArgumentError => e
          raise Refusal.new(e.message, path: at, table: TABLE)
        end
      end

      # The refusals a registration can earn at load.
      module Check
        def self.call(area, call, at)
          refuse("has no area #{area.inspect}; known areas: #{AREAS.join(", ")}", at, area) unless AREAS.include?(area)
          if call.block
            refuse("http takes a Faraday middleware class, not a block", at, area) if area == :http
          else
            klass(area, call.args.first, at)
          end
        end

        def self.klass(area, klass, at)
          refuse("a middleware is a Class, not a Module: #{klass.inspect}", at, area) if klass.instance_of?(Module)
          refuse("a middleware is a Class or a block, got #{klass.inspect}", at, area) unless klass.is_a?(Class)
          missing = missing_methods(area, klass)
          refuse("#{describe(klass)} has no instance #{missing.join(" or ")}", at, area) unless missing.empty?
        end

        def self.missing_methods(area, klass)
          wanted = area == :http ? [] : %i[call]
          wanted += %i[settle] if area == :turn
          wanted.reject { |name| klass.method_defined?(name) }.map { |name| "##{name}" }
        end

        def self.describe(klass) = klass.name || "an anonymous class"

        def self.refuse(detail, at, area) = raise(Refusal.new(detail, path: at, table: TABLE, key: area.to_s))
      end
      private_constant :Check

      # @return [Middleware] a value that builds nothing
      def self.empty = new

      # @param calls [Array<#verb, #args, #kwargs, #block, #line>] one per registration, verb = area
      # @param path [String] the config file, to name in a refusal
      # @return [Middleware]
      # @raise [Refusal] naming `path:line` for anything that cannot be a middleware
      def self.from(calls, path:)
        by_area = calls.group_by(&:verb).to_h do |area, group|
          [area, group.map { |call| registration(area, call, "#{path}:#{call.line}") }.freeze]
        end
        new(**by_area)
      end

      def self.registration(area, call, at)
        Check.call(area, call, at)
        Registration.new(factory: call.args.first, args: shareable(call.args.drop(1), area, at),
                         kwargs: shareable(call.kwargs, area, at), block: call.block, at:)
      end
      private_class_method :registration

      # A copy, so a constant the caller still owns is never frozen under it.
      def self.shareable(value, area, at)
        Ractor.make_shareable(value, copy: true)
      rescue Ractor::Error, TypeError => e
        raise Refusal.new("cannot be shared across agents: #{e.message}", path: at, table: TABLE, key: area.to_s)
      end
      private_class_method :shareable

      # @param by_area [Hash{Symbol => Array<Registration>}]
      def initialize(**by_area)
        @by_area = AREAS.to_h { |area| [area, by_area.fetch(area, []).dup.freeze] }.freeze
      end

      # @return [Middleware] this one's registrations first, per area
      def +(other) = self.class.new(**AREAS.to_h { |area| [area, registrations(area) + other.registrations(area)] })

      # @param area [Symbol] model, tool, turn or repl
      # @return [Array] fresh instances, in written order
      def members(area) = registrations(area).map(&:build)

      # @return [Array<Array>] `[klass, *args, kwargs]` for `faraday.use`
      def http_entries = registrations(:http).map { |reg| [reg.factory, *reg.args, reg.kwargs].freeze }.freeze

      protected

      def registrations(area) = @by_area.fetch(area)
    end
  end
end
