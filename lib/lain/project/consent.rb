# frozen_string_literal: true

require "digest"
require "fileutils"
require "shellwords"

module Lain
  class Project
    # Whether this project's `[approval]` table may GRANT authority.
    #
    # `.lain/config.toml` is a file a repository CARRIES, and {Config::Answers}
    # lets it name call shapes to pre-approve. Honoured unconditionally that
    # makes `git clone && lain up ./thing` hand a stranger the first
    # deterministic rung of {Approval::Escalation} -- ahead of the queue, ahead
    # of any human, and composed with {Resolver}'s rung 3, where the nearest
    # ancestor `.lain/` wins. So the pre-approval table is honoured only from a
    # root the user has consented to. Every OTHER table loads as it always did;
    # this one is gated because it is the only one that can grant authority.
    #
    # == Restricting needs no consent. Granting does.
    #
    # The asymmetry runs ONE way and it is the whole design: an unconsented
    # root's `[[approval.deny]]` and `[[approval.deny_tool]]` are honoured in
    # full, and only `[[approval.allow]]` is dropped. A refusal grants nothing,
    # so gating it would block the SAFE direction -- a cloned repository could
    # no longer say "never run bash here" -- which is the failure this class
    # would be introducing rather than the one it exists to prevent. The
    # strictest remembered answer still wins inside {Approval::Remembered}, so
    # a consented root that both allows and denies one shape denies it.
    #
    # == What consent is
    #
    # A per-root mark in XDG state ({Record}), keyed by a full-width digest of
    # the ROOT -- so two checkouts carrying byte-identical configs are two
    # decisions, and a decision survives into every later session. It is
    # granted by exactly two things:
    #
    # * an explicit `--root`/`--cwd`, which {Project#detected_by} reports as
    #   `:flag` -- naming a directory on the command line IS the intent, and
    #   {Resolver} records that rung precisely so this rule can read it; or
    # * an interactive first-run confirmation, asked through an INJECTED
    #   `confirm:` -- the {Frontend::ApprovalPolicy} shape, because only the
    #   frontend may hold a terminal.
    #
    # The default `confirm:` is {Unattended}, which answers `false`. A headless
    # run -- cron, a pipe, a supervisor -- is therefore NOT consented, and the
    # ordering is deliberate: no path here turns "nobody could be asked" into
    # "yes". Nobody is asked at all unless the file actually carries an `allow`
    # entry, so a project with nothing to grant never sees a prompt.
    #
    # == Exact shapes only
    #
    # This class widens nothing about matching. {Approval::Remembered} compares
    # a whole call shape by value, never a prefix, which is why consent can be
    # a coarse per-root yes at all: `approval/rule.rb`'s MA-1 hazard (a
    # `command.start_with?("git ")` rule allowing `git -c core.fsmonitor=id
    # status`) needs a partial match, and there is none to be had here.
    #
    # == A broken config costs the table, never the launch
    #
    # {.for} answers a consent that grants nothing when the file will not load,
    # and reports it once through `notice:` -- {CLI::EpicMount.for}'s posture,
    # including its trap: Ruby evaluates default arguments BEFORE the body's
    # rescue is armed, so every default that can raise lives on {.resolve}
    # inside the guarded region rather than in this method's signature.
    class Consent
      # Where the marks live under {Paths#state_home}.
      DIR = "consent"

      # The startup-notice seam's null, matching {CLI::EpicMount::SILENT}.
      SILENT = ->(_message) {}

      # The rung an explicit `--root`/`--cwd` produces, read from
      # {Project::DETECTED_BY} rather than spelled again, so a rename of the
      # rung breaks loudly here instead of silently ceasing to grant.
      FLAG = :flag

      IGNORED = "this project's remembered approvals are not in force: %<reason>s"
      # `--root` ALONE, and that is read off T6's own wiring rather than
      # guessed: `exe/lain`'s `project_override` builds
      # `resolved_project(root:, cwd: cwd || root)`, so `--cwd` defaults to the
      # root and naming the project is one flag. A remedy that told the user to
      # pass both would be teaching them a longer command than the binary needs.
      #
      # Shell-escaped because the line's whole value is that it can be pasted:
      # a root with a space in it otherwise renders a command that runs
      # somewhere else.
      UNCONSENTED = "%<path>s pre-approves %<count>d call shape(s); they are ignored, because this project root " \
                    "has not been consented to. Every one of those calls will be put to you as it happens. " \
                    "To consent to this root, re-open it with: lain chat --root %<root>s"

      # The confirmer of a run nobody is watching, and the reason it is a Null
      # Object rather than a nil check: every branch below asks the same
      # question, and the one answer this default may give is the refusal.
      # A run that cannot surface a prompt is not consented -- never consented
      # by default.
      class Unattended
        def call(_project) = false
      end

      # The mark itself: one file per consented root, under
      # `<state_home>/consent/<digest of the resolved root>`, whose body is the
      # root it was written for.
      #
      # == Presence is NOT the test
      #
      # A directory, a dangling symlink and a half-written file all EXIST, and
      # every one of them would grant if existence were the question. So a mark
      # counts when it is a REGULAR FILE whose contents are exactly the root
      # being asked about. That also makes a digest collision inert -- a
      # colliding root's mark names the other root and grants nothing -- which
      # is defence in depth behind the full-width key below.
      #
      # The REGULAR-FILE half is what refuses a FIFO, and the rescue would not
      # have: reading a FIFO with no writer blocks forever, so existence alone
      # would let anyone able to create a file in the state home wedge every
      # launch. It is a check-then-use, and that residual is accepted rather
      # than missed -- the path can be swapped between `File.file?` and
      # `File.read` -- but it narrows the attack from "plant it once and every
      # launch hangs" to "win a race on each one, with the same write access
      # either way".
      #
      # == Full-width, unlike {Paths#project_hash}
      #
      # That recipe truncates SHA-256 to twelve hex characters because it names
      # an nvim socket, where a collision is a nuisance. Here a colliding root
      # would INHERIT a trust decision, so the width is a boundary rather than a
      # filename, and widening it costs nothing.
      class Record
        # A mark is one path plus a newline. PATH_MAX plus room to SEE that a
        # longer file is longer is everything this ever needs to read, so a
        # corrupt entry cannot make the read unbounded.
        LIMIT = 4098

        # Every `root` below is ALREADY RESOLVED, and this class depends on that
        # rather than re-establishing it: {Project#initialize} realpaths both of
        # its paths, so a `Project#root` cannot carry an unresolved spelling.
        # This class kept a private copy of {Paths#resolved}'s expand-then-
        # realpath recipe until the T18 panel proved it dead -- replacing it
        # with a bare `File.expand_path` changed no behaviour anywhere -- so
        # what stands here is the precondition, stated, instead of a second
        # implementation of it that no caller can exercise.
        #
        # @param paths [Paths] supplies the state home the marks live under
        def initialize(paths: Paths.new)
          @paths = paths
          freeze
        end

        # @param root [String] a project root
        # @return [Boolean]
        def granted?(root) = recorded(path_for(root)) == mark_for(root)

        # Atomic replace, {Remembered::Persister#write}'s shape and for its
        # reasons: the bytes land in a sibling so the rename is a single-inode
        # swap and a reader only ever sees a whole mark, and the target is
        # RESOLVED first so a dotfiles-managed symlink survives the swap instead
        # of being quietly replaced by a regular file.
        #
        # @param root [String] a project root
        # @return [String] the mark that now exists
        def grant(root)
          target = resolved_target(path_for(root))
          FileUtils.mkdir_p(File.dirname(target))
          tmp = "#{target}.tmp-#{Process.pid}-#{object_id}"
          begin
            File.write(tmp, mark_for(root))
            File.rename(tmp, target)
          ensure
            FileUtils.rm_f(tmp)
          end
          target
        end

        # @param root [String] a resolved project root
        # @return [String] the mark's path, whether or not it exists
        def path_for(root) = File.join(@paths.state_home, DIR, Digest::SHA256.hexdigest(root))

        private

        def mark_for(root) = "#{root}\n"

        # nil for anything that is not a regular file, because every one of
        # those is "no mark here" and the caller's question is a Boolean. An
        # unreadable regular file is NOT rescued here and deliberately: it
        # raises into {Consent.for}'s own rescue, which answers not-consented
        # AND names the file through `notice:`. A local rescue would answer
        # not-consented in silence and then let the flag rung try to rewrite a
        # mark it just failed to read.
        def recorded(path) = File.file?(path) ? File.read(path, LIMIT) : nil

        def resolved_target(path) = File.exist?(path) ? File.realpath(path) : path
      end

      # Total: a config that will not load costs this project its remembered
      # approvals and nothing else.
      #
      # @param project [Project] the resolved project, whose `detected_by` is
      #   read as consent when it is `:flag`
      # @param notice [#call, nil] told once when the table had to be dropped,
      #   and once when an allow table is present but unhonoured; silent by default
      # @param injected [Hash] collaborators {.resolve} substitutes
      # @return [Consent]
      def self.for(project:, notice: nil, **injected)
        resolve(project:, notice: notice || SILENT, **injected)
      rescue Lain::Error, SystemCallError => e
        (notice || SILENT).call(format(IGNORED, reason: e.message))
        new(granted: false, answers: Config::Answers.empty)
      end

      # Resolution proper, with nothing rescued: every refusal here is {.for}'s
      # to answer, and this method exists so that the defaults raise where that
      # answer can hear them.
      #
      # @param project [Project] the resolved project
      # @param notice [#call] the startup-notice seam
      # @param paths [Paths] supplies the state home the mark is kept under
      # @param record [Record, nil] the mark store; built over `paths:` by default
      # @param confirm [#call] `Project -> Boolean`, the first-run confirmation;
      #   {Unattended} by default, which refuses
      # @param config [Config, nil] read from the project root by default -- HERE
      #   rather than in {.for}'s signature, so a malformed file raises inside
      #   that method's rescue rather than past it
      # @return [Consent]
      def self.resolve(project:, notice: SILENT, paths: Paths.new, record: nil, confirm: Unattended.new, config: nil)
        answers = (config || Config.load(root: project.root)).approval
        marks = record || Record.new(paths:)
        granted = grant?(project:, answers:, record: marks, confirm:)
        report(notice, project, answers) unless granted
        new(granted:, answers:)
      end

      # An existing mark, or a yes given now -- which is written down, so this
      # session's answer is every later session's.
      #
      # NOTHING TO GRANT IS NOTHING TO RECORD, and that guard comes FIRST, ahead
      # of the flag rung, because getting it wrong is silent: one `--root` at a
      # project with no `[[approval.allow]]` would otherwise mark that
      # repository permanently trusted, a consented root prints no line by
      # design, and an `[[approval.allow]]` added to it six months later would
      # then be honoured with nobody asked and nothing said. Naming a directory
      # is an intent about THIS session, not a standing decision about that
      # repository's future contents.
      def self.grant?(project:, answers:, record:, confirm:)
        return false if answers.allow.empty?
        return true if record.granted?(project.root)
        return false unless offered?(project, confirm)

        record.grant(project.root)
        true
      end

      # What amounts to a yes: the flag that IS intent, or a human saying so.
      #
      # `== true` rather than truthiness: a reader that answers a String, or a
      # surface that answers itself, has not said yes. {Frontend::ApprovalPolicy}
      # fails closed on the same line for the same reason.
      #
      # A confirmer that RAISES is a prompt that could not be surfaced -- a
      # closed stream is the ordinary headless shape -- and the only answer to
      # that is the answer {Unattended} gives. Never a crash, and never a yes.
      # It is not swallowed silently either: a refusal here leaves `granted`
      # false, so {.report} still names the file whose table is being ignored.
      def self.offered?(project, confirm)
        return true if project.detected_by == FLAG

        confirm.call(project) == true
      rescue StandardError
        false
      end

      # Said only when there is something to say: a project whose file grants
      # nothing has nothing ignored, and a startup line about it would fire in
      # every chat in every project that has never used the table.
      def self.report(notice, project, answers)
        return if answers.allow.empty?

        notice.call(format(UNCONSENTED, path: Resolver.config_path(project.root),
                                        count: answers.allow.length, root: Shellwords.escape(project.root)))
      end

      private_class_method :resolve, :grant?, :offered?, :report

      # @param granted [Boolean] whether this root may grant authority
      # @param answers [Config::Answers] the `[approval]` table as read
      def initialize(granted:, answers:)
        @granted = granted == true
        # The gate, in one expression: the restricting halves always, the
        # granting half only with consent.
        @remembered = Approval::Remembered.new(allow: @granted ? answers.allow : [],
                                               deny: answers.deny, deny_tools: answers.deny_tools)
        @rules = (@remembered.empty? ? [] : [@remembered]).freeze
        freeze
      end

      # The remembered answers this root is allowed to contribute, as a rule.
      # Never nil -- an unconsented root with nothing to refuse answers an
      # empty {Approval::Remembered}, which is its own Null Object.
      attr_reader :remembered

      # What {Approval::Escalation.for} takes as `rules:`. EMPTY when nothing
      # is remembered, so a project with no `[approval]` table wires the rung
      # exactly as it was wired before this class existed.
      attr_reader :rules

      def granted? = @granted
    end
  end
end
