# frozen_string_literal: true

require "delegate"
require "json"
require "securerandom"

module Lain
  module Review
    class Queue
      # A review held for a checkout where no chat runs, until the next cockpit
      # there offers it. Any same-uid process can write the file, so it is read
      # as a request on the wire is: through {Request.load}, never as a line.
      class Pending
        COCKPIT = "lain up --nvim"
        STALE = 86_400
        LIMIT = 65_536
        FIELD_LIMIT = 80
        DROPPED = "lain queue: a held review was dropped: %<reason>s"
        UNREAD = "lain queue: a held review could not be read: %<reason>s"
        UNKEPT = "lain queue: a review could not be held again: %<reason>s"
        # The chat needs only the line, so a pull request's clone is not looked up.
        NO_CHECKOUTS = Checkouts.new(roots: [])
        private_constant :STALE, :LIMIT, :FIELD_LIMIT, :DROPPED, :UNREAD, :UNKEPT, :NO_CHECKOUTS

        # @param paths [Paths]
        # @param env [Hash{String=>String}] read for HERDR_ENV
        # @param workspaces [#create] starts a cockpit inside herdr
        # @param clock [#call] now, for the age of a held file
        def initialize(paths:, env: ENV, workspaces: Herdr::Workspaces.new(env:), clock: -> { Time.now })
          @paths = paths
          @env = env
          @workspaces = workspaces
          @clock = clock
        end

        # Inside herdr a workspace is started only when none for the checkout is
        # open, since a cockpit there takes whatever file is held.
        #
        # @param request [Request] one with a local checkout
        # @return [Symbol] `:pending`, `:started`, or `:herdr_failed` (inside herdr, with no workspace
        #   started); each prefixed `replaced_` over a review a chat would still take, and `:pending` then
        #   reads `:replaced`
        # @raise [Lain::Error] in 1 line when the review cannot be written
        def hold(request)
          root = request.repo_root
          replaced = held?(root)
          File.rename(written(request), path_for(root))
          outcome = herdr_outcome(root)
          return outcome unless replaced

          outcome == :pending ? :replaced : :"replaced_#{outcome}"
        rescue SystemCallError => e
          raise Error, "lain cannot hold the review in #{directory}: #{e.message}"
        end

        # Claimed by a rename before it is read, so 2 chats starting at once
        # cannot both offer it, and removed whatever it was.
        #
        # @param root [String] the chat's project root
        # @param notice [#call] told once why a held file was dropped
        # @return [Request, nil]
        def take(root, notice:)
          claimed = claim(path_for(root)) or return
          loaded(claimed, root)
        rescue Request::Refused => e
          notice.call(format(DROPPED, reason: Utf8.escaped(cut(e))))
          nil
        rescue SystemCallError => e
          notice.call(format(UNREAD, reason: Utf8.escaped(e.message)))
          nil
        ensure
          removed(claimed) if claimed
        end

        # @param producer [#start] the chat's input producer
        # @param root [String] the chat's project root
        # @param rail [Frontend::Intake]
        # @param notice [#call]
        # @return [Offering] the producer, offering the review held for `root` once the chat first asks
        def offering(producer, root:, rail:, notice:) = Offering.new(producer, pending: self, root:, rail:, notice:)

        # The chat's input producer, which also offers the held review at the
        # chat's first `you>`: by then the input socket is bound and the editor
        # attached. A review taken but not answered when the chat stops is held
        # again, unless a newer one was held meanwhile.
        class Offering < SimpleDelegator
          # A `you>` is drawn only once the frontend is up, and the Intake says
          # nothing to a reader that is not a producer.
          POLL = 0.05
          SETTLE = 0.1

          # @param producer [#start]
          # @param pending [Pending]
          # @param root [String]
          # @param rail [Frontend::Intake]
          # @param notice [#call]
          def initialize(producer, pending:, root:, rail:, notice:)
            super(producer)
            @pending = pending
            @root = root
            @rail = rail
            @notice = notice
          end

          # @param task [Async::Task, nil]
          # @return [self]
          def start(task)
            @started = __getobj__.start(task)
            @thread = Thread.new { offer }
            self
          end

          # The thread is given a moment before it is killed, so an answer
          # already typed reaches it and is not taken for no answer at all.
          #
          # @return [void]
          def stop(**)
            @started&.stop(**)
            @stopped = true
            @thread&.join(SETTLE)
            @thread&.kill&.join
            @pending.keep(@request, notice: @notice) if @request
          end

          private

          # A kill lands only inside the offer itself, so a review is never taken
          # without being remembered, nor still remembered once the offer returned.
          def offer
            first_you
            Thread.handle_interrupt(Object => :never) do
              @request = @pending.take(@root, notice: @notice) unless @stopped
              Thread.handle_interrupt(Object => :immediate) { offered(@request) } if @request
              @request = nil
            end
          end

          # A crowded offer is never shown, and the take already removed its file.
          def offered(request)
            @rail.offer(request) { |outcome| @pending.keep(request, notice: @notice) if outcome == :crowded }
          rescue Request::Refused => e
            @notice.call(format(DROPPED, reason: Utf8.escaped(e.message)))
          end

          def first_you
            sleep(POLL) until @rail.published.kind == :you
          end
        end

        # Held only where nothing newer is.
        #
        # @param request [Request]
        # @param notice [#call] told why, when the review could not be written
        # @return [void]
        def keep(request, notice:)
          scratch = written(request)
          File.link(scratch, path_for(request.repo_root))
        rescue Errno::EEXIST
          nil
        rescue SystemCallError => e
          notice.call(format(UNKEPT, reason: Utf8.escaped(e.message)))
        ensure
          FileUtils.rm_f(scratch) if scratch
        end

        private

        def label(root) = "review #{File.basename(root)}"

        # Asked through the same checks {#take} makes, so a stale or planted file is no review to replace.
        def held?(root)
          loaded(path_for(root), root)
          true
        rescue Request::Refused, SystemCallError
          false
        end

        # A planted directory may deny its owner the search bit it needs emptied.
        def removed(claimed)
          File.chmod(0o700, claimed) if File.lstat(claimed).directory?
          FileUtils.rm_rf(claimed)
        rescue SystemCallError
          nil
        end

        def directory = File.join(@paths.state_home, "queue", "pending")

        def path_for(root) = File.join(directory, "#{@paths.project_hash(root)}.json")

        def written(request)
          FileUtils.mkdir_p(directory)
          scratch = "#{path_for(request.repo_root)}.#{SecureRandom.hex(4)}.tmp"
          File.open(scratch, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |io| io.write(JSON.generate(request.to_h)) }
          scratch
        end

        def herdr_outcome(root)
          return :pending unless @env["HERDR_ENV"] == "1" && !@workspaces.include?(label(root))

          @workspaces.create(cwd: root, command: COCKPIT, label: label(root)).nil? ? :herdr_failed : :started
        end

        def claim(path)
          claimed = "#{path}.#{SecureRandom.hex(4)}.taken"
          File.rename(path, claimed)
          claimed
        rescue Errno::ENOENT
          nil
        end

        # A planted field can be any length; its name is cut to what a note can show.
        def cut(refused)
          field = refused.field.to_s
          return refused.message if field.size <= FIELD_LIMIT

          refused.message.sub("refused: #{field}", "refused: #{field[0, FIELD_LIMIT]}...")
        end

        def loaded(claimed, root)
          checked(File.lstat(claimed))
          request = Request.load(parsed(claimed), checkouts: NO_CHECKOUTS)
          held_at = request.to_h["repo_root"]
          raise Request::Refused.new("repo_root", "is not this checkout") if held_at && held_at != root

          request
        end

        def checked(stat)
          raise Request::Refused.new("file", "is not a regular file") unless stat.file?
          raise Request::Refused.new("file", "has a mode others may use") if stat.mode.anybits?(0o077)
          raise Request::Refused.new("file", "is over #{LIMIT} bytes") if stat.size > LIMIT

          age = @clock.call - stat.mtime
          raise Request::Refused.new("file", "was held over 1 day ago, or dated ahead") unless age.between?(0, STALE)
        end

        # NONBLOCK, so a file swapped for a FIFO after the check cannot hang the chat's start.
        def parsed(claimed)
          text = File.open(claimed, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) { |io| io.read(LIMIT + 1) }.to_s
          raise Request::Refused.new("file", "is over #{LIMIT} bytes") if text.bytesize > LIMIT

          JSON.parse(text)
        rescue JSON::ParserError
          raise Request::Refused.new("file", "is not JSON")
        rescue SystemCallError
          raise Request::Refused.new("file", "could not be read")
        end
      end
    end
  end
end
