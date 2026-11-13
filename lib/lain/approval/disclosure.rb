# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Lain
  module Approval
    Disclosure = Data.define(:holdings, :sinks, :unnameable, :unscanned)

    # What a bash call would reach before it runs: how many sensitive regions
    # each file it reads holds, where it would send, whether lain could name
    # its files at all, and which reads it did not scan whole. Built by
    # {Middleware::ParsedCommand} at most once per call, so the parked row and
    # the judge read the same facts and no file is read twice.
    #
    # The sinks are advisory, a list of known senders' argv shapes; nothing
    # that contains a call may rest on them.
    #
    # @!attribute [r] holdings
    #   @return [Hash{String => Integer}] each file the call reads, as the row
    #     names it (relative to the session's directory when below it), and its
    #     count, at most {Scanner::CEILING}
    # @!attribute [r] sinks
    #   @return [Array<String>] each network destination the call names
    # @!attribute [r] unnameable
    #   @return [Boolean] whether lain could not name the files the call touches
    # @!attribute [r] unscanned
    #   @return [Array<String>] each read lain did not scan whole, named as in holdings: a glob, a
    #     directory or search root, a file past the cap, or one it could not open as a regular file
    class Disclosure
      HOLDS = "%<path>s holds %<count>s sensitive %<noun>s"
      SENDS = "it names %<sinks>s as %<noun>s"
      UNNAMEABLE = "lain cannot name the files it touches"
      UNSCANNED = "reads files lain did not scan whole: %<paths>s"
      HERE = "."
      RECURSIVE = "/**"

      # Counts the sensitive regions in one file's leading bytes, the lockfile
      # rule applied by the file's name as the classifier reads it.
      class Scanner
        CAP = 256 * 1024
        CEILING = 100
        # Lines are fed in pieces this size, so counting can stop at the ceiling.
        PIECE = 16 * 1024
        # Non-blocking, so a FIFO swapped in after the path was named cannot hold the open.
        OPEN_FLAGS = File::RDONLY | File::NONBLOCK

        # @!attribute [r] regions
        #   @return [Integer, nil] nil when nothing was read
        # @!attribute [r] whole
        #   @return [Boolean] whether every byte was scanned
        Count = Data.define(:regions, :whole)
        UNREAD = Count.new(regions: nil, whole: false)

        # A replay's file facts record where files are, never what they hold, so
        # over them nothing is opened and no region is counted.
        #
        # @param policy [#file_facts, #checksums?] the session's path policy
        # @return [Scanner, Unscanned]
        def self.over(policy) = policy.file_facts.equal?(FileFacts::LIVE) ? new(policy) : Unscanned

        # @param classifier [#checksums?] whether a path is a lockfile of checksums
        def initialize(classifier)
          @classifier = classifier
          freeze
        end

        # The descriptor is asked what it is, not the path, so a file swapped
        # between naming and opening is judged as what was opened.
        #
        # @param path [String] absolute
        # @return [Count, nil] nil for a path that names nothing a read could reach
        def call(path)
          File.open(path, OPEN_FLAGS) { |file| counted(path, file) }
        rescue Errno::ENOENT, Errno::ENOTDIR, ArgumentError, EncodingError
          nil
        rescue SystemCallError, IOError
          UNREAD
        end

        private

        def counted(path, file)
          stat = file.stat
          return if stat.chardev?
          return UNREAD unless stat.file?

          bytes = file.read(CAP + 1).to_s
          Count.new(regions: regions(path, bytes.byteslice(0, CAP)), whole: bytes.bytesize <= CAP)
        end

        def regions(path, text)
          checksums = @classifier.checksums?(path, within: File.dirname(path))
          total = 0
          pieces(text).find { |piece| (total += found(piece, checksums)) >= CEILING }
          [total, CEILING].min
        end

        def found(piece, checksums) = Middleware::RedactSecretReads::Scan.new(piece, checksums:).regions.length

        # Whole lines, so no region is cut unless one line outgrows a piece.
        def pieces(text)
          size = 0
          text.each_line.slice_before { |line| (size += line.bytesize) > PIECE && (size = line.bytesize) }
              .lazy.map(&:join)
        end
      end

      # The network destinations a stage's known sender names: a curl or wget
      # URL, the nc, ncat, netcat or socat host, an ssh, scp, rsync or sftp
      # remote, a git push, fetch or pull remote, and a `/dev/tcp` or `/dev/udp`
      # path. A URL is named by its host alone, so a credential in it is never shown.
      module Sinks
        URL = %r{\A[a-z][a-z0-9+.-]*://(?:[^@/?#]*@)?(\[[^\]]*\]|[^/:?#@]+)}i
        DEV = %r{\A/dev/(?:tcp|udp)/([^/]+)/}
        SOCKET = /\A(?:tcp|udp|openssl|ssl|sctp)[46]?:([^:,]+)/i
        REMOTE = %r{\A(?:[^@/:]+@)?([^/:@]+):}
        USER = /\A.*@/
        ASSIGNMENT = /\A\w+=/
        DEFAULT_REMOTE = "the default remote"
        URLS = %w[curl wget].freeze
        NC = %w[nc ncat netcat].freeze
        SSH = %w[ssh sftp].freeze
        COPIES = %w[scp rsync].freeze
        FETCHES = %w[push fetch pull].freeze
        NC_VALUED = %w[-p -s -w -i -q -x -X -e -c -I -O -T -V -g -G -P -W].freeze
        SSH_VALUED = %w[-p -i -l -o -F -J -L -R -D -b -c -E -e -I -m -O -Q -S -W -w -B].freeze
        GIT_VALUED = %w[-C -c --git-dir --work-tree --namespace].freeze

        # @param stages [Array<Shell::Parse::Stage>]
        # @return [Array<String>] each destination once, in the order named
        def self.of(stages) = stages.flat_map { from(_1) }.uniq

        def self.from(stage)
          words = stage.argv.map { unquoted(_1) }.drop_while { _1.match?(ASSIGNMENT) }
          targets = stage.redirects.filter_map { _1.target && unquoted(_1.target) }
          [*sent(program(words.first), words.drop(1)), *(words + targets).filter_map { _1[DEV, 1] }]
        end

        def self.sent(program, args)
          case program
          when *URLS then args.filter_map { _1[URL, 1] }
          when *NC then operands(args, NC_VALUED).first(1)
          when "socat" then args.filter_map { _1[SOCKET, 1] }
          when *SSH then operands(args, SSH_VALUED).first(1).map { _1[URL, 1] || _1.sub(USER, "") }
          when *COPIES then operands(args, []).filter_map { _1[URL, 1] || _1[REMOTE, 1] }
          when "git" then remote(operands(args, GIT_VALUED))
          else []
          end
        end

        # By the string, not File.basename, which raises on a NUL byte a model can write.
        def self.program(word) = word.to_s.split(File::SEPARATOR).last.to_s

        def self.remote(operands)
          subcommand, remote = operands
          return [] unless FETCHES.include?(subcommand)

          [remote.nil? ? DEFAULT_REMOTE : remote[URL, 1] || remote]
        end

        def self.operands(args, valued)
          args.each_index.reject { |at| args[at].start_with?("-") || (at.positive? && valued.include?(args[at - 1])) }
              .map { args[_1] }
        end

        def self.unquoted(word) = word.delete(%q('"))
        private_class_method :from, :program, :sent, :remote, :operands, :unquoted
      end

      # The scan of a session whose files cannot be read: nothing is a file it can count.
      module Unscanned
        # @param _path [String]
        # @return [nil]
        def self.call(_path) = nil
      end

      # @param named [Shell::Named] the paths the call names
      # @param stages [Array<Shell::Parse::Stage>] the call's stages, as parsed
      # @param cwd [String] absolute; the session's directory, a file below it named from there
      # @param scan [#call] `path -> Scanner::Count or nil`, nil for a path that names nothing
      # @return [Disclosure]
      def self.of(named, stages, cwd:, scan:)
        read = named.paths.reject { _1.written || _1.guess || _1.directory }
        files, bulk = read.partition { _1.pattern.nil? }
        counts = files.map(&:resolved).uniq.filter_map { |path| scan.call(path)&.then { [path, _1] } }
        new(holdings: held(counts, cwd), sinks: Sinks.of(stages), unnameable: named.opaque?,
            unscanned: unscanned(bulk, counts, cwd))
      end

      # @param context [Object, nil]
      # @return [Disclosure] the context's, or {NONE}
      def self.in(context) = context.respond_to?(:disclosure) ? context.disclosure : NONE

      def self.held(counts, cwd)
        counts.reject { |_, count| count.regions.nil? }.to_h { |path, count| [shown(path, cwd), count.regions] }
      end

      def self.unscanned(bulk, counts, cwd)
        partial = counts.reject { |_, count| count.whole }.map(&:first)
        [*bulk.map { root(_1) }, *partial].map { shown(_1, cwd) }
      end

      # A search reads below its root, so the root is what it names; a glob is named as written.
      def self.root(path) = path.pattern.end_with?(RECURSIVE) ? path.resolved : path.pattern

      def self.shown(path, cwd)
        return path if cwd == File::SEPARATOR
        return HERE if path == cwd

        below = cwd.end_with?(File::SEPARATOR) ? cwd : "#{cwd}#{File::SEPARATOR}"
        path.start_with?(below) ? path.delete_prefix(below) : path
      end
      private_class_method :held, :unscanned, :root, :shown

      def initialize(holdings:, sinks:, unnameable:, unscanned: [])
        super(holdings: Ractor.make_shareable(holdings.to_h { |path, count| [-path.to_s, Integer(count)] }),
              sinks: Ractor.make_shareable(sinks.map { -_1.to_s }.uniq), unnameable: unnameable == true,
              unscanned: Ractor.make_shareable(unscanned.map { -_1.to_s }.uniq))
      end

      NONE = new(holdings: {}, sinks: [], unnameable: false)

      # @return [Boolean] whether a file it reads holds a region, or what it reads is not wholly known
      def secret_bearing? = holds_secrets? || unnameable || unscanned.any?

      # @return [Boolean] whether a file it reads holds a region: all an automatic allow is contained for, since
      #   a read lain could not name or scan whole is most of a build or a commit
      def holds_secrets? = holdings.values.any?(&:positive?)

      # @return [Array<Parked::Queue::Reason>] lain's own words, each path and host inspected
      def notes
        [*holdings.select { _2.positive? }.map { |path, count| Parked::Queue::Reason.own(held_note(path, count)) },
         *(Parked::Queue::Reason.own(sent_note) unless sinks.empty?),
         *(Parked::Queue::Reason.own(UNNAMEABLE) if unnameable),
         *(Parked::Queue::Reason.own(format(UNSCANNED, paths: unscanned.map(&:inspect).join(", "))) if unscanned.any?)]
      end

      private

      def held_note(path, count)
        shown = count >= Scanner::CEILING ? "#{count} or more" : count.to_s
        format(HOLDS, path: path.inspect, count: shown, noun: "region".pluralize(count))
      end

      def sent_note
        format(SENDS, sinks: sinks.map(&:inspect).join(", "),
                      noun: sinks.one? ? "a network destination" : "network destinations")
      end
    end
  end
end
