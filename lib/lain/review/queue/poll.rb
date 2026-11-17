# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Lain
  module Review
    class Queue
      # One poll of the review requests asked of me: it rewrites the counts file the HUDs read, marks
      # the herdr `reviews` workspace, and notices each new direct request once. It asks GitHub one
      # question and never reads a pull request's keywords or paths.
      class Poll
        SOURCE = "lain-queue"
        TITLE = "review requested"
        UNREACHABLE = [Forge::Gh::Reads::Refused, Forge::Gh::Account::Refused, Shell::Out::Timeout,
                       SystemCallError].freeze
        COUNT = /\Arv \d+(?:\+\d+)?\z/
        private_constant :SOURCE, :TITLE, :UNREACHABLE, :COUNT

        # The segment every HUD appends to its line. The file is any same-uid process's to write, so
        # only a count is let through: nothing else can reach a status bar as an escape or a tmux format.
        #
        # @param paths [Paths]
        # @return [String] empty when there is no counts file or it holds anything but a count
        def self.hud(paths:)
          counts = JSON.parse(File.read(paths.review_counts))
          line = counts.is_a?(Hash) ? counts["hud"] : nil
          COUNT.match?(line.to_s) ? "#{line}#{"?" if counts["stale"] == true}" : ""
        rescue SystemCallError, JSON::ParserError, Paths::NonAbsoluteHome
          ""
        end

        # @param reads [Forge::Gh::Reads]
        # @param log [Log] says when the queue was last listed and which requests were noticed
        # @param counts [String] the counts file's path
        # @param workspaces [Herdr::Workspaces]
        # @param feed [#call] takes source, title and body ({Notices::Feed}, {Notices::Null})
        # @param orgs [Array<String>] organizations to count; empty counts every one
        # @param clock [#call]
        def initialize(reads:, log:, counts:, workspaces:, feed:, orgs: [], clock: -> { Time.now })
          @reads = reads
          @log = log
          @counts = counts
          @workspaces = workspaces
          @feed = feed
          @orgs = orgs
          @clock = clock
        end

        # @return [void]
        def call
          FileUtils.mkdir_p(File.dirname(@counts))
          FileLock.new("#{@counts}.lock").try { poll }
          nil
        end

        private

        def poll
          @log.prune
          pulls = requested or return mark_stale
          fresh = fresh_direct(pulls)
          write(summary(pulls, fresh.size))
          @workspaces.token(label: "reviews", name: "reviews", value: token(pulls.size, fresh.size))
          fresh.each { |pull| notice(pull) }
        end

        # @return [Array<Forge::Gh::ReviewRequest>, nil] nil when GitHub could not be asked
        def requested
          @reads.review_requests(query: PullRequests::REQUESTS).select { |pull| PullRequests.in_orgs?(pull, @orgs) }
        rescue *UNREACHABLE
          nil
        end

        def fresh_direct(pulls)
          since = @log.last_listed_at
          pulls.select { |pull| pull.via == :direct && (since.nil? || pull.requested_at.to_i > since.to_i) }
        end

        def summary(pulls, fresh)
          direct = pulls.count { _1.via == :direct }
          { total: pulls.size, direct:, team: pulls.size - direct, new_direct: fresh,
            polled_at: @clock.call.utc.iso8601, hud: "rv #{pulls.size}#{"+#{fresh}" if fresh.positive?}", stale: false }
        end

        def token(total, fresh) = fresh.positive? ? "#{total} (#{fresh} new)" : total.to_s

        # The title goes in the body, which the feed reads from stdin, and only after it is made printable.
        def notice(pull)
          id = PullRequests.id_for(pull)
          return if @log.notified?(id)

          sent = @feed.call(SOURCE, TITLE, "#{id} #{Request.plain(pull.title)}")
          @log.append(Log::Event.new(kind: :notified, at: nil, row_id: id, head_sha: pull.head_sha)) if sent
        end

        def mark_stale
          last = previous
          write(last.merge("stale" => true)) if last
        end

        def previous
          JSON.parse(File.read(@counts))
        rescue SystemCallError, JSON::ParserError
          nil
        end

        # A rename, so a HUD reading mid-poll sees a whole file.
        def write(fields)
          scratch = "#{@counts}.#{Process.pid}"
          File.write(scratch, JSON.generate(fields))
          File.rename(scratch, @counts)
        ensure
          FileUtils.rm_f(scratch)
        end
      end
    end
  end
end
