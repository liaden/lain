# frozen_string_literal: true

require "digest"
require "fileutils"
require "rbconfig"

module Lain
  module Daemon
    Launch = Data.define(:binary, :socket, :trace, :ruby, :lain, :env, :flags, :digest)

    # Everything that decides how a daemon behaves, so a running daemon whose
    # digest differs was started by another launch and is due a restart.
    class Launch
      # Only what the daemon and its children need. A desktop session's own
      # names (XDG_SEAT, XDG_VTNR) would split a desktop lain and an ssh lain
      # into 2 digests, each restarting the other's daemon. The proxy names are here because the
      # ntfy notice goes out through the daemon, and a user behind a required proxy has no other route.
      KEEP = /\A(?:PATH|HOME|USER|LOGNAME|LANG|LC_ALL|TZ|TMPDIR|GEM_HOME|GEM_PATH|SSL_CERT_(?:FILE|DIR)|
                 (?:http|https|no)_proxy|(?:HTTP|HTTPS|NO)_PROXY|
                 XDG_(?:RUNTIME_DIR|STATE_HOME|CONFIG_HOME|CACHE_HOME|DATA_HOME))\z/x

      # The ntfy topic is as good as a password and an argv is world-readable, so it rides in the
      # environment under this name, which the daemon's `main.rs` reads by the same string. The
      # digest hashes the topic with inputs any user can read, so it rides there too.
      NTFY = "DAEMON_NTFY_TOPIC"
      DIGEST = "DAEMON_LAUNCH_DIGEST"

      # @param paths [Paths] where the socket and trace go, the XDG homes the daemon is handed, and
      #   the user's config, whose `remote relay:` the daemon runs the phone relay on
      # @param env [Hash] the caller's environment, read for cargo's target dir and the allowlist
      # @return [Launch] this checkout's release build, run by this ruby
      def self.current(paths:, env: ENV)
        remote = remote_settings(paths)
        Ractor.make_shareable(
          new(binary: File.join(Paths::Shipped.cargo_target(env:), "release", "lain-daemon"),
              socket: Daemon.socket(paths:), trace: trace_path(paths:),
              ruby: RbConfig.ruby, lain: File.join(Paths::Shipped::GEM_ROOT, "exe", "lain"),
              env: kept(env).merge(homes(paths), topic_env(remote)), flags: relay_flags(remote, paths))
        )
      end

      # @param paths [Paths]
      # @return [String] where the daemon, and the relay worker it runs, write their trace
      def self.trace_path(paths:) = File.join(paths.daemon_dir, "daemon.trace")

      # A user config that cannot be read starts a daemon with no relay; the chat reading the same
      # file is what says why.
      def self.remote_settings(paths)
        Config.remote(paths:)
      rescue Error
        {}
      end

      def self.relay_flags(remote, paths)
        remote[:relay] ? ["--relay", remote[:relay], "--devices-file", devices_file(paths)] : []
      end

      # Only a relay has items to announce, so a topic with no relay goes to nobody.
      def self.topic_env(remote)
        remote[:relay] && remote[:ntfy] ? { NTFY => remote[:ntfy] } : {}
      end

      # The relay refuses a devices file that is missing or open to others, so the first launch
      # writes the empty one a first pairing fills.
      def self.devices_file(paths)
        path = Remote::Devices.for(paths:).path
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600, &:close)
        path
      rescue Errno::EEXIST
        path
      end

      def self.kept(env) = env.to_h.select { |name, _| KEEP.match?(name) && !Exec::ChildEnv::SECRET.match?(name) }

      # The daemon resolves its own paths from these, so they must be the ones the caller's paths did.
      def self.homes(paths)
        { "XDG_RUNTIME_DIR" => paths.runtime_dir, "XDG_STATE_HOME" => paths.state_home,
          "XDG_CONFIG_HOME" => paths.config_home, "XDG_CACHE_HOME" => paths.cache_home }
          .transform_values { |dir| File.dirname(dir) }
      end
      private_class_method :kept, :homes, :relay_flags, :devices_file, :remote_settings, :topic_env

      # Content, not mtime or size, so an untouched or re-copied binary does
      # not restart the daemon. A rebuild at a new commit stamps a new sha in,
      # so it does. The allowlist, not the env: 2 shells that differ only in
      # whether TMPDIR is set would otherwise restart each other's daemon.
      # @return [String, nil] hex; nil when the binary is not built
      def self.digest_of(binary:, ruby:, lain:, flags:, topic: nil)
        return unless File.file?(binary)

        Digest::SHA256.hexdigest([Digest::SHA256.file(binary).hexdigest, ruby, lain, KEEP.source, flags, topic].inspect)
      end

      # Recomputed from the fields, so a #with never carries a stale digest; it is also put in
      # the environment, where the daemon reads it.
      def initialize(**fields)
        given = fields.except(:digest)
        digest = Launch.digest_of(**given.slice(:binary, :ruby, :lain, :flags), topic: given[:env][NTFY])
        env = digest ? given[:env].merge(DIGEST => digest) : given[:env]
        super(**given, env:, digest:)
      end

      # @return [Array<String>] the command the daemon is started with
      def argv = [binary, "--socket", socket, "--trace", trace, *flags]
    end
  end
end
