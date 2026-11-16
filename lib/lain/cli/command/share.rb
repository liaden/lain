# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/share`: the session's html export as a secret gist. The bytes are the model's masked
      # view, never a re-scan, so a session that released a read in clear is refused: the gist
      # would carry what the human agreed to show the model, not the world.
      class Share
        USAGE = "/share -- publish this session's masked export as a secret gist"
        FORMAT = :html

        # Only the spawn raises it, so a session file that vanished is not read as a missing gh.
        class GhMissing < StandardError
        end

        # @param exports [#call] given the chat's session file as it is NOW (promotion renames it), answers
        #   the {CLI::Export} over it
        # @param shell [Class] answers `new(*argv, input:)` and `#run_command`, {Shell::Out}'s shape
        # @param journal [#record] takes the {Telemetry::SessionShared}
        # @param account [Forge::Gh::Account, Forge::Gh::Account::None] whose token gh creates the gist with
        def initialize(exports:, journal:, shell: Shell::Out, account: Forge::Gh::Account::None.new)
          @exports = exports
          @shell = shell
          @journal = journal
          @account = account
          freeze
        end

        def name = "share"

        def usage = USAGE

        def call(args, env)
          return USAGE unless args.to_s.strip.empty?

          file = session_file(env)
          export = @exports.call(file)
          released = export.released
          return released_refusal(released) if released.positive?

          publish(export, file)
        end

        private

        def session_file(env)
          env.journal_path || raise(Lain::Error, "/share needs the session file, and this chat has none (--no-journal)")
        end

        def released_refusal(count)
          "#{regions(count)} #{count == 1 ? "was" : "were"} released to the model and sit in the transcript " \
            "in clear, so nothing was shared; `lain export` writes a local copy"
        end

        def publish(export, file)
          document = export.call(format: FORMAT)
          masked = export.masked
          shell = spawn(File.basename(file, ".*"), document)
          return "gh gist create failed: #{shell.stderr.strip}" unless Shell::Out.ok?(shell)

          url = shell.stdout.strip
          return "gh answered no gist url, so nothing was recorded" if url.empty?

          @journal.record(Telemetry::SessionShared.new(url:, format: FORMAT, masked:))
          "#{notice(file)}\n#{url} (#{regions(masked)} masked)"
        rescue GhMissing
          "gh is needed to share a session; `lain export` writes a local copy"
        end

        def notice(file) = "shared the model's masked view of #{File.basename(file)} as a secret gist"

        def spawn(base, document)
          argv = ["gh", "gist", "create", "--public=false", "--filename", "#{base}.#{FORMAT}", "-"]
          @shell.new(*argv, input: document, environment: @account.environment).run_command
        rescue Errno::ENOENT
          raise GhMissing
        end

        def regions(count) = "#{count} #{"region".pluralize(count)}"
      end
    end
  end
end
