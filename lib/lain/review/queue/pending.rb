# frozen_string_literal: true

require "delegate"
require "json"
require "securerandom"

module Lain
  module Review
    class Queue
      # A review held for a checkout where no chat runs, until the next cockpit
      # there offers it. Any same-uid process can write the file, so it is read
      # as an offer on the wire is: the request through {Request.load}, never
      # as a line, and the row beside it through {Mark.load}.
      class Pending
        # What a held file holds: the review, and the row it marks seen once taken.
        Held = Data.define(:request, :mark) do
          def to_h = { "request" => request.to_h, "row" => mark.to_h }
        end

        COCKPIT = "lain up --nvim"
        STALE = 86_400
        LIMIT = 65_536
        FIELD_LIMIT = 80
        DROPPED = "lain queue: a held review was dropped: %<reason>s"
        UNREAD = "lain queue: a held review could not be read: %<reason>s"
        UNKEPT = "lain queue: a review could not be held again: %<reason>s"
        FILE_FIELDS = %w[request row].freeze
        # The chat needs only the line, so a pull request's clone is not looked up.
        NO_CHECKOUTS = Checkouts.new(roots: [])
        private_constant :STALE, :LIMIT, :FIELD_LIMIT, :DROPPED, :UNREAD, :UNKEPT, :FILE_FIELDS, :NO_CHECKOUTS

        # @param paths [Paths]
        # @param env [Hash{String=>String}] read for HERDR_ENV
        # @param workspaces [#create] starts a cockpit inside herdr
        # @param clock [#call] now, for the age of a held file
        # @param log [Log] where a held review the human takes marks its row seen
        def initialize(paths:, env: ENV, workspaces: Herdr::Workspaces.new(env:), clock: -> { Time.now },
                       log: Log.new(paths:))
          @paths = paths
          @env = env
          @workspaces = workspaces
          @clock = clock
          @log = log
        end

        # Inside herdr a workspace is started only when none for the checkout is
        # open, since a cockpit there takes whatever file is held.
        #
        # @param request [Request] one with a local checkout
        # @param mark [Mark] the row it marks seen once the human takes it
        # @return [Symbol] `:pending`, `:started`, or `:herdr_failed` (inside herdr, with no workspace
        #   started); each prefixed `replaced_` over a review a chat would still take, and `:pending` then
        #   reads `:replaced`
        # @raise [Lain::Error] in 1 line when the review cannot be written
        def hold(request, mark)
          root = request.repo_root
          replaced = held?(root)
          File.rename(written(Held.new(request:, mark:)), path_for(root))
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
        # @return [Held, nil]
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
        def offering(producer, root:, rail:, notice:)
          Offering.new(producer, pending: self, log: @log, root:, rail:, notice:)
        end

        # The chat's input producer, which also offers the held review at the
        # chat's first `you>`: by then the input socket is bound and the editor
        # attached. The human's Enter marks its row seen and `x` or Ctrl-D drops
        # it; one never answered, or never shown, is held again unless a newer
        # one was held meanwhile.
        class Offering < SimpleDelegator
          # A `you>` is drawn only once the frontend is up, and the Intake says
          # nothing to a reader that is not a producer.
          POLL = 0.05

          # @param producer [#start]
          # @param pending [Pending]
          # @param log [Log] where a taken review marks its row seen
          # @param root [String]
          # @param rail [Frontend::Intake]
          # @param notice [#call]
          def initialize(producer, pending:, log:, root:, rail:, notice:)
            super(producer)
            @pending = pending
            @log = log
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

          # The offer is ended through the rail rather than by killing its
          # thread, so an answer already typed is still the answer.
          #
          # @return [void]
          def stop(**)
            @started&.stop(**)
            @stopped = true
            @rail.end_offer
            abandon unless @thread.nil? || @thread.join(Frontend::Intake::OFFERS_END)
          end

          private

          # Only an offer whose line is still being built outlives the bound,
          # since an ended offer leaves at once; it was never shown, so it is held.
          def abandon
            @thread.kill.join
            @pending.keep(@held, notice: @notice) if @held
          end

          # A kill lands only inside the offer itself, so a review is never taken
          # without being remembered, nor still remembered once it was settled.
          def offer
            sleep(POLL) until @stopped || @rail.published.kind == :you
            Thread.handle_interrupt(Object => :never) do
              @held = @pending.take(@root, notice: @notice) unless @stopped
              answered(@held) if @held
              @held = nil
            end
          end

          # A turned-away offer is never shown, and the take already removed its file.
          def answered(held)
            turned = nil
            answer = Thread.handle_interrupt(Object => :immediate) do
              @rail.offer(held.request) { |outcome| turned = outcome }
            end
            case answer
            when :taken then held.mark.seen(@log, notice: @notice)
            when nil then @pending.keep(held, notice: @notice) unless turned == :repeat
            end
          rescue Request::Refused => e
            @notice.call(format(DROPPED, reason: Utf8.escaped(e.message)))
          end
        end

        # Held only where nothing newer is.
        #
        # @param held [Held]
        # @param notice [#call] told why, when the review could not be written
        # @return [void]
        def keep(held, notice:)
          scratch = written(held)
          File.link(scratch, path_for(held.request.repo_root))
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

        def written(held)
          FileUtils.mkdir_p(directory)
          scratch = "#{path_for(held.request.repo_root)}.#{SecureRandom.hex(4)}.tmp"
          File.open(scratch, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |io| io.write(JSON.generate(held.to_h)) }
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
          file = fields(parsed(claimed))
          mark = Mark.load(file["row"])
          request = Request.load(file["request"], checkouts: NO_CHECKOUTS)
          held_at = request.to_h["repo_root"]
          raise Request::Refused.new("repo_root", "is not this checkout") if held_at && held_at != root

          Held.new(request:, mark:)
        end

        def fields(file)
          raise Request::Refused.new("file", "is not a map") unless file.is_a?(Hash)
          return file if (file.keys - FILE_FIELDS).empty?

          raise Request::Refused.new("file", "has a field other than #{FILE_FIELDS.join(" and ")}")
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
