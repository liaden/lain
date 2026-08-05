# frozen_string_literal: true

require "async"
require "stringio"
require "tmpdir"

# The chat's end of the epic tier: which epic this session is in, the ONE
# ownership baton over it, and the {Lain::Tools::RequestReview} hung off that
# baton.
#
# The examples that park go through {#parked}, never a bare `task.with_timeout`
# -- a review is an unbounded wait by design, so a regression that never settles
# has to FAIL rather than hang. A hung run reports "fewer examples, 0 failures",
# which reads exactly like a pass. Copied from spec/lain/tools/request_review_spec.rb,
# which says why the obvious bound does not bound.
RSpec.describe Lain::CLI::EpicMount do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  # The seam Wiring reaches the session record through -- /dev/null under
  # --no-journal, a real journal here, exactly as {Switchboard.for} reads it.
  let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

  # Fully injected, so neither this machine's real epics nor its real session
  # journals can reach an example: repo-mode home under the tmpdir, and an XDG
  # state home inside it too.
  def paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state"), "HOME" => @dir })
  def config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo))

  def mount_for(options: {}, **overrides)
    described_class.for(chronicle:, options:, root: @dir, paths:, config:, **overrides)
  end

  def notices_from(options: {})
    said = []
    [mount_for(options:, notice: ->(message) { said << message }), said]
  end

  def issue(id) = Lain::Epic::Issue.new(id:, title: "the #{id} issue")
  def three_issue_graph = Lain::Epic::Graph.new(issues: [issue("a1"), issue("b2"), issue("c3")])

  def bare_home(slug) = Lain::Epic::Home.resolve(config:, paths:, root: @dir, slug:)

  # An epic exists once its document is on disk -- {Home.resolve} is pure and
  # creates nothing, so the write is what makes the directory the slug listing
  # finds.
  def create_epic(slug, graph = three_issue_graph)
    bare_home(slug).tap { |home| home.epic.write(Lain::Epic::Document.to_markdown(graph)) }
  end

  def written_side(home) = Lain::Epic::Intake::Written.new(graph: three_issue_graph, bytes: home.epic.read)

  # A bound that actually bounds: `task.with_timeout` alone raises in the
  # CALLING task while the child is still parked on the review's promise, and
  # `Sync` does not return until every child has finished. Stopping the children
  # in an `ensure` is what returns.
  def parked(timeout: 5, &block)
    Sync do |task|
      @runs = []
      begin
        task.with_timeout(timeout) { yield(task) }
      ensure
        @runs.each(&:stop)
      end
    end
  end

  # One tool call as a child task, registered with {#parked} so it cannot
  # outlive the example. `task.async` runs synchronously up to the first park,
  # so the review is already open when this returns.
  def call_in(task, tool, input)
    task.async { tool.call(input, invocation) }.tap { |run| @runs << run }
  end

  describe "which epic a chat is in" do
    it "wires request_review over the sole epic in the home" do
      create_epic("alpha")

      mount = mount_for

      expect(mount.slug).to eq("alpha")
      expect(mount.tools.map(&:name)).to eq(["request_review"])
    end

    # The whole reason --epic exists: the sole-epic default cannot answer, and
    # guessing would hand a human somebody else's document to review.
    it "offers no tool, and says which epics are here, when several are and none was named" do
      create_epic("alpha")
      create_epic("beta")

      mount, said = notices_from

      expect(mount.tools).to be_empty
      expect(said.join).to include("alpha", "beta", "--epic")
    end

    it "resolves the named epic over the sole-epic default" do
      create_epic("alpha")
      create_epic("beta")

      mount = mount_for(options: { epic: "beta" })

      expect(mount.slug).to eq("beta")
      expect(mount.tools.map(&:name)).to eq(["request_review"])
    end

    # The ordinary case. Most chats are not in an epic, and a startup line about
    # it every time would be noise no one can act on.
    it "says nothing at all when the project has no epics" do
      mount, said = notices_from

      expect(mount.tools).to be_empty
      expect(said).to be_empty
    end

    # Not the ordinary case: the human named one. Silence here would leave them
    # believing the tool is wired.
    it "names an epic that is not there rather than dropping the tool silently" do
      create_epic("alpha")

      _mount, said = notices_from(options: { epic: "ghost" })

      expect(said.join).to include("ghost")
    end

    # The T27 review's blocking find, pinned. `Config.load` sat in a DEFAULT
    # ARGUMENT, and Ruby evaluates those before the body's rescue is armed --
    # so every refusal below escaped the guard that names its class and stopped
    # the chat outright.
    #
    # It was a NEW regression rather than an old one: no chat path read
    # `.lain/config.toml` at all before this card, so the feature built to keep
    # a chat starting was what made seven config errors fatal to startup. The
    # population most exposed is the epic tier's own users, since `[epics]` is
    # the table they hand-edit.
    #
    # Driven at the PRODUCTION call shape -- no `root:`, `paths:` or `config:`
    # injected, because injecting a config is precisely what hides this.
    describe "a project config the chat cannot read" do
      def in_project_config(bytes)
        said = []
        FileUtils.mkdir_p(File.join(@dir, ".lain"))
        File.write(File.join(@dir, ".lain", "config.toml"), bytes)
        mount = Dir.chdir(@dir) { described_class.for(chronicle:, options: {}, notice: ->(m) { said << m }) }
        [mount, said]
      end

      {
        "TOML that does not parse" => "this is [not valid TOML ===\n",
        "an epics_home outside the closed set" => %([epics]\nhome = "sideways"\n),
        "a misspelled key in the [epics] table" => %([epics]\nhomme = "repo"\n)
      }.each do |what, bytes|
        it "starts the chat with no review tool, and says why, given #{what}" do
          mount, said = in_project_config(bytes)

          expect(mount.tools).to be_empty
          expect(said.join).to include("config.toml")
        end
      end
    end

    # A chat must never fail to start over this, whatever the epic tier says.
    it "starts anyway when the epics container cannot be listed" do
      FileUtils.mkdir_p(File.join(@dir, ".lain"))
      File.write(File.join(@dir, ".lain", "epics"), "not a directory")

      mount = nil

      expect { mount = mount_for }.not_to raise_error
      expect(mount.tools).to be_empty
    end
  end

  describe "the ONE baton per slug" do
    before { create_epic("alpha") }

    # Two Reviews sharing one journal both hand out generation 1, and
    # {Review::Replay#park} calls that a wiring error and CARRIES the damage
    # rather than refusing -- so the memo is the guard.
    it "hands back the identical Review every time" do
      mount = mount_for

      expect(mount.review).to equal(mount.review)
    end

    it "journals the review through the notes tee, so the tool has a reader for the annotations" do
      mount = mount_for

      expect(mount.notes).to equal(mount.notes)
      expect(mount.tools.first).to be_a(Lain::Tools::RequestReview)
    end

    # The invariant this whole object exists for, asserted rather than read off
    # the wiring: the SAME Review is the journaled home's `reviews:` and the
    # tool's `review:`, or the regeneration guard guards nothing.
    it "guards the journaled home with the SAME Review it hands the tool" do
      mount = mount_for
      path = bare_home("alpha").epic.path

      parked do |task|
        run = call_in(task, mount.tools.first, { "stage" => "epic_plan" })

        expect { mount.home.write_epic(three_issue_graph) }
          .to raise_error(Lain::Epic::Home::Journaled::ReviewPending)

        mount.review.settle(mount.review.generation_for(path), disk: File.binread(path))
        run.wait
      end
    end

    it "lets the home write again once the baton is back" do
      mount = mount_for
      path = bare_home("alpha").epic.path

      parked do |task|
        run = call_in(task, mount.tools.first, { "stage" => "epic_plan" })
        mount.review.settle(mount.review.generation_for(path), disk: File.binread(path))
        run.wait
      end

      expect { mount.home.write_epic(three_issue_graph) }.not_to raise_error
    end
  end

  # Review.from_journal, not Review.new: a chat restarted while a human still
  # holds a file must go on refusing to overwrite it.
  describe "a chat restarted mid-review" do
    it "rebuilds the open baton from the session journals and still refuses to regenerate" do
      home = create_epic("alpha")
      sessions = paths.sessions_dir(project: paths.project_hash(@dir))
      File.open(File.join(sessions, "prior.ndjson"), "ab") do |file|
        prior = Lain::Epic::Review.new(journal: Lain::Journal.new(io: file), epic_slug: "alpha")
        prior.open(path: home.epic.path, written: written_side(home))
      end

      mount = mount_for

      expect(mount.review.open?(home.epic.path)).to be(true)
      expect { mount.home.write_epic(three_issue_graph) }
        .to raise_error(Lain::Epic::Home::Journaled::ReviewPending)
    end

    # The fold is scoped to THIS epic: another epic's open claim must not hold
    # this one's document.
    it "ignores a claim belonging to another epic" do
      home = create_epic("alpha")
      other = create_epic("beta")
      sessions = paths.sessions_dir(project: paths.project_hash(@dir))
      File.open(File.join(sessions, "prior.ndjson"), "ab") do |file|
        prior = Lain::Epic::Review.new(journal: Lain::Journal.new(io: file), epic_slug: "beta")
        prior.open(path: other.epic.path, written: written_side(other))
      end

      mount = mount_for(options: { epic: "alpha" })

      expect(mount.review.open?(home.epic.path)).to be(false)
    end
  end

  describe "the collaborators the tool is late-bound to" do
    before { create_epic("alpha") }

    # HumanReplies does not exist when the toolset is built, so the wiring hands
    # a thunk and the tool reads it at CALL time.
    it "reads the bindings thunk when the tool asks, not when the mount is built" do
      replies = nil
      mount = mount_for(bindings: -> { replies })
      tool = mount.tools.first

      expect(tool.send(:bindings)).to equal(Lain::Tools::RequestReview::NoBindings)

      replies = :the_live_replies
      expect(tool.send(:bindings)).to eq(:the_live_replies)
    end

    # `notify:` is the one collaborator the tool does NOT coalesce -- it calls
    # @notify.question directly -- so a mount that defaulted it to nil would
    # wedge every hand-over with a NoMethodError.
    it "never hands the tool a nil notifier" do
      expect { mount_for.tools.first.send(:instance_variable_get, :@notify).question(agent: "lain", text: "x") }
        .not_to raise_error
    end

    # T21. `changesets:` is nil BY DEFAULT and deliberately -- a verdict has no
    # rail to arrive on yet, so a default source would ship a park nobody could
    # end -- and these two are one claim in two halves: the seam is THREADED, so
    # a caller that can answer turns the half on by injecting one rather than by
    # editing this class.
    it "leaves the changeset seam unwired, so implementation refuses rather than parking" do
      result = mount_for.tools.first.call({ "stage" => "implementation", "base" => "main" }, invocation)

      expect(result).to be_error
      expect(result.content).to include("no changeset")
    end

    it "forwards an injected changeset seam to the tool" do
      changesets = Class.new do
        def initialize = @asked = []

        attr_reader :asked

        def source(base:, head:)
          @asked << [base, head]
          nil
        end
      end.new
      mount_for(changesets:).tools.first.call({ "stage" => "implementation", "base" => "main" }, invocation)

      expect(changesets.asked).to eq([%w[main HEAD]])
    end
  end
end
