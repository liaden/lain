# frozen_string_literal: true

require "digest"
require "fileutils"
require "rbconfig"

module Lain
  module Daemon
    Launch = Data.define(:binary, :socket, :trace, :ruby, :lain, :runs, :env, :settings, :config_error, :build_digest,
                         :settings_digest)

    # Everything that decides how a daemon behaves, split in 2: a running daemon whose build digest
    # differs was started by another build or checkout and is due a restart, while one whose settings
    # digest differs keeps running, since a restart is the user's to ask for.
    class Launch
      # Only what the daemon and its children need. A desktop session's own
      # names (XDG_SEAT, XDG_VTNR) would split a desktop lain and an ssh lain
      # into 2 digests, each restarting the other's daemon. The proxy names are here because the
      # ntfy notice goes out through the daemon, and a user behind a required proxy has no other route.
      KEEP = /\A(?:PATH|HOME|USER|LOGNAME|LANG|LC_ALL|TZ|TMPDIR|GEM_HOME|GEM_PATH|SSL_CERT_(?:FILE|DIR)|
                 (?:http|https|no)_proxy|(?:HTTP|HTTPS|NO)_PROXY|
                 XDG_(?:RUNTIME_DIR|STATE_HOME|CONFIG_HOME|CACHE_HOME|DATA_HOME))\z/x

      # The daemon always polls the projects whose chats ask; this adds the user's own poll.
      POLL = { "review poll" => ["--poll-user"].freeze }.freeze

      # The ntfy topic is as good as a password and an argv is world-readable, so it rides in the
      # environment under this name, which the daemon's `main.rs` reads by the same string. The
      # settings digest hashes the topic, so both digests ride there too, under 1 name split by a space.
      NTFY = "DAEMON_NTFY_TOPIC"
      DIGEST = "DAEMON_LAUNCH_DIGEST"

      # The one secret-shaped name a run is handed: a headless chat on the anthropic provider has
      # no other way to its key. The relay worker the daemon runs clears its env, so it never has it.
      PROVIDER_KEY = "ANTHROPIC_API_KEY"

      # What a run the daemon starts needs beyond KEEP, which the daemon hands on to it whole. The
      # provider profile names are here so a run with no requester chats on the daemon's own model;
      # the digest hashes the pattern, never a value, so another shell's model restarts nothing.
      RUN_NAMES = [*CLI::PaneCommand::RUNTIME_ENV, *CLI::EnvDefaults::READ, "SHELL", "OLLAMA_HOST",
                   PROVIDER_KEY].freeze
      RUN_ENV = /\A(?:#{Regexp.union(*RUN_NAMES).source}|LC_\w+)\z/

      # @param paths [Paths] where the socket and trace go, the XDG homes the daemon is handed, and
      #   the user's config, whose `remote relay:` the daemon runs the phone relay on
      # @param env [Hash] the caller's environment, read for cargo's target dir and the allowlist
      # @return [Launch] this checkout's release build, run by this ruby
      def self.current(paths:, env: ENV)
        remote, polled, config_error = configured(paths)
        Ractor.make_shareable(
          new(binary: File.join(Paths::Shipped.cargo_target(env:), "release", "lain-daemon"),
              socket: Daemon.socket(paths:), trace: trace_path(paths:),
              ruby: RbConfig.ruby, lain: File.join(Paths::Shipped::GEM_ROOT, "exe", "lain"), runs: runs_dir(paths),
              env: kept(env).merge(run_env(env), homes(paths), topic_env(remote)),
              settings: relay_settings(remote, paths).merge(polled ? POLL : {}), config_error:)
        )
      end

      # @param paths [Paths]
      # @return [String] where the daemon, and the relay worker it runs, write their trace
      def self.trace_path(paths:) = File.join(paths.daemon_dir, "daemon.trace")

      # @param paths [Paths]
      # @return [String] where each run's log goes, as `<id>.log`
      def self.runs_dir(paths) = File.join(paths.state_home, "daemon", "runs")

      # A user config that cannot be read starts a daemon with no relay and no poll, and its error
      # rides along so the chat can say why a running daemon was kept. The review count has a
      # source only when the user's config has a github verb; the environment's account alone does not.
      def self.configured(paths)
        [Config.remote(paths:), Config.user_github?(paths:), nil]
      rescue Error => e
        [{}, false, e.message]
      end

      def self.relay_settings(remote, paths)
        return {} unless remote[:relay]

        { "relay" => ["--relay", remote[:relay]], "devices file" => ["--devices-file", devices_file(paths)] }
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

      def self.run_env(env)
        env.to_h.select do |name, _|
          RUN_ENV.match?(name) && (name == PROVIDER_KEY || !Exec::ChildEnv::SECRET.match?(name))
        end
      end

      # The daemon resolves its own paths from these, so they must be the ones the caller's paths did.
      def self.homes(paths)
        { "XDG_RUNTIME_DIR" => paths.runtime_dir, "XDG_STATE_HOME" => paths.state_home,
          "XDG_CONFIG_HOME" => paths.config_home, "XDG_CACHE_HOME" => paths.cache_home }
          .transform_values { |dir| File.dirname(dir) }
      end
      private_class_method :kept, :run_env, :homes, :relay_settings, :devices_file, :configured, :topic_env, :runs_dir

      # Content, not mtime or size, so an untouched or re-copied binary does
      # not restart the daemon. A rebuild at a new commit stamps a new sha in,
      # so it does. The allowlist, not the env: 2 shells that differ only in
      # whether TMPDIR is set would otherwise restart each other's daemon.
      # Whether the provider key is there, never its value, so a daemon started without it is
      # replaced by a launch that has it rather than keeping every later run keyless: the key is
      # part of the run env this digest already hashes the shape of.
      # @return [String, nil] hex; nil when the binary is not built
      def self.build_digest_of(binary:, ruby:, lain:, keyed: false)
        return unless File.file?(binary)

        Digest::SHA256.hexdigest([Digest::SHA256.file(binary).hexdigest, ruby, lain, KEEP.source, RUN_ENV.source,
                                  keyed].inspect)
      end

      # 1 short hash per named setting, so a chat can name which differ without the daemon ever
      # reporting a value, the topic least of all.
      # @param named [Hash{String => Object}] each setting's user-facing name and its value
      # @return [String] `name=hash` entries joined by commas
      def self.settings_digest_of(named)
        named.map { |name, value| "#{name}=#{Digest::SHA256.hexdigest([name, value].inspect)[0, 16]}" }.join(",")
      end

      # Recomputed from the fields, so a #with never carries a stale digest; both are also put in
      # the environment, where the daemon reads them.
      def initialize(config_error: nil, **fields)
        given = fields.except(:build_digest, :settings_digest)
        build_digest = Launch.build_digest_of(**given.slice(:binary, :ruby, :lain),
                                              keyed: given[:env].key?(PROVIDER_KEY))
        settings_digest = Launch.settings_digest_of(given[:settings].merge("ntfy topic" => given[:env][NTFY],
                                                                           "runs dir" => given[:runs]))
        env = build_digest ? given[:env].merge(DIGEST => "#{build_digest} #{settings_digest}") : given[:env]
        super(**given, env:, config_error:, build_digest:, settings_digest:)
      end

      # @param other [String, nil] a running daemon's settings digest; nil from a build that reports none
      # @return [Array<String>] the settings this launch would run with otherwise, by name, never a value
      def settings_differing(other)
        mine = named_digests(settings_digest)
        theirs = named_digests(other.to_s)
        (mine.keys | theirs.keys).reject { |name| mine[name] == theirs[name] }
      end

      # @return [Array<String>] the flags its settings start the daemon with
      def flags = settings.values.flatten

      # @return [Array<String>] the command the daemon is started with
      def argv = [binary, "--socket", socket, "--trace", trace, *run_flags, *flags]

      private

      # An entry with no name is one this launch cannot match, so each of its own settings reads as differing.
      def named_digests(digest) = digest.split(",").filter_map { _1.split("=", 2) if _1.include?("=") }.to_h

      def run_flags = ["--ruby", ruby, "--lain", lain, "--runs-dir", runs]
    end
  end
end
