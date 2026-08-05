# frozen_string_literal: true

require "json"
require "mixlib/shellout"

module Lain
  module Review
    module Source
      # A changeset read from a GitHub pull request.
      #
      # == The object database is the workhorse, not the API
      #
      # GitHub stops serving a combined diff past 300 changed files, and §3.7
      # measured a real work changeset at 810, so a source that asked the API
      # first would fail on exactly the changesets this exists for. It asks git
      # instead: `refs/pull/N/head` is an ordinary ref, so the pull request's
      # head fetches into the local object database and everything after that is
      # {LocalBranch} -- the SAME object, so the diff bytes, the merge-base
      # resolution, the walk and the per-commit numstat cannot differ between a
      # branch review and a pull request review. One parser downstream, because
      # there is one producer here.
      #
      # The combined diff is asked for in one case only: the head is not in the
      # object database yet, so GitHub can answer without a fetch. Any refusal
      # takes the fetch instead, and {#diff_origin} says so.
      #
      # The shape that path CANNOT see is a zero-exit, non-empty, TRUNCATED
      # diff: there is nothing local to check it against yet, which is the only
      # reason the API was asked. GitHub's documented behaviour at its ceilings
      # is a 406 refusal rather than a short answer, so a truncated one would be
      # a gh or proxy defect rather than the API's limit -- worth saying out
      # loud, because the port contract runs over this path (it catches a diff
      # of the WRONG revision range; measured, it does not catch a short one,
      # since every check there is one-directional: the walk accounts for at
      # least what the diff shows).
      #
      # == A refusal on the diff is a value; an unresolvable pull request raises
      #
      # {Forge::Gh}'s line, in both directions. gh refusing the combined diff is
      # data: the object database can answer the same question, so the refusal
      # becomes a {DiffOrigin} a caller journals rather than an exception it
      # handles. A pull request that does not resolve at all is the other side
      # of that line -- there is no review to be had -- so it raises
      # {UnknownRef}, which is this port's own doctrine.
      #
      # == A known limit, pinned rather than discovered
      #
      # The oids come from one `gh pr view` and the objects from a later fetch,
      # so a force-push in between moves `refs/pull/N/head` away from the head
      # GitHub named. That fails LOUDLY -- the oid is not among the objects
      # fetched, and {LocalBranch} refuses a ref that does not resolve -- rather
      # than quietly reviewing whatever the ref points at now. There is a spec.
      class GithubPr
        # A wedged gh must not stall the bench driving it -- {Forge::Gh}'s
        # bound, at the same scale of one API round trip.
        DEFAULT_TIMEOUT = 60

        # gh is not on this machine. Named rather than left as
        # `Errno::ENOENT - gh`, which tells a newcomer nothing about what is
        # missing or why this source wanted it.
        #
        # BESIDE {UnknownRef} rather than beneath it, and {Forge::Gh}'s doctrine
        # is what decides that: "gh answering 'no' is data, gh not existing is a
        # broken machine". Those are categorically different -- one is a fact
        # about the pull request, the other a fact about the machine, and only
        # the second is fixed by installing something -- and the class is the
        # one place a caller can tell them apart cheaply. Sharing a class would
        # make `rescue UnknownRef` swallow "the GitHub CLI is not here" as
        # though the pull request had been the problem. Both descend from
        # {Lain::Error}, so a caller wanting a single rescue still has one.
        class NoGh < Error
          def self.for(ref)
            new("gh is not on PATH, and this source needs it to read pull request #{ref.inspect} " \
                "from GitHub -- install the GitHub CLI, or review a local branch instead")
          end
        end

        # gh, and the three things this source asks it: which pull request the
        # caller means, what GitHub says its refs are, and -- when it can save a
        # fetch -- the combined diff itself.
        #
        # == Why gh is spawned here rather than through {Forge::Gh}
        #
        # Gh is a CLOSED set of four landing verbs whose names are written in
        # three places (its own methods, and twice in {Forge::Gh::Recorded},
        # which replays a journal); a verb missing from one of them replays
        # straight through to the live remote. Reading a pull request needs
        # `pr diff`, which is not one of them, and a read-only source has no
        # landing to fold into. So what is reused is the IDIOM, spelled
        # identically: an argv array through an injected `shell_out_factory`,
        # never a command string, and no `sh -c` anywhere -- there is no place
        # to put one.
        class Remote
          # gh resolves a pull request from a URL, a branch or a number, and the
          # ref is handed over as the human wrote it. Only `refs/pull/N/head`
          # needs the bare number, which is why it is parsed out rather than
          # required in that form.
          URL_NUMBER = %r{\A\w+://\S+/pull/(\d+)(?:[/?#]\S*)?\z}

          BARE_NUMBER = /\A#?(\d+)\z/

          # What the oids have to look like. A document answering anything else
          # is a gh whose shape this source does not know, and it is named
          # rather than passed along.
          SHA = /\A[0-9a-f]{40}\z/

          # The `--json` fields read below, and nothing else.
          FIELDS = %w[baseRefName baseRefOid headRefOid].freeze

          # GitHub's own words for the 300-file ceiling, as gh relays them:
          #
          #   could not find pull request diff: HTTP 406: Sorry, the diff
          #   exceeded the maximum number of files (300) (https://api.github…)
          #
          # The API answers 406 with `{"code": "too_large"}` and the same
          # sentence in `message`; the line-count ceiling is worded identically
          # with "lines" in place of "files", which is why the match stops
          # before the noun.
          #
          # This pattern NAMES a refusal. It never decides whether there was one
          # ({#refused?} does that), and the difference is the whole point: a
          # wording change at GitHub costs a less specific label, never a
          # silently truncated diff.
          TOO_LARGE = /diff exceeded the maximum number of/

          # What gh answered when asked for the combined diff: the bytes, and
          # the {DiffOrigin} that says whether they are usable.
          CombinedDiff = Data.define(:bytes, :origin)

          # @param ref [String] the pull request as the caller spelled it
          # @param cwd [String] where gh runs, which is how it resolves WHICH
          #   repository it is talking to
          # @param timeout [Numeric] seconds one gh call may take
          # @param shell_out_factory [#call] builds the subprocess runner
          # @raise [UnknownRef] if `ref` names no pull request at all
          def initialize(ref:, cwd:, timeout:, shell_out_factory:)
            @ref = ref
            @number = number_in(ref)
            @cwd = cwd
            @timeout = timeout
            @shell_out_factory = shell_out_factory
            freeze
          end

          # @return [Integer] the pull request number, which is what
          #   `refs/pull/N/head` needs
          attr_reader :number

          # @return [Hash] the head oid, the base oid and the base branch name,
          #   each validated
          # @raise [UnknownRef] if gh cannot resolve the pull request, answers a
          #   document this source cannot read, or leaves out a field
          def refs
            document = view
            { head: sha!(document, "headRefOid"), base: sha!(document, "baseRefOid"),
              base_name: base_name!(document) }
          end

          # @return [CombinedDiff] gh's bytes, or a refusal saying why the
          #   object database has to answer instead
          def combined_diff
            shell = gh("pr", "diff", @ref)
            return CombinedDiff.new(bytes: "".b, origin: refusal(shell)) if refused?(shell)

            CombinedDiff.new(bytes: shell.stdout.b.freeze, origin: DiffOrigin.served)
          rescue Mixlib::ShellOut::CommandTimeout => e
            CombinedDiff.new(bytes: "".b, origin: DiffOrigin.fallback(reason: "timeout", message: e.message))
          end

          private

          def number_in(ref)
            number = ref[URL_NUMBER, 1] || ref[BARE_NUMBER, 1]
            if number.nil?
              raise UnknownRef, "#{ref.inspect} names no pull request: expected a number like 42, " \
                                "or a URL like https://github.com/owner/repo/pull/42"
            end

            Integer(number, 10)
          end

          def view
            shell = gh("pr", "view", @ref, "--json", FIELDS.join(","))
            raise UnknownRef.unresolved("pull request", @ref, @cwd, shell) unless shell.exitstatus.zero?

            JSON.parse(shell.stdout)
          rescue JSON::ParserError => e
            raise UnknownRef, "gh answered a document this source cannot read for pull request " \
                              "#{@ref.inspect}: #{e.message}"
          rescue Mixlib::ShellOut::CommandTimeout => e
            raise UnknownRef, "gh did not answer about pull request #{@ref.inspect} within its " \
                              "bound, so its refs are unknown: #{e.message}"
          end

          def sha!(document, field)
            value = document[field].to_s
            unless value.match?(SHA)
              raise UnknownRef, "gh answered #{value.inspect} for #{field} of pull request " \
                                "#{@ref.inspect}, which is not a commit sha"
            end

            value.freeze
          end

          # The base branch is wanted BY NAME rather than by oid, because a
          # server may refuse a bare sha in a want; `baseRefOid` then resolves
          # from the objects that arrive, being reachable from the branch.
          def base_name!(document)
            name = document["baseRefName"].to_s
            if name.empty?
              raise UnknownRef, "gh answered no baseRefName for pull request #{@ref.inspect}, " \
                                "so there is no base branch to fetch"
            end

            name.freeze
          end

          # Two ways gh says no, and the second one is the dangerous one. A
          # non-zero exit is the ordinary refusal. An error on stderr with an
          # EMPTY stdout and a zero exit is gh answering nothing at all -- it
          # has shipped that shape (cli/cli#10712) -- and taken at face value it
          # reads as a pull request that changed no files, which is a review of
          # an empty changeset reported as a success. That is the silent
          # truncation octo's own fix introduced (research §4.5), reached from
          # the other direction.
          def refused?(shell)
            !shell.exitstatus.zero? || (shell.stdout.empty? && !shell.stderr.to_s.strip.empty?)
          end

          # stderr only, because that is where gh writes its errors and stdout
          # on a refused diff can be a partial patch -- scanning it would copy
          # megabytes to decide a LABEL. Wording gh puts somewhere else costs
          # the specific label and nothing more, which is the whole design of
          # {TOO_LARGE}.
          def refusal(shell)
            # Scrubbed BEFORE the match, not only on the way into the value: a
            # regexp against bytes that are invalid in the encoding they claim
            # raises, and this path exists to report a failure, not to add one.
            stderr = shell.stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub
            DiffOrigin.fallback(reason: stderr.match?(TOO_LARGE) ? "too_large" : "refused",
                                message: stderr.strip)
          end

          def gh(*)
            shell = @shell_out_factory.call("gh", *, cwd: @cwd, timeout: @timeout)
            shell.run_command
            shell
          rescue Errno::ENOENT
            raise NoGh.for(@ref)
          end
        end

        # @param pull_request [String, Integer] a pull request number, or a URL
        #   naming one
        # @param repo_root [String] the repository whose object database answers
        # @param remote [String] the remote `refs/pull/N/head` is fetched from
        # @param timeout [Numeric] seconds one gh call may take
        # @param shell_out_factory [#call] builds the subprocess runner,
        #   injected exactly as {Forge::Gh} and {LocalBranch} do
        # @raise [UnknownRef] if `pull_request` names no pull request, or gh
        #   cannot resolve the one it names
        def initialize(pull_request:, repo_root: Dir.pwd, remote: "origin",
                       timeout: DEFAULT_TIMEOUT,
                       shell_out_factory: Mixlib::ShellOut.public_method(:new))
          @repo_root = File.expand_path(repo_root)
          @remote = remote.to_s
          @shell_out_factory = shell_out_factory
          @remote_pr = Remote.new(ref: pull_request.to_s, cwd: @repo_root, timeout:,
                                  shell_out_factory:)
          read_refs
        end

        # @return [String] the pull request head's sha, frozen -- GitHub's own
        #   `headRefOid`, which is a fork's commit when the pull request comes
        #   from one and is served at `refs/pull/N/head` either way
        attr_reader :head_ref

        # @return [Integer] the pull request number
        def number = @remote_pr.number

        # @return [String] the merge base of the base branch and the head,
        #   frozen. GitHub's `baseRefOid` is the base BRANCH's tip and moves on
        #   its own; anchoring the old side to it would shift every old-side
        #   anchor the moment somebody merged something else into the base.
        def base_ref = local.base_ref

        # @return [Array<Commit>] oldest-first, each carrying its own numstat.
        #   Only the object database can answer this: a combined diff carries no
        #   commits, so asking for the walk is what forces the fetch.
        def commits = local.commits

        # @return [String] raw unified diff bytes, binary-encoded for
        #   {LocalBranch#diff}'s reason
        def diff = @diff ||= locally_answerable? ? from_object_database(DiffOrigin.already_local) : from_api

        # @return [DiffOrigin] where {#diff} came from. Asking forces the diff,
        #   because until it has been answered there is nothing to report.
        def diff_origin
          diff
          @diff_origin
        end

        private

        # Whether the object database can answer NOW -- which is not the same
        # question as the one the constructor asked. `@prefetched` is a snapshot
        # of a repository this object goes on to CHANGE: {#commits} fetches, so
        # a reviewer who lists the commits and then asks for the diff would
        # otherwise send us back to GitHub for something already on disk, and
        # the same pull request would report a different {#diff_origin} purely
        # by the order the messages arrived in. `@local` existing is the record
        # that the fetch has happened.
        def locally_answerable? = @prefetched || !@local.nil?

        # Whether the head was here BEFORE this object touched anything is read
        # once and kept, because it is the fetch's own precondition: reading it
        # afterwards would answer about the fetch instead of about the
        # repository.
        def read_refs
          refs = @remote_pr.refs
          @head_ref = refs.fetch(:head)
          @base_oid = refs.fetch(:base)
          @base_name = refs.fetch(:base_name)
          @prefetched = object?(@head_ref) && object?(@base_oid)
        end

        # Everything the object database can answer is answered by the class a
        # local branch review uses. Built lazily, because building it is what
        # fetches, and a diff GitHub can serve does not need the objects.
        def local
          @local ||= begin
            fetch! unless @prefetched
            LocalBranch.new(base: @base_oid, head: @head_ref, repo_root: @repo_root,
                            shell_out_factory: @shell_out_factory)
          end
        end

        # `refs/pull/N/head` is what GitHub serves for a pull request, including
        # one from a fork whose branch this remote does not carry. No
        # destination ref: the objects are what is wanted, and writing a local
        # ref into a human's repository is a side effect a read model has no
        # business having.
        def fetch!
          shell = git("fetch", "--no-tags", "--quiet", @remote,
                      "refs/pull/#{number}/head", "refs/heads/#{@base_name}")
          return if shell.exitstatus.zero?

          raise UnknownRef, "fetching pull request #{number} from #{@remote.inspect} into " \
                            "#{@repo_root} failed#{UnknownRef.because(shell)}"
        end

        def object?(sha) = git("cat-file", "-e", "#{sha}^{commit}").exitstatus.zero?

        def from_object_database(origin)
          @diff_origin = origin
          local.diff
        end

        def from_api
          answer = @remote_pr.combined_diff
          return from_object_database(answer.origin) if answer.origin.fell_back?

          @diff_origin = answer.origin
          answer.bytes
        end

        # {LocalBranch}'s pins and {Isolation::Worktree}'s scrub, read from a
        # METHOD body rather than the class body because `lain.rb` loads
        # isolation after review -- the same shape, and the same reason, as
        # {LocalBranch#git}.
        def git(*)
          shell = @shell_out_factory.call("git", "-C", @repo_root, *LocalBranch::CONFIG_PINS, *,
                                          environment: Isolation::Worktree::GIT_CONTEXT_SCRUB)
          shell.run_command
          shell
        end
      end
    end
  end
end
