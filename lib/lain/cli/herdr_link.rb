# frozen_string_literal: true

require "thor"

module Lain
  module CLI
    # `lain herdr link|unlink|status`: the only place lain writes to herdr's
    # configuration, by asking herdr itself to link the plugin folder this
    # checkout ships. Named HerdrLink so it cannot shadow {Lain::Herdr}.
    class HerdrLink < Thor
      namespace "herdr"

      PLUGIN_ID = "lain"
      PLUGIN_ROOT = File.join(Paths::Shipped::GEM_ROOT, "plugin", "herdr")

      def self.exit_on_failure? = true

      desc "link", "Link lain's herdr plugin into herdr"
      def link
        herdr("plugin", "link", PLUGIN_ROOT)
        say "linked #{PLUGIN_ROOT}"
      end

      desc "unlink", "Remove lain's herdr plugin from herdr"
      def unlink
        herdr("plugin", "unlink", PLUGIN_ID)
        say "unlinked #{PLUGIN_ID}"
      end

      desc "status", "Show herdr's plugin list"
      def status = say(herdr("plugin", "list"))

      private

      def herdr(*argv)
        raise Thor::Error, "herdr was not found on PATH" unless Shell::Path.find("herdr", path: ENV.fetch("PATH", ""))

        out = Shell::Out.new("herdr", *argv).run_command
        raise Thor::Error, "herdr #{argv.join(" ")} failed: #{out.stderr.strip}" unless Shell::Out.ok?(out)

        out.stdout
      end
    end
  end
end
