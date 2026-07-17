# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Role do
  # A named capability the union can hold. Anonymous so a spec can name exactly
  # the tools a role attenuates to without wiring the real recorder-bearing tools.
  def tool(named)
    Class.new(Lain::Tool) do
      define_method(:name) { named.to_s }
      define_method(:description) { "the #{named} capability" }
      define_method(:input_schema) { { type: :object, properties: {} } }
      define_method(:perform) { |_input, _invocation| Lain::Tool::Result.ok("ok") }
    end.new
  end

  # The superset union a spawn attenuates FROM -- every tool any built-in role names.
  let(:union) do
    Lain::Toolset.new(
      %i[read_file list_files glob grep edit_file todo_write bash memory_write memory_read].map { |n| tool(n) }
    )
  end

  # A throwaway project with an optional .lain/slots/ tree. Keys are slot paths
  # under .lain/slots ("system", "role/test-engineer"); values are the file body.
  def with_project(slots = {})
    Dir.mktmpdir do |root|
      slots.each do |rel, body|
        path = File.join(root, ".lain", "slots", "#{rel}.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      yield Lain::Prompt::Slots.load(root:)
    end
  end

  describe "the filename mapping (underscores become hyphens)" do
    it "maps a role name to its .lain/slots/role/<name>.md basename" do
      expect(Lain::Role::Catalog.fetch(:test_engineer).slot_name).to eq("test-engineer")
      expect(Lain::Role::Catalog.fetch(:court_clerk).slot_name).to eq("court-clerk")
      expect(Lain::Role::Catalog.fetch(:dev).slot_name).to eq("dev")
    end
  end

  describe "a built-in role spawns attenuated and framed" do
    let(:role) { Lain::Role::Catalog.fetch(:test_engineer) }

    it "attenuates the union down to exactly the role's toolset" do
      expect(role.attenuate(union).names).to eq(role.only.map(&:to_s).sort)
    end

    it "its spawn policy carries the same attenuation" do
      expect(role.spawn_policy.attenuate(union).names).to eq(role.attenuate(union).names)
    end

    it "renders the role slot AFTER the role-invariant preamble" do
      with_project do |slots|
        preamble = slots.render("system")
        role_slot = slots.render_role(role.name)
        prelude = role.prelude(slots:)

        expect(prelude).to include(preamble)
        expect(prelude).to include(role_slot)
        expect(prelude.index(role_slot)).to be > prelude.index(preamble)
      end
    end
  end

  describe "an override touches one role only" do
    it "changes test_engineer's prelude and leaves every sibling byte-identical" do
      te = Lain::Role::Catalog.fetch(:test_engineer)
      siblings = Lain::Role::Catalog.all.reject { |r| r.name == :test_engineer }

      with_project do |before|
        with_project("role/test-engineer" => "OVERRIDE 42: bias toward property tests.") do |after|
          expect(te.prelude(slots: after)).not_to eq(te.prelude(slots: before))
          expect(after.render_role(:test_engineer)).to include("OVERRIDE 42")

          siblings.each do |sibling|
            expect(sibling.prelude(slots: after))
              .to eq(sibling.prelude(slots: before)), "#{sibling.name} prelude changed by a sibling override"
          end
        end
      end
    end
  end

  describe "the prelude splits into segments so the breakpoint can sit between them" do
    let(:sre) { Lain::Role::Catalog.fetch(:reviewer_sre) }
    let(:researcher) { Lain::Role::Catalog.fetch(:researcher) }

    it "returns a frozen [bulk, role_tail] pair" do
      with_project do |slots|
        segments = sre.prelude_segments(slots:)

        expect(segments).to be_frozen
        expect(segments.size).to eq(2)
        expect(segments).to all(be_frozen)
      end
    end

    it "shares a byte-identical bulk across two different roles" do
      with_project do |slots|
        expect(sre.prelude_segments(slots:).first).to eq(researcher.prelude_segments(slots:).first)
        expect(sre.prelude_segments(slots:).last).not_to eq(researcher.prelude_segments(slots:).last)
      end
    end

    it "joins to exactly #prelude, so the two surfaces cannot drift" do
      with_project do |slots|
        expect(sre.prelude_segments(slots:).join("\n\n")).to eq(sre.prelude(slots:))
      end
    end

    # The probe-shape from the T24 review: a fused String renders ONE system
    # block whose single mark lands after the role tail, so siblings share zero
    # cached bytes. Segments fix it -- the seam marks the bulk as its own block,
    # and the rendered system carries the mark ON the shared bulk.
    it "renders blocks=2 with the mark on the bulk when the seam marks segment 0" do
      with_project do |slots|
        bulk, tail = sre.prelude_segments(slots:)
        context = Lain::Context.new(
          model: "probe", max_tokens: 64,
          system: [{ "type" => "text", "text" => bulk, "cache" => true },
                   { "type" => "text", "text" => tail }]
        )
        timeline = Lain::Timeline.empty(store: Lain::Store.new)
                                 .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])

        request = context.render(timeline:, toolset: union)

        expect(request.system.size).to eq(2)
        expect(request.system.first["cache"]).to be(true)
        expect(request.system.first["text"]).to eq(bulk)
      end
    end
  end

  describe "the catalog and the shipped role templates cannot drift" do
    it "ships exactly one default template per catalog role, both directions" do
      catalog = Lain::Role::Catalog.names.map { |name| Lain::Prompt::Slots.role_slot_name(name) }.sort
      shipped = Lain::Prompt::Slots.shipped_role_templates.keys.sort

      expect(shipped).to eq(catalog),
                         "catalog/template drift -- catalog-only: #{(catalog - shipped).inspect}, " \
                         "shipped-only: #{(shipped - catalog).inspect}"
    end
  end

  describe "the cache properties hold" do
    it "renders byte-identical preludes for two spawns of one role in a session" do
      role = Lain::Role::Catalog.fetch(:reviewer_sre)
      with_project("system" => "steady guidance") do |slots|
        expect(role.prelude(slots:)).to eq(role.prelude(slots:))
      end
    end

    it "renders byte-identical tools blocks for two different roles under handler_union" do
      a = Lain::Role::Catalog.fetch(:reviewer_sre)
      b = Lain::Role::Catalog.fetch(:researcher)

      rendered = lambda do |role|
        policy = role.spawn_policy(posture: :handler_union)
        Lain::Canonical.dump(policy.posture.rendered_toolset(union:, allowed: role.attenuate(union)).to_schema)
      end

      expect(rendered.call(a)).to eq(rendered.call(b))
    end
  end

  describe "unknown roles are loud" do
    it "raises a named error listing the catalog" do
      expect { Lain::Role::Catalog.fetch(:chef) }
        .to raise_error(Lain::Role::Catalog::Unknown) { |e|
          expect(e.message).to include("chef")
          expect(e.message).to include("test_engineer")
        }
    end
  end

  describe "the catalog ships the OM-5 built-ins" do
    it "names dev, test_engineer, the three reviewers, researcher, court_clerk" do
      expect(Lain::Role::Catalog.names).to contain_exactly(
        :dev, :test_engineer, :reviewer_sre, :reviewer_security, :reviewer_dba, :researcher, :court_clerk
      )
    end

    it "ships a default role slot for every built-in (rendered without an override)" do
      with_project do |slots|
        Lain::Role::Catalog.all.each do |role|
          expect(slots.render_role(role.name)).not_to be_empty
        end
      end
    end
  end

  describe "an unknown role slot file is loud (the role namespace, like top-level)" do
    it "names the file and rejects a role that ships no default" do
      Dir.mktmpdir do |root|
        path = File.join(root, ".lain", "slots", "role", "chef.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "cook something")

        expect { Lain::Prompt::Slots.load(root:) }
          .to raise_error(Lain::Prompt::UnknownSlot, /chef/)
      end
    end

    it "rejects an impure override the same way top-level slots do" do
      expect do
        with_project("role/test-engineer" => "Now: <%= Time.now %>") do |slots|
          slots.render_role(:test_engineer)
        end
      end.to raise_error(Lain::Prompt::ImpureSlot, /Time/)
    end
  end
end
