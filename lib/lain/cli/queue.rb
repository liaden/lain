# frozen_string_literal: true

require "json"
require "thor"

module Lain
  module CLI
    # `lain queue here|local|prs|show`: what a reviewer should look at next, one
    # line per row. Rows carry text from outside (a plan's title, a pull
    # request's title, a branch name), so {Entry} is the one place a row becomes
    # a line and it takes that text apart first.
    class Queue < ::Thor
      include Exe::Boundary

      namespace "queue"

      # A row as text: every field safe to print, whichever source wrote it.
      class Entry
        # @param row [::Lain::Review::Queue::Row]
        # @param pull [Forge::Gh::ReviewRequest, nil] what GitHub said of a pull request row
        def initialize(row, pull)
          @row = row
          @pull = pull
        end

        # @return [String] `<id>\t<reason>\t<summary>`
        def line = [id, reason, summary].join("\t")

        # @return [Hash] the row as 1 JSON object's members
        def to_h
          { id:, rank: @row.rank.to_s, reason:, summary:, head_sha: @row.head_sha, request: @row.request.to_h }
        end

        # @return [Array<String>] the lines `show` prints
        def detail
          ["id: #{id}", "reason: #{reason}", "range: #{range}", *pull_detail]
        end

        private

        def id = ::Lain::Review::Queue::Request.plain(@row.id)

        def reason = ::Lain::Review::Queue::Request.plain(@row.reason)

        def summary
          fields = @row.request.to_h
          ::Lain::Review::Queue::Request.plain(fields["kind"] == "pr" ? @pull&.title || fields["url"] : span)
        end

        def span
          fields = @row.request.to_h
          case fields["kind"]
          when "range" then "#{fields["base"][0, 8]}..#{fields["head"][0, 8]}"
          when "branch" then [fields["branch"], fields["base"]].compact.join(" against ")
          else fields["repo_root"]
          end
        end

        def range
          fields = @row.request.to_h
          case fields["kind"]
          when "range" then "#{fields["base"]}..#{fields["head"]}"
          when "pr" then ::Lain::Review::Queue::Request.plain([fields["url"],
                                                               *(if fields["since"]
                                                                   "since #{fields["since"]}"
                                                                 end)].join(" "))
          else span
          end
        end

        def pull_detail
          return [] unless @pull

          ["title: #{::Lain::Review::Queue::Request.plain(@pull.title)}", "author: #{::Lain::Review::Queue::Request.plain(@pull.author)}",
           "requested: #{@pull.requested_at&.utc&.iso8601 || "unknown"}"]
        end
      end

      private_constant :Entry

      # Keeps each pull request the reads returned, so a row's title, author and
      # request time are known without a second GraphQL call.
      class Pulls
        # @param reads [Forge::Gh::Reads]
        def initialize(reads)
          @reads = reads
          @seen = {}
          @requests = {}
        end

        # @param query [String]
        # @return [Array<Forge::Gh::ReviewRequest>]
        def review_requests(query:) = @requests[query] ||= remember(@reads.review_requests(query:))

        # @param query [String]
        # @param notes [#puts]
        # @return [Array<Forge::Gh::ReviewRequest>]
        def matches(query:, notes: Sink::Null.new) = remember(@reads.matches(query:, notes:))

        # @param row_id [String]
        # @return [Forge::Gh::ReviewRequest, nil]
        def for(row_id) = @seen[row_id]

        private

        def remember(pulls)
          pulls.each { |pull| @seen[::Lain::Review::Queue::PullRequests.id_for(pull)] = pull }
        end
      end
      private_constant :Pulls

      # Where a source's note goes: stderr, so a row stream stays rows.
      Notes = Struct.new(:cli) do
        def puts(text) = cli.say_error(::Lain::Review::Queue::Request.plain(text))
      end
      private_constant :Notes

      # Where the picker's rows go when there is no fzf: stdout, through Thor.
      Printer = Struct.new(:cli) do
        def puts(text) = cli.say(text, nil, false)
      end
      private_constant :Printer

      # A project's poll leaves the herdr `reviews` token to the user's.
      class NoToken
        def token(**) = nil
      end
      private_constant :NoToken

      EXE = File.expand_path("../../../exe/lain", __dir__)
      PICKABLE = %w[here local prs].freeze
      TURNED_AWAY = { crowded: "the chat is showing another offer; try again when it is answered",
                      repeat: "already offered" }.freeze
      HELD = {
        pending: "no lain cockpit is running in %<root>s; the review opens with the next lain up --nvim there",
        started: "no lain cockpit is running in %<root>s; started lain up --nvim there in a herdr workspace",
        herdr_failed: "no lain cockpit is running in %<root>s; herdr did not start a workspace, so the review opens " \
                      "with the next lain up --nvim there",
        replaced: "replaced the review held for %<root>s; it opens with the next lain up --nvim there",
        replaced_started: "replaced the review held for %<root>s; started lain up --nvim there in a herdr workspace",
        replaced_herdr_failed: "replaced the review held for %<root>s; herdr did not start a workspace, so it opens " \
                               "with the next lain up --nvim there"
      }.freeze
      private_constant :EXE, :PICKABLE, :TURNED_AWAY, :HELD

      def self.exit_on_failure? = true

      desc "here", "Plan runs, then the local changes of this checkout"
      method_option :json, type: :boolean, default: false, desc: "One JSON object per row"
      def here = list { here_sources }

      desc "local", "Unmerged branches, a dirty tree and recent commits of this checkout"
      method_option :json, type: :boolean, default: false, desc: "One JSON object per row"
      def local = list { local_sources }

      desc "prs", "Pull requests that want my review"
      method_option :json, type: :boolean, default: false, desc: "One JSON object per row"
      method_option :all, type: :boolean, default: false, desc: "Also requests asked of my teams or as code owner"
      method_option :matches, type: :boolean, default: false, desc: "Also pull requests a keyword or path picks out"
      def prs = list(listed: true) { prs_sources }

      desc "show ID", "Why a row is queued, its range, and for a pull request who asked and when"
      def show(id) = render(newline: false) { lines(entry(row_for(id)).detail) }

      desc "open ID", "Offer a row's review to the chat running in its checkout"
      method_option :critique, type: :string, desc: "Run a critique focused on this text once the review opens"
      def open(id)
        render(newline: false) do
          row = row_for(id)
          said(delivery.call(row, critiqued(row, options[:critique])), row, options[:critique])
        end
      end

      desc "poll", "Count the review requests asked of me, for the HUDs; meant for a timer"
      method_option :root, type: :string, desc: "Poll this project's own github settings instead of the user's"
      def poll
        paths = Paths.new
        root = options[:root]
        config = root ? project_github(root, paths) : Config.github(root: nil, paths:)
        config && poll_with(config, paths, root)
      end

      desc "pick [here|local|prs]", "Choose a row in fzf and open it; Alt-Enter opens it with a critique"
      def pick(source = "here")
        unless PICKABLE.include?(source)
          raise ::Thor::Error,
                "no queue source #{::Lain::Review::Queue::Request.plain(source)}"
        end

        render(newline: false) do
          shown = rows(sources_for(source), listed: source == "prs")
          picker = Picker.new(rows: shown, source:, lain: [Gem.ruby, EXE], out: Printer.new(self),
                              opener: method(:open_row))
          exit 130 if picker.call == :cancelled
          ""
        rescue Picker::NoFzf => e
          raise ::Thor::Error, e.message
        end
      end

      no_commands do
        def list(listed: false) = render(newline: false) { rows(yield, listed: listed && !options[:json]) }
      end

      private

      def project_github(root, paths)
        return skipped("#{root} sets no github, so it is not polled") unless Config.project_github?(root:, paths:)

        Config.github(root:, paths:)
      rescue Project::Trust::Untrusted
        skipped("#{root} is untrusted, so it is not polled; run lain trust there")
      end

      def skipped(note)
        notes.puts(note)
        nil
      end

      def poll_with(config, paths, root)
        account = Forge::Gh::Account.for(config, shell_out_factory: Shell::Out.public_method(:new), notes:)
        ::Lain::Review::Queue::Poll.new(
          reads: Forge::Gh::Reads.new(cwd: root || Dir.pwd, account:), log: ::Lain::Review::Queue::Log.new(paths:),
          counts: paths.review_counts(root), workspaces: root ? NoToken.new : Herdr::Workspaces.new,
          feed: Notices.for(env: ENV, notes:), orgs: config.orgs
        ).call
      end

      def rows(sources, listed: false)
        log = ::Lain::Review::Queue::Log.new(paths: Paths.new)
        queue = ::Lain::Review::Queue.new(sources:, log:)
        lines(queue.map { |row| options[:json] ? JSON.generate(entry(row).to_h) : entry(row).line })
          .tap { listed(log) if listed }
      end

      def listed(log)
        log.append(::Lain::Review::Queue::Log::Event.new(kind: :listed, at: nil, row_id: nil, head_sha: nil))
      end

      def sources_for(source)
        case source
        when "here" then here_sources
        when "local" then local_sources
        when "prs" then prs_sources
        else raise ArgumentError, "no queue source #{source.inspect}"
        end
      end

      def open_row(id, critique:) = invoke(:open, [id], critique:)

      def row_for(id)
        row = id.start_with?("pr:") ? pull_row(id) : find_row([plan_runs, local_changes], id)
        row || raise(::Thor::Error, "no queue row #{::Lain::Review::Queue::Request.plain(id)}")
      end

      # A listed row may be one only the wider read finds.
      def pull_row(id)
        find_row([pull_requests(scope: :mine, matches: false)], id) ||
          find_row([pull_requests(scope: :all, matches: true)], id)
      end

      def find_row(sources, id)
        sources.flat_map(&:call).find do |candidate|
          ::Lain::Review::Queue::Request.plain(candidate.id) == ::Lain::Review::Queue::Request.plain(id)
        end
      end

      def critiqued(row, critique)
        return row.request unless critique

        fields = row.request.to_h
        raise ::Thor::Error, "a critique focus goes only with a pull request row" unless fields["kind"] == "pr"

        focus = ::Lain::Review::Queue::Request.focus(critique)
        raise ::Thor::Error, "the critique focus has no printable ASCII in it" unless focus

        ::Lain::Review::Queue::Request.load(fields.merge("focus" => focus), checkouts: pull_checkouts)
      end

      def said(result, row, critique)
        case result.outcome
        when :held then lines(["offered #{::Lain::Review::Queue::Request.plain(row.id)} to #{session(result.chat)}",
                               *also(result)])
        when *HELD.keys then lines([held(result, row), *also(result)])
        when :browsed
          lines(["no local checkout of #{::Lain::Review::Queue::Request.plain(row.id)}; opened it in the browser" \
                 "#{", so --critique was not used" if critique}"])
        else raise ::Thor::Error, [refusal(result), *also(result)].join("\n")
        end
      end

      def refusal(result)
        case result.outcome
        when :refused then refused(result.field)
        when :silent then "the chat #{session(result.chat)} has not answered the offer, and may still show it"
        else TURNED_AWAY.fetch(result.outcome)
        end
      end

      def refused(field)
        return "the chat could not offer the review; it says why on its screen" if field.nil?

        "the chat refused the request's #{::Lain::Review::Queue::Request.plain(field)}"
      end

      def held(result, row) = format(HELD.fetch(result.outcome), root: row.request.repo_root)

      def also(result)
        [*("also running there: #{result.others.map { session(_1) }.join(", ")}" if result.others.any?)]
      end

      # A listed session's fields are whatever its chat registered.
      def session(record) = ::Lain::Review::Queue::Request.plain(record.session_id)

      def delivery
        ::Lain::Review::Queue::Delivery.new(
          notes:,
          account: Forge::Gh::Account.for(github_config, shell_out_factory: Shell::Out.public_method(:new), notes:),
          pending: ::Lain::Review::Queue::Pending.new(paths: Paths.new)
        )
      end

      def lines(texts) = texts.map { |text| "#{text}\n" }.join

      def entry(row) = Entry.new(row, row.request.to_h["kind"] == "pr" ? pulls.for(row.id) : nil)

      def notes = @notes ||= Notes.new(self)

      def checkout = Isolation::Checkout.of(Dir.pwd)

      def here_sources = [plan_runs, local_changes]

      def local_sources = [local_changes]

      def prs_sources = [pull_requests(scope: options[:all] ? :all : :mine, matches: options[:matches])]

      def plan_runs = ::Lain::Review::Queue::PlanRuns.new(checkout:, notes:)

      def local_changes = ::Lain::Review::Queue::LocalChanges.new(repo_root: Dir.pwd, notes:)

      def pull_requests(scope:, matches:)
        ::Lain::Review::Queue::PullRequests.new(reads: pulls, config: github_config, checkouts: pull_checkouts, scope:,
                                                matches:, notes:)
      end

      def pulls
        @pulls ||= begin
          account = Forge::Gh::Account.for(github_config, shell_out_factory: Shell::Out.public_method(:new), notes:)
          Pulls.new(Forge::Gh::Reads.new(cwd: Dir.pwd, account:))
        end
      end

      def pull_checkouts = @pull_checkouts ||= ::Lain::Review::Queue::Checkouts.new(roots: github_config.roots, notes:)

      def github_config
        @github_config ||= Config.github(root: Project::Resolver.default_project.root, paths: Paths.new)
      end
    end
  end
end
