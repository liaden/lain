# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "tmpdir"

module Lain
  module Bench
    # Times the paths every chat turn, bash call and model call pays for, so a change that touches one
    # can be held to a ceiling. `bin/hot-path-bench` is the only caller; it records the rows and checks
    # them, the way `bin/runtime-census` guards the suite's wall.
    #
    # Each row is a median over its repetitions with the interquartile range as its spread: a run on a
    # shared box has outliers, and a range that ate them would make every row look too noisy to budget.
    class HotPaths
      Row = Data.define(:name, :median_ms, :spread_ms, :reps, :skipped)

      CHAT_BODY = ("lorem ipsum dolor sit amet " * 14).freeze
      SAMPLE_OUTPUT = "build ok\nAPI_TOKEN=sk-ant-api03-#{"a1B2c3D4" * 8}\ndone\n".freeze

      # @param turns [Integer] how long the rendered conversation is
      # @param reps [Integer] repetitions of a cheap row; the render cold row runs a tenth of them, at least 5
      # @param sizes [Array<Integer>] request body sizes in bytes; the largest also sizes the journal line
      # @param clock [#call] returns monotonic seconds
      # @param probe [Confine::Probe, nil] what the box offers the sandbox; nil asks this box
      # @param bash [#call] `call(probe:, scratch:)`, building what the bash rows run through
      def initialize(turns: 10_000, reps: 50, sizes: [100_000, 1_000_000], clock: RunClock::MONOTONIC,
                     probe: nil, bash: ->(**options) { Bash.new(**options) })
        @turns = turns
        @reps = reps
        @sizes = sizes
        @clock = clock
        @probe = probe
        @bash = bash
      end

      # @return [Array<Row>] one per measured row, in the table's order
      def rows
        [*render_rows, *bash_rows, *request_rows, *journal_rows, mask_row, wire_row]
      end

      # @param reps [Integer]
      # @param name [String, nil]
      # @return [Row]
      def measure(reps, name: nil)
        samples = Array.new(reps) do
          started = @clock.call
          yield
          (@clock.call - started) * 1000.0
        end
        Row.new(name:, median_ms: Stats.quantile(samples, 0.5), spread_ms: Stats.iqr(samples), reps:, skipped: nil)
      end

      private

      def skipped(name, reason) = Row.new(name:, median_ms: nil, spread_ms: nil, reps: 0, skipped: reason)

      def label = (@turns % 1000).zero? ? "#{@turns / 1000}k" : @turns.to_s

      def render_rows
        render = Corpus.render(turns: @turns)
        [measure(@reps, name: "render_chat_#{label}") { render.chat },
         measure([@reps / 10, 5].max.clamp(..@reps), name: "render_cold_#{label}") { render.cold }]
      end

      def bash_rows
        Dir.mktmpdir("hot-path-workspace") do |scratch|
          git_init(scratch)
          bash = @bash.call(probe: @probe || Corpus.probe, scratch: File.realpath(scratch))
          %w[none traced reader workspace].map do |profile|
            reason = bash.unavailable(profile)
            if reason
              skipped("bash_true_#{profile}", reason)
            else
              call = bash.caller_for(profile)
              measure(@reps, name: "bash_true_#{profile}") { call.call }
            end
          end
        end
      end

      # The workspace row's root is a repository, so its call pays the git seals a chat's call in one pays.
      def git_init(dir)
        _, status = Open3.capture2e(Isolation::Worktree::GIT_CONTEXT_SCRUB, "git", "init", "-q", dir)
        raise Error, "git init failed in #{dir}" unless status.success?
      end

      def request_rows
        Loopback.serving do |url|
          connection = Provider::HTTP::Connection.new(Loopback::Endpoint.new(url, true, {}),
                                                      Provider::HTTP::Configuration.new)
          @sizes.map do |size|
            body = "x" * size
            measure(@reps, name: "request_#{size}") { connection.post("/api/chat", Corpus.payload(body)) }
          end
        end
      end

      def journal_rows
        Dir.mktmpdir("hot-path-journal") do |dir|
          Journal.open(File.join(dir, "bench.ndjson")) do |journal|
            line = { "type" => "request_sent", "body" => "x" * @sizes.max }
            [measure(@reps, name: "journal_small") { journal.record({ "type" => "turn", "n" => 1 }) },
             measure(@reps, name: "journal_#{@sizes.max}") { journal.record(line) }]
          end
        end
      end

      def mask_row
        measure(@reps, name: "mask_first_output") do
          secrets = Sensitivity::Secrets.for(child_env: Exec::ChildEnv::DEFAULT, context: nil)
          Sensitivity::TextMask.new(secrets:).call(SAMPLE_OUTPUT)
        end
      end

      def wire_row
        Dir.mktmpdir("hot-path-wiring") do |dir|
          measure(@reps, name: "wire_ready") { Corpus.wire_agent(dir) }
        end
      end

      # Median and interquartile range, by linear interpolation between ranks.
      module Stats
        module_function

        def quantile(samples, fraction)
          sorted = samples.sort
          at = (sorted.size - 1) * fraction
          low = sorted[at.floor]
          low + ((sorted[at.ceil] - low) * (at - at.floor))
        end

        def iqr(samples) = quantile(samples, 0.75) - quantile(samples, 0.25)
      end

      # What each row measures over, built the way production builds it. The digest of the cold
      # request is pinned in the spec, so a card that changes the render cannot change what a
      # render row measures without a failing example saying so.
      module Corpus
        Prefixed = Data.define(:timeline, :advance) { def messages = advance.call(timeline).messages }
        Render = Struct.new(:timeline, :context, :toolset, :prefix, :turns_added) do
          def chat
            self.turns_added += 1
            role = turns_added.even? ? :user : :assistant
            self.timeline = timeline.commit(role:, content: Corpus.text("c#{turns_added}"))
            advance = ->(tl) { self.prefix = prefix.over(tl) }
            context.render(timeline: Prefixed.new(timeline:, advance:), toolset:)
          end

          def cold = context.render(timeline:, toolset:)
        end

        module_function

        def text(label) = [{ "type" => "text", "text" => "#{label} #{CHAT_BODY}" }]

        def render(turns:)
          store = Dag::Factory.store
          timeline = Dag::Factory.timeline(store:)
          turns.times { |i| timeline = timeline.commit(role: i.even? ? :user : :assistant, content: text(i)) }
          Render.new(timeline, Context.new(model: "bench", max_tokens: 64), Toolset.new([]),
                     Agent::RenderedPrefix.none, 0).tap(&:chat)
        end

        def cold_request(turns:) = render(turns:).cold

        def payload(body)
          request = Lain::Request.new(model: "bench", max_tokens: 64, stream: false,
                                      messages: [{ role: "user", content: body }])
          Canonical.dump(model: request.model, messages: request.messages, stream: false)
        end

        def probe = Confine::Probe.new(fence: Confine::Bwrap.fence_binary, journal: Channel::Null.instance)

        def wire_agent(dir)
          project = Project.new(root: dir, cwd: dir, kind: :project, detected_by: :flag)
          wiring = ::Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle: ::Lain::CLI::Chronicle::Null.new, project:,
                                           status_feed: StatusFeed.new(path: File.join(dir, "status.json")),
                                           paths: Paths.new(env: { "HOME" => dir }))
          recorder, session = wiring.run_state(nil)
          wiring.wire_agent(channel: Channel.new, recorder:, session:, backend: offline_backend(dir))
        end

        # The real Backend with only the network edge swapped for a mock.
        def offline_backend(dir)
          mock = Provider::Mock.new(responses: [])
          Class.new(::Lain::CLI::Backend) { define_method(:provider) { |**| mock } }
               .new({ provider: "ollama", max_tokens: 64 }, root: dir)
        end
      end

      # Runs `true` through {Exec::Sandboxed} under each profile the box can give.
      class Bash
        STALE_FENCE = "stale lain-fence: run bundle exec rake compile"
        ALLOWED = Approval::Escalation::Ruling.allow(rung: "rules", because: "bench",
                                                     rule: Approval::ComposedTerm.rule_name)
        JUDGED = Approval::Escalation::Ruling.allow(rung: Approval::Judged::NAME, because: "bench")
        NoMasks = Struct.new(:nothing) do
          def masks = []
          def landed_on(_path) = []
        end
        NoTrace = Struct.new(:nothing) { def supports?(_layer) = false }

        # @param probe [#supports?, #fence_gap]
        # @param scratch [String] absolute; the repository the workspace row may write, so its writable
        #   profile never covers the checkout
        # @param journal [#<<] where each call's sandbox record lands
        def initialize(probe:, scratch:, journal: Channel::Null.instance)
          @probe = probe
          @scratch = scratch
          @journal = journal
        end

        # Every profile runs under the fence, and a missing or stale one exits 127 or 125 at once,
        # which would read as a fast row.
        #
        # @return [String, nil] why this box cannot run the profile, nil when it can
        def unavailable(profile)
          gap = case profile
                when "traced" then ("no strace" unless @probe.supports?(:trace))
                when "reader", "workspace" then reader_gap
                end
          gap || fence_gap
        end

        # @return [#call] one `true` through the profile
        def caller_for(profile)
          sandboxed = Exec::Sandboxed.new(inner: Exec::Local.new, launcher: Confine::Bwrap.new(fence: Confine::Bwrap.fence_binary),
                                          profiles: profiles(profile), journal: @journal)
          request = request_for(profile)
          cwd = root_for(profile)
          -> { sandboxed.call(command: "true", cwd:, env: {}, timeout: 10, confinement: request) }
        end

        private

        def reader_gap
          missing = %i[bwrap landlock].reject { @probe.supports?(_1) }
          "no #{missing.join(" and no ")}" if missing.any?
        end

        def fence_gap
          fence = Confine::Bwrap.fence_binary
          return "no lain-fence at #{fence}: run bundle exec rake compile" unless File.executable?(fence)

          STALE_FENCE if fence_stale?(fence)
        end

        def profiles(profile)
          probe = profile == "none" ? NoTrace.new : @probe
          Confine::Profiles.new(masks: NoMasks.new, probe:, home: Dir.home, root: root_for(profile),
                                workspace: profile == "workspace")
        end

        def root_for(profile) = profile == "workspace" ? @scratch : Dir.pwd

        def profile_for(profile) = profiles(profile).for(request_for(profile))

        def request_for(profile)
          ruling = { "reader" => ALLOWED, "workspace" => JUDGED }[profile]
          return Confine::Request::NONE unless ruling

          root = root_for(profile)
          Confine::Request.new(ruling:, executables: [], cwd: root, root:, tool_use_id: "bench")
        end

        def fence_stale?(fence)
          built = File.mtime(fence)
          sources = Dir.glob(File.join(Paths::Shipped::GEM_ROOT, "crates/lain-fence/{src/**/*.rs,Cargo.toml}"))
          sources.any? { File.mtime(_1) > built }
        end
      end
      private_constant :Bash

      # A loopback HTTP server that reads one request and answers an empty chat completion.
      class Loopback
        REPLY = JSON.generate("model" => "bench", "message" => { "role" => "assistant", "content" => "ok" },
                              "done" => true, "done_reason" => "stop").freeze

        Endpoint = Struct.new(:api_base, :configured?, :headers) { def parse_error(_response) = nil }

        # @yieldparam url [String] the server's base URL
        def self.serving
          server = TCPServer.new("127.0.0.1", 0)
          acceptor = Thread.new { loop { Thread.new(server.accept) { |socket| answer(socket) } } }
          yield "http://127.0.0.1:#{server.addr[1]}"
        ensure
          acceptor&.kill
          server&.close
        end

        def self.answer(socket)
          length = 0
          while (line = socket.gets) && line != "\r\n"
            length = line.split(":").last.to_i if line.downcase.start_with?("content-length:")
          end
          socket.read(length)
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{REPLY.bytesize}\r\n" \
                       "Connection: close\r\n\r\n#{REPLY}")
        ensure
          socket.close
        end
      end
      private_constant :Loopback

      # Merges the same rows measured under different environment paddings, which move memory layout:
      # the median of the medians is the row, and how far they range is the layout noise, the figure a
      # gap between two trees has to beat before it is a finding.
      module Sweep
        module_function

        # @param runs [Array<Array<Row>>] one row list per padding
        # @return [Array<Row>]
        def merge(runs)
          runs.flatten.group_by(&:name).map { |name, rows| merged(name, rows) }
        end

        def merged(name, rows)
          gap = rows.find(&:skipped)
          return gap if gap

          medians = rows.map(&:median_ms)
          Row.new(name:, median_ms: Stats.quantile(medians, 0.5), spread_ms: medians.max - medians.min,
                  reps: rows.sum(&:reps), skipped: nil)
        end
      end

      # One recorded run: the rows and the conditions they were taken under.
      Log = Data.define(:rows, :sha, :loadavg, :workers) do
        def self.parse(text)
          data = JSON.parse(text)
          new(rows: data.fetch("rows").map { |row| Row.new(**row.transform_keys(&:to_sym)) },
              sha: data.fetch("sha"), loadavg: data.fetch("loadavg"), workers: data.fetch("workers"))
        end

        def dump
          JSON.pretty_generate("sha" => sha, "loadavg" => loadavg, "workers" => workers, "rows" => rows.map(&:to_h))
        end
      end

      # The last few logs, newest last, in one directory.
      class Records
        KEEP = 3

        # @param dir [String]
        def initialize(dir:)
          @dir = dir
        end

        # @param text [String]
        def write(text)
          FileUtils.mkdir_p(@dir)
          File.write(File.join(@dir, "#{Time.now.strftime("%Y%m%d-%H%M%S-%6N")}.json"), text)
          Array(files[0...-KEEP]).each { File.delete(_1) }
        end

        # @return [Array<String>]
        def texts = files.map { File.read(_1) }

        private

        def files = Dir.glob(File.join(@dir, "*.json"))
      end

      # Holds recorded logs to their ceilings: a row passes when it is at or under its ceiling in at
      # least 2 of 3 logs, and fails when it is over in 2 of 3. A skipped row is not measured, so it
      # never counts as a pass.
      class Check
        NEEDED = 3

        # @param ceilings [Hash{String => Numeric, nil}] milliseconds; nil is a row not yet seeded
        def initialize(ceilings)
          @ceilings = ceilings
        end

        # @param logs [Array<Array<Row>>] the rows of each recorded log
        # @return [Array<String>] one line per failure
        def failures(logs)
          return ["need #{NEEDED} recorded logs, found #{logs.size}"] unless logs.size == NEEDED

          @ceilings.flat_map do |name, ceiling|
            found = logs.map { |rows| rows.find { |row| row.name == name } }
            ceiling ? row_failures(name, ceiling, found) : ["#{name} has no ceiling; seed it from 3 quiet-box logs"]
          end
        end

        private

        def row_failures(name, ceiling, rows)
          measured = rows.compact.reject(&:skipped).map(&:median_ms)
          over = measured.count { |median| median > ceiling }
          return [] if measured.size - over >= 2

          ["#{name} #{verdict(ceiling, over, measured.size - over)} of #{NEEDED} logs (medians #{shown(rows)} ms)"]
        end

        def verdict(ceiling, over, under)
          return "is over its #{ceiling.to_f} ms ceiling in #{over}" if over >= 2

          "is under its #{ceiling.to_f} ms ceiling in only #{under}"
        end

        def shown(rows) = rows.map { |row| row ? cell(row) : "missing" }.join(", ")

        def cell(row) = row.skipped ? "skipped: #{row.skipped}" : row.median_ms.to_s
      end
    end
  end
end
