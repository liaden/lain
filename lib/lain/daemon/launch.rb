# frozen_string_literal: true

require "digest"
require "rbconfig"

module Lain
  module Daemon
    Launch = Data.define(:binary, :socket, :trace, :ruby, :lain, :env, :flags, :digest)

    # Everything that decides how a daemon behaves, so a running daemon whose
    # digest differs was started by another launch and is due a restart.
    class Launch
      # Only what the daemon and its children need. A desktop session's own
      # names (XDG_SEAT, XDG_VTNR) would split a desktop lain and an ssh lain
      # into 2 digests, each restarting the other's daemon.
      KEEP = /\A(?:PATH|HOME|USER|LOGNAME|LANG|LC_ALL|TZ|TMPDIR|GEM_HOME|GEM_PATH|SSL_CERT_(?:FILE|DIR)|
                 XDG_(?:RUNTIME_DIR|STATE_HOME|CONFIG_HOME|CACHE_HOME|DATA_HOME))\z/x

      # @param paths [Paths] where the socket and trace go, and the XDG homes the daemon is handed
      # @param env [Hash] the caller's environment, read for cargo's target dir and the allowlist
      # @return [Launch] this checkout's release build, run by this ruby
      def self.current(paths:, env: ENV)
        Ractor.make_shareable(
          new(binary: File.join(Paths::Shipped.cargo_target(env:), "release", "lain-daemon"),
              socket: Daemon.socket(paths:), trace: File.join(paths.daemon_dir, "daemon.trace"),
              ruby: RbConfig.ruby, lain: File.join(Paths::Shipped::GEM_ROOT, "exe", "lain"),
              env: kept(env).merge(homes(paths)), flags: [])
        )
      end

      def self.kept(env) = env.to_h.select { |name, _| KEEP.match?(name) && !Exec::ChildEnv::SECRET.match?(name) }

      # The daemon resolves its own paths from these, so they must be the ones the caller's paths did.
      def self.homes(paths)
        { "XDG_RUNTIME_DIR" => paths.runtime_dir, "XDG_STATE_HOME" => paths.state_home,
          "XDG_CONFIG_HOME" => paths.config_home, "XDG_CACHE_HOME" => paths.cache_home }
          .transform_values { |dir| File.dirname(dir) }
      end
      private_class_method :kept, :homes

      # Content, not mtime or size, so an untouched or re-copied binary does
      # not restart the daemon. A rebuild at a new commit stamps a new sha in,
      # so it does. The allowlist, not the env: 2 shells that differ only in
      # whether TMPDIR is set would otherwise restart each other's daemon.
      # @return [String, nil] hex; nil when the binary is not built
      def self.digest_of(binary:, ruby:, lain:, flags:)
        return unless File.file?(binary)

        Digest::SHA256.hexdigest([Digest::SHA256.file(binary).hexdigest, ruby, lain, KEEP.source, flags].inspect)
      end

      # Recomputed from the fields, so a #with never carries a stale digest.
      def initialize(**fields)
        given = fields.except(:digest)
        super(**given, digest: Launch.digest_of(**given.slice(:binary, :ruby, :lain, :flags)))
      end

      # @return [Array<String>] the command the daemon is started with
      def argv = [binary, "--socket", socket, "--trace", trace, "--launch-digest", digest, *flags]
    end
  end
end
