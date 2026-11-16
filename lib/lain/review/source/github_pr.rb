# frozen_string_literal: true

require "json"

module Lain
  module Review
    module Source
      # A changeset read from a GitHub pull request.
      #
      # THE OBJECT DATABASE IS THE WORKHORSE, NOT THE API. GitHub stops serving a
      # combined diff past 300 changed files, and a real work changeset was
      # measured at 810, so a source that asked the API first would fail on
      # exactly the changesets this exists for. It asks git instead:
      # `refs/pull/N/head` is an ordinary ref, so the head fetches into the local
      # object database and everything after that is {LocalBranch} -- the SAME
      # object, so the diff bytes, the merge-base resolution, the walk and the
      # per-commit numstat cannot differ between a branch review and a pull
      # request review.
      #
      # The combined diff is asked for in one case only: the head is not in the
      # object database yet, so GitHub can answer without a fetch. Any refusal
      # takes the fetch instead, and {#diff_origin} says so.
      #
      # The shape that path CANNOT see is a zero-exit, non-empty, TRUNCATED diff:
      # there is nothing local to check it against yet, which is the only reason
      # the API was asked. GitHub's documented behaviour at its ceilings is a 406
      # refusal rather than a short answer, so a truncated one would be a gh or
      # proxy defect -- worth saying out loud, because the port contract runs over
      # this path and catches a diff of the WRONG revision range but (measured)
      # not a short one.
      #
      # A REFUSAL ON THE DIFF IS A VALUE; AN UNRESOLVABLE PULL REQUEST RAISES.
      # {Forge::Gh}'s line, in both directions: gh refusing the combined diff is
      # data, because the object database can answer the same question, while a
      # pull request that does not resolve at all means there is no review to be
      # had.
      #
      # A KNOWN LIMIT, pinned rather than discovered: the oids come from one
      # `gh pr view` and the objects from a later fetch, so a force-push in
      # between moves `refs/pull/N/head` away from the head GitHub named. That
      # fails LOUDLY -- the oid is not among the objects fetched -- rather than
      # quietly reviewing whatever the ref points at now.
      class GithubPr
        # {#files} and {#identity}, over THIS class's {#diff} -- which is the
        # reason they are included rather than delegated to {#local} the way
        # {#commits} and {#file_at} are. {#diff} has two producers and the
        # API-served bytes never reach the local branch, so a delegated `#files`
        # would parse a locally regenerated diff instead of the bytes actually
        # served: the same changeset most days, and silently a different one
        # whenever the two disagree.
        include Diffed

        # A since commit as a human gives it: abbreviated or whole, and never
        # something git could read as an option.
        SINCE = /\A\h{4,40}\z/

        # gh is not on this machine. Named rather than left as
        # `Errno::ENOENT - gh`, which tells a newcomer nothing.
        #
        # BESIDE {UnknownRef} rather than beneath it, on {Forge::Gh}'s doctrine:
        # "gh answering 'no' is data, gh not existing is a broken machine". One is
        # a fact about the pull request, the other about the machine, and only the
        # second is fixed by installing something. Sharing a class would make
        # `rescue UnknownRef` swallow "the GitHub CLI is not here" as though the
        # pull request had been the problem.
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
        # Spawned through {Forge::Gh::Reads} rather than {Forge::Gh} because Gh is
        # a CLOSED set of four landing verbs whose names are written in three
        # places, and a verb missing from one of them replays straight through to
        # the live remote. Reading a pull request needs `pr diff`, which is not
        # one of them, and a read-only source has no landing to fold into. What
        # stays here is the reading of gh's answer: refusals map to raises and
        # values below.
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

          # GitHub's own words for the 300-file ceiling, as gh relays them:
          #
          #   could not find pull request diff: HTTP 406: Sorry, the diff
          #   exceeded the maximum number of files (300) (https://api.github...)
          #
          # The API answers 406 with `{"code": "too_large"}` and the same sentence
          # in `message`; the line-count ceiling is worded identically with
          # "lines" in place of "files", which is why the match stops before the
          # noun.
          #
          # This pattern NAMES a refusal and never decides whether there was one
          # ({#refused?} does that): a wording change at GitHub costs a less
          # specific label, never a silently truncated diff.
          TOO_LARGE = /diff exceeded the maximum number of/

          # What gh answered when asked for the combined diff: the bytes, and
          # the {DiffOrigin} that says whether they are usable.
          CombinedDiff = Data.define(:bytes, :origin)

          # @param ref [String] the pull request as the caller spelled it
          # @param cwd [String] the repository gh is asked about, named in a refusal
          # @param reads [Forge::Gh::Reads] runs the gh calls, as the configured account
          # @raise [UnknownRef] if `ref` names no pull request at all
          def initialize(ref:, cwd:, reads:)
            @ref = ref
            @number = number_in(ref)
            @cwd = cwd
            @reads = reads
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
            shell = naming_a_missing_gh { @reads.pr_diff(ref: @ref) }
            return CombinedDiff.new(bytes: "".b, origin: refusal(shell)) if refused?(shell)

            CombinedDiff.new(bytes: shell.stdout.b.freeze, origin: DiffOrigin.served)
          rescue Shell::Out::Timeout => e
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
            shell = naming_a_missing_gh { @reads.pr_refs(ref: @ref) }
            raise UnknownRef.unresolved("pull request", @ref, @cwd, shell) unless Shell::Out.ok?(shell)

            JSON.parse(shell.stdout)
          rescue JSON::ParserError => e
            raise UnknownRef, "gh answered a document this source cannot read for pull request " \
                              "#{@ref.inspect}: #{e.message}"
          rescue Shell::Out::Timeout => e
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

          # Two ways gh says no, and the second is the dangerous one. A non-zero
          # exit is the ordinary refusal. An error on stderr with an EMPTY stdout
          # and a zero exit is gh answering nothing at all -- it has shipped that
          # shape (cli/cli#10712) -- and taken at face value it reads as a pull
          # request that changed no files, which is a review of an empty
          # changeset reported as a success.
          def refused?(shell)
            !Shell::Out.ok?(shell) || (shell.stdout.empty? && !shell.stderr.to_s.strip.empty?)
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
            stderr = Utf8.legible(shell.stderr)
            DiffOrigin.fallback(reason: stderr.match?(TOO_LARGE) ? "too_large" : "refused",
                                message: stderr.strip)
          end

          def naming_a_missing_gh
            yield
          rescue Errno::ENOENT
            raise NoGh.for(@ref)
          end
        end

        # @param pull_request [String, Integer] a pull request number, or a URL
        #   naming one
        # @param repo_root [String] the repository whose object database answers
        # @param remote [String] the remote `refs/pull/N/head` is fetched from
        # @param shell_out_factory [#call] builds the subprocess runner,
        #   injected exactly as {Forge::Gh} and {LocalBranch} do
        # @param reads [Forge::Gh::Reads] runs the gh reads as the configured account
        # @param since [String, nil] a commit to review from instead of the merge
        #   base, as a re-review of a pull request the reviewer has already read
        # @raise [UnknownRef] if `pull_request` names no pull request, or gh
        #   cannot resolve the one it names, or `since` is not a sha
        def initialize(pull_request:, reads:, repo_root: Dir.pwd, remote: "origin", since: nil,
                       shell_out_factory: Shell::Out.public_method(:new))
          @repo_root = File.expand_path(repo_root)
          @remote = remote.to_s
          @shell_out_factory = shell_out_factory
          @git = Isolation::Checkout.of(@repo_root, shell_out_factory:)
          @remote_pr = Remote.new(ref: pull_request.to_s, cwd: @repo_root, reads:)
          @since = since && since_sha!(since.to_s)
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
        def diff = @diff ||= api_answerable? ? from_api : from_object_database(DiffOrigin.already_local)

        # The pull request from its merge base, which is what GitHub places a
        # comment against whatever range the round shows.
        #
        # @return [Diffed]
        def whole
          return self if @since.nil?

          local
          @whole ||= LocalBranch.new(base: @base_oid, head: @head_ref, repo_root: @repo_root,
                                     shell_out_factory: @shell_out_factory)
        end

        # @return [String, nil] why the whole pull request is shown although a
        #   since commit was named, or nil when the range is as asked. Asking
        #   forces the fetch, because only the object database knows ancestry.
        def since_note
          return if @since.nil?

          local
          @since_note
        end

        # Delegated like {#base_ref} and {#commits}, and for the sharper half of
        # their reason: one file at one revision is a question only the object
        # database answers, so asking it is what forces the fetch. The API leg
        # could not serve it in any case -- a combined diff carries hunks, never
        # whole files.
        #
        # @param revision [String] a commit-ish
        # @param path [String] repository-relative
        # @return [String, nil] the file's bytes, or nil when that revision
        #   carries no such path
        def file_at(revision, path) = local.file_at(revision, path)

        # {#file_at} for many sides, delegated for the same reason.
        #
        # @param requests [Array<Array(String, String)>] `[revision, path]` pairs
        # @return [Hash{Array, String, String => String, nil}]
        def files_at(requests) = local.files_at(requests)

        # {LocalBranch#checked_out?}, through this object's own `git` rather than
        # delegated to `#local`: building that is what fetches, and a reviewer
        # whose checkout is not the pull request's head -- the ordinary case --
        # would pay a fetch to be told so. HEAD is compared before anything else.
        #
        # @param path [String] repository-relative
        # @return [Boolean]
        def checked_out?(path)
          pinned = ->(*argv, **opts) { @git.run(*argv, pins: LocalBranch::PINS, **opts) }
          LocalBranch::Checkout.new(head_ref: @head_ref, &pinned).holds?(path)
        end

        # @return [DiffOrigin] where {#diff} came from. Asking forces the diff,
        #   because until it has been answered there is nothing to report.
        def diff_origin
          diff
          @diff_origin
        end

        private

        # Whether the object database can answer NOW -- not the question the
        # constructor asked. `@prefetched` is a snapshot of a repository this
        # object goes on to CHANGE: {#commits} fetches, so a reviewer who lists
        # the commits and then asks for the diff would otherwise be sent back to
        # GitHub for something already on disk, and the same pull request would
        # report a different {#diff_origin} purely by message order.
        def locally_answerable? = @prefetched || !@local.nil?

        # GitHub's combined diff is always the whole pull request, so a range
        # can only come from the object database.
        def api_answerable? = @since.nil? && !locally_answerable?

        def since_sha!(value)
          return value.freeze if value.match?(SINCE)

          raise UnknownRef, "--since #{value.inspect} is not a commit sha"
        end

        # The old side of the review: the since commit when the head descends
        # from it, else the merge base the whole pull request is anchored to,
        # with the reason kept for the banner.
        def range_base
          @range_base ||= ancestral_since || @base_oid
        end

        def ancestral_since
          return if @since.nil?

          @since = full_since
          return @since if ancestor?(@since)

          @since_note = "since commit #{@since[0, 12]} is not an ancestor of the pull request head " \
                        "#{@head_ref[0, 12]} (force-pushed?), so the whole pull request is shown"
          nil
        end

        # git prefers a ref NAME over an abbreviated sha, so the answer is only
        # the commit the human typed if it still begins with what they typed.
        def full_since
          shell = @git.run("rev-parse", "--verify", "--quiet", "--end-of-options", "#{@since}^{commit}",
                           pins: LocalBranch::PINS)
          found = shell.stdout.to_s.strip
          return found.freeze if Shell::Out.ok?(shell) && found.start_with?(@since.downcase)

          raise UnknownRef, "since commit #{@since} is unknown or ambiguous in this repository: " \
                            "name a commit sha that no branch or other commit shares a prefix with"
        end

        def ancestor?(sha)
          Shell::Out.ok?(@git.run("merge-base", "--is-ancestor", "#{sha}^{commit}", @head_ref, pins: LocalBranch::PINS))
        end

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
            LocalBranch.new(base: range_base, head: @head_ref, repo_root: @repo_root,
                            shell_out_factory: @shell_out_factory)
          end
        end

        # `refs/pull/N/head` is what GitHub serves for a pull request, including
        # one from a fork whose branch this remote does not carry. No
        # destination ref: the objects are what is wanted, and writing a local
        # ref into a human's repository is a side effect a read model has no
        # business having.
        def fetch!
          shell = @git.run("fetch", "--no-tags", "--quiet", @remote,
                           "refs/pull/#{number}/head", "refs/heads/#{@base_name}", pins: LocalBranch::PINS)
          return if Shell::Out.ok?(shell)

          raise UnknownRef, "fetching pull request #{number} from #{@remote.inspect} into " \
                            "#{@repo_root} failed#{UnknownRef.because(shell)}"
        end

        def object?(sha) = Shell::Out.ok?(@git.run("cat-file", "-e", "#{sha}^{commit}", pins: LocalBranch::PINS))

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
      end
    end
  end
end
