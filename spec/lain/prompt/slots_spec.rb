# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Prompt::Slots do
  # A throwaway project dir with an optional .lain/slots/ tree. Slots are
  # session-fixed: loaded once from disk here, then rendered purely in memory.
  def with_project(slots = {})
    Dir.mktmpdir do |root|
      slots.each do |name, body|
        path = File.join(root, ".lain", "slots", "#{name}.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      yield root
    end
  end

  describe "a project override fills its hole verbatim" do
    it "puts the override file's content in the system hole" do
      with_project("system" => "PROJECT GUIDANCE 42: prefer haiku.") do |root|
        rendered = described_class.load(root:).render

        expect(rendered).to include("PROJECT GUIDANCE 42: prefer haiku.")
      end
    end
  end

  describe "a missing fill falls back to the shipped default" do
    it "renders the shipped base template and raises nothing" do
      with_project do |root|
        rendered = nil
        expect { rendered = described_class.load(root:).render }.not_to raise_error
        expect(rendered).to include(described_class.shipped_templates.fetch("system").strip.lines.first.strip)
      end
    end
  end

  describe "impurity fails loudly" do
    it "raises a named Lain error, never a silently nondeterministic value" do
      with_project("system" => "Now: <%= Time.now %>") do |root|
        expect { described_class.load(root:).render }
          .to raise_error(Lain::Prompt::ImpureSlot, /Time/)
      end
    end

    it "rejects impure Kernel calls (rand) the same way, by name" do
      with_project("system" => "<%= rand(100) %>") do |root|
        expect { described_class.load(root:).render }
          .to raise_error(Lain::Prompt::ImpureSlot, /rand/)
      end
    end

    it "rejects backtick subshells" do
      with_project("system" => "<%= `date` %>") do |root|
        expect { described_class.load(root:).render }
          .to raise_error(Lain::Prompt::ImpureSlot)
      end
    end

    it "names the offending slot" do
      with_project("system" => "<%= File.read('/etc/hostname') %>") do |root|
        expect { described_class.load(root:).render }
          .to raise_error(Lain::Prompt::ImpureSlot, /system/)
      end
    end

    # The lint is a node-type ALLOWLIST with default-reject, so every escape
    # hatch the review probes found -- reflection through a receiver, the
    # send/eval family, self, globals -- falls out rejected without being
    # individually named. Fills are single-quoted: nothing pre-interpolates.
    {
      "send" => "<%= 0.send(:rand) %>",
      "__send__" => "<%= 0.__send__(:rand) %>",
      "public_send" => '<%= "".public_send(:object_id) %>',
      "instance_eval" => '<%= "x".instance_eval("rand") %>',
      "eval" => '<%= eval("rand") %>',
      "self" => "<%= self %>",
      "object_id" => '<%= "".object_id %>',
      "__id__" => '<%= "".__id__ %>',
      "$$" => "<%= $$ %>",
      "$0" => "<%= $0 %>",
      "@resolve" => "<%= @resolve %>"
    }.each do |escape, fill|
      it "rejects the #{escape} escape by default, naming it" do
        with_project("system" => fill) do |root|
          expect { described_class.load(root:).render }
            .to raise_error(Lain::Prompt::ImpureSlot, /#{Regexp.escape(escape)}/)
        end
      end
    end

    it "rejects a method chained off the helper (partials are not a scripting language)" do
      with_project("system" => '<%= render("missing").to_i %>') do |root|
        expect { described_class.load(root:).render }
          .to raise_error(Lain::Prompt::ImpureSlot, /to_i/)
      end
    end
  end

  describe "renders are pure" do
    it "produces byte-identical output across repeated renders" do
      with_project("system" => "steady guidance") do |root|
        slots = described_class.load(root:)

        expect(slots.render).to eq(slots.render)
      end
    end

    it "is byte-identical across two loads of the same fills" do
      with_project("system" => "steady guidance") do |root|
        expect(described_class.load(root:).render).to eq(described_class.load(root:).render)
      end
    end
  end

  # The evaluator (LockedBinding#evaluate) has its OWN locals (source, label,
  # template) that must never be reachable from inside a fill -- a fill that
  # reads them is reading the evaluator's implementation, not the model of a
  # markdown partial. `template` is the LIVE escape: it is the ERB instance
  # itself, and its default #to_s embeds the object's address, so a bare
  # `<% template = template %><%= template %>` renders non-deterministically
  # across two otherwise-identical loads even though Prism's purity grammar
  # allows LocalVariableWrite/Read. `source` and `label` are plain strings
  # (deterministic content regardless of object identity), so they are dead
  # variants of the same shape -- not pinned here.
  describe "the evaluator binding leaks no locals of its own" do
    it "closes the leaked-local escape: renders across two fresh Slots stay byte-identical" do
      with_project("system" => "<% template = template %><%= template %>") do |root|
        first = begin
          described_class.load(root:).render
        rescue Lain::Prompt::ImpureSlot
          :rejected
        end
        second = begin
          described_class.load(root:).render
        rescue Lain::Prompt::ImpureSlot
          :rejected
        end

        expect(first).to eq(second)
      end
    end

    # A bare read of an evaluator local, with no prior assignment IN THE FILL,
    # is not even a LocalVariableReadNode to Prism -- lexically it is an
    # implicit method call, so it is already rejected as an impure call. This
    # pins that no evaluator-state bytes (a class name, an object id, an
    # inspect string) ever reach rendered output by that route either.
    %w[source label template].each do |name|
      it "rejects a bare `#{name}` read before it can leak evaluator state" do
        with_project("system" => "<%= #{name} %>") do |root|
          expect { described_class.load(root:).render }
            .to raise_error(Lain::Prompt::ImpureSlot, /#{name}/)
        end
      end
    end
  end

  describe "legitimate fills still render, digests unchanged from HEAD" do
    # Recorded from `Slots.load(root: <empty dir>).digests` / `#render_role`
    # against shipped templates only (no project overrides), before T2's fix.
    # The escalation bar: if fixing the binding moves any of these, stop.
    let(:shipped_system_digest) { "blake3:b8f7c81556a743daf8049a1a5290bc50c485f2f04edac5a8e810a3b0b5c9d41f" }
    let(:shipped_role_digests) do
      {
        "court-clerk" => "blake3:499fc742e000f14b49882c3c860b89717be9ed2e2f96d08bdab25dc953316de5",
        "dev" => "blake3:d07a3b13c813c36c6ce8ecd5034893c8b39ca6b2df6c2004a1125f8039a6b9ed",
        "researcher" => "blake3:8bd27883cf2819e0a9612e776034556b6cd9064d5a1f9be9fa53f22c0ee36a0c",
        "reviewer-dba" => "blake3:fc9c90ceceeab6c7d82c2bea4fd828155dedd03eccbd5c23acf591ec2026f56e",
        "reviewer-security" => "blake3:ecb3aa0b4bc3c5edbc7441139277e9d56ea12eede714c2950c76e265a1edecd3",
        "reviewer-sre" => "blake3:a2368d9430c97547536f3ae515c23ca9c6a9a2b66e17d47aa598097f3d6b6539",
        "test-engineer" => "blake3:30f5366f06280c98f857304e1983ac6c6956af5b1dccce647a32e2084250b9c0"
      }
    end

    it "renders the shipped system template twice, byte-identically, at the HEAD digest" do
      with_project do |root|
        slots = described_class.load(root:)

        expect(slots.render).to eq(slots.render)
        expect(slots.digests.fetch("system")).to eq(shipped_system_digest)
      end
    end

    it "renders every shipped role template twice, byte-identically, at the HEAD digest" do
      with_project do |root|
        slots = described_class.load(root:)

        shipped_role_digests.each do |role, digest|
          rendered = slots.render_role(role)

          expect(rendered).to eq(slots.render_role(role))
          expect(Lain::Canonical.digest(rendered)).to eq(digest)
        end
      end
    end
  end

  describe "an unknown top-level slot file is loud" do
    it "names the file and lists the known slots" do
      with_project("tyop" => "oops") do |root|
        expect { described_class.load(root:) }
          .to raise_error(Lain::Prompt::UnknownSlot) { |e|
            expect(e.message).to include("tyop")
            expect(e.message).to include("system")
          }
      end
    end
  end

  describe "content addressing" do
    it "digests each known slot's RENDERED bytes via Canonical" do
      with_project("system" => "addressed") do |root|
        slots = described_class.load(root:)

        expect(slots.digests.fetch("system")).to eq(Lain::Canonical.digest(slots.render("system")))
      end
    end

    it "gives differently-rendering fills different digests" do
      digest_for = lambda do |fill|
        with_project("system" => fill) { |root| described_class.load(root:).digests.fetch("system") }
      end

      expect(digest_for.call("one")).not_to eq(digest_for.call("two"))
    end
  end

  # The skill slot namespace is TWO-LEVEL, unlike the flat one-per-role region:
  # a skill has many holes, so a user override lives at
  # `.lain/slots/skill/<skill>/<hole>.md` over shipped hole defaults at
  # `templates/skill/<skill>/<hole>.md`. `#render_skill` is the pure LEAF render
  # of one hole; composing holes into a scaffold is the Skill::Renderer's job.
  describe "#render_skill renders one skill hole through the locked binding" do
    # A shipped skill dir (hole defaults) plus optional user overrides. The
    # scaffold `skill.md` is the catalog's concern; render_skill only reads holes.
    def with_skill_slots(shipped: {}, overrides: {})
      Dir.mktmpdir do |root|
        shipped_dir = File.join(root, "shipped")
        shipped.each do |(skill, hole), body|
          write_file(File.join(shipped_dir, skill, "#{hole}.md"), body)
        end
        overrides.each do |(skill, hole), body|
          write_file(File.join(root, ".lain", "slots", "skill", skill, "#{hole}.md"), body)
        end
        yield described_class.load(root:, skill_shipped_dir: shipped_dir)
      end
    end

    def write_file(path, body)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    it "injects the user override verbatim when present" do
      with_skill_slots(
        shipped: { %w[create-plan conventions] => "SHIPPED default" },
        overrides: { %w[create-plan conventions] => "USER 42 conventions" }
      ) do |slots|
        expect(slots.render_skill("create-plan", "conventions")).to eq("USER 42 conventions")
      end
    end

    it "falls back to the shipped default when no override exists" do
      with_skill_slots(shipped: { %w[create-plan conventions] => "SHIPPED default" }) do |slots|
        expect(slots.render_skill("create-plan", "conventions")).to eq("SHIPPED default")
      end
    end

    it "renders byte-identically across repeated calls" do
      with_skill_slots(shipped: { %w[create-plan conventions] => "steady" }) do |slots|
        expect(slots.render_skill("create-plan", "conventions"))
          .to eq(slots.render_skill("create-plan", "conventions"))
      end
    end

    it "raises ImpureSlot for an impure reference in the hole" do
      with_skill_slots(overrides: { %w[create-plan conventions] => "Now: <%= Time.now %>" }) do |slots|
        expect { slots.render_skill("create-plan", "conventions") }
          .to raise_error(Lain::Prompt::ImpureSlot, /Time/)
      end
    end

    it "raises UnknownSlot loudly when a hole has neither override nor shipped default" do
      with_skill_slots do |slots|
        expect { slots.render_skill("create-plan", "ghost") }
          .to raise_error(Lain::Prompt::UnknownSlot) { |e|
            expect(e.message).to include("ghost")
            expect(e.message).to include("create-plan")
          }
      end
    end
  end
end
