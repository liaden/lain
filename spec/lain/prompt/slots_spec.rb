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

    it "raises on every top-level render, never only the first" do
      with_project("system" => "Now: <%= Time.now %>") do |root|
        slots = described_class.load(root:)

        3.times do
          expect { slots.render }.to raise_error(Lain::Prompt::ImpureSlot, /Time/)
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

  # The loaded snapshot is what every render reads, and it was session-fixed by
  # CLAIM only -- the trailing `freeze` in #initialize is shallow, so the
  # template hashes themselves used to stay writable and a later writer could
  # grow or replace a slot under an already-constructed Slots. Copied and
  # frozen at construction, that ONE property is mechanical. It is not
  # immutability: the template Strings are still the caller's, and mutating one
  # in place still moves the render (see the sibling example).
  describe "the loaded snapshot is copied and frozen at construction" do
    it "renders the slots it was built with after the caller's hashes are rewritten" do
      templates = { "system" => "shipped bulk" }
      role_templates = { "dev" => "dev framing" }
      slots = described_class.new(fills: {}, templates:, role_templates:)

      templates["system"] = "smuggled"
      role_templates["dev"] = "smuggled"
      templates.delete("system")

      expect(slots.render).to eq("shipped bulk")
      expect(slots.render_role("dev")).to eq("dev framing")
    end

    # The caller's Hash is the caller's: {.shipped_templates} hands ONE across
    # every instance, and a constructor that froze its argument would reach
    # into an object it does not own.
    it "leaves the caller's own hashes alone" do
      templates = { "system" => "shipped bulk" }
      described_class.new(fills: {}, templates:)

      expect(templates).not_to be_frozen
    end

    # SkillSlots freezes itself, so this pins the contract Slots leans on for
    # its own snapshot claim rather than a freeze Slots performs.
    it "renders through a skill-slot region that is frozen before it arrives" do
      region = Lain::Prompt::SkillSlots.new(fills: {}, templates: { "cp" => { "h" => "hole" } })
      slots = described_class.new(fills: {}, skill_slots: region)

      expect(region).to be_frozen
      expect(slots.render_skill("cp", "h")).to eq("hole")
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
    # against shipped templates only (no project overrides), before the fix.
    # The escalation bar: if fixing the binding moves any of these, stop.
    let(:shipped_system_digest) { "blake3:b8f7c81556a743daf8049a1a5290bc50c485f2f04edac5a8e810a3b0b5c9d41f" }
    let(:shipped_role_digests) do
      {
        "court_clerk" => "blake3:4879b45773658d7cac5285a0bffc53ee79e7249d461df494fb8a579d3e00ed50",
        "dev" => "blake3:d07a3b13c813c36c6ce8ecd5034893c8b39ca6b2df6c2004a1125f8039a6b9ed",
        "researcher" => "blake3:8bd27883cf2819e0a9612e776034556b6cd9064d5a1f9be9fa53f22c0ee36a0c",
        "reviewer_dba" => "blake3:fc9c90ceceeab6c7d82c2bea4fd828155dedd03eccbd5c23acf591ec2026f56e",
        "reviewer_security" => "blake3:ecb3aa0b4bc3c5edbc7441139277e9d56ea12eede714c2950c76e265a1edecd3",
        "reviewer_sre" => "blake3:a2368d9430c97547536f3ae515c23ca9c6a9a2b66e17d47aa598097f3d6b6539",
        "test_engineer" => "blake3:30f5366f06280c98f857304e1983ac6c6956af5b1dccce647a32e2084250b9c0"
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

  # The role namespace is a second, independent filename check (slots.rb:114) --
  # a typo here must be as loud as a top-level one, naming the file and the
  # full shipped roster rather than being silently dropped as an unreadable
  # override. Moved here from role_spec.rb: this is Prompt::Slots'
  # OWN behavior, so it belongs in Prompt::Slots' own spec, not borrowed
  # locality in the Role class's.
  describe "an unknown role slot file is loud (the role namespace, like top-level)" do
    it "names the file and rejects a role that ships no default" do
      Dir.mktmpdir do |root|
        path = File.join(root, ".lain", "slots", "role", "chef.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "cook something")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Prompt::UnknownSlot) { |e|
            expect(e.message).to include("chef")
            Lain::Role::Catalog.names.each { |name| expect(e.message).to include(name.to_s) }
          }
      end
    end
  end

  # A role is spelled one way everywhere a person meets it: the catalog, a
  # spawn line, and the file that overrides its framing.
  describe "a role slot file is named exactly as the role is" do
    def role_slot(root, basename, body)
      path = File.join(root, ".lain", "slots", "role", basename)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    it "fills test_engineer from test_engineer.md" do
      Dir.mktmpdir do |root|
        role_slot(root, "test_engineer.md", "OVERRIDE 42")

        expect(described_class.load(root:).render_role(:test_engineer)).to eq("OVERRIDE 42")
      end
    end

    it "refuses a hyphenated spelling, naming the rename that fixes it" do
      Dir.mktmpdir do |root|
        role_slot(root, "test-engineer.md", "OVERRIDE 42")
        path = File.join(root, ".lain", "slots", "role", "test-engineer.md")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Prompt::UnknownSlot,
                          "role slot files are spelled as the role is: rename #{path.inspect} to test_engineer.md")
      end
    end

    it "ships one default per catalog role, under the role's own name" do
      expect(described_class.shipped_role_templates.keys).to match_array(Lain::Role::Catalog.names.map(&:to_s))
    end
  end

  # A slot file is only ever read as `<name>.md`, so any other extension is a
  # file the author meant to be read and never would be.
  describe "a slot file with the wrong extension is named" do
    def slot_file(root, relative)
      path = File.join(root, ".lain", "slots", relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "a fill")
    end

    it "names a role slot's file and the .md name to rename it to" do
      Dir.mktmpdir do |root|
        slot_file(root, "role/dev.txt")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Prompt::UnknownSlot) { |e| expect(e.message).to include("dev.txt", "rename it to dev.md") }
      end
    end

    it "names a top-level slot's file and the .md name to rename it to" do
      Dir.mktmpdir do |root|
        slot_file(root, "system.markdown")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Prompt::UnknownSlot) { |e| expect(e.message).to include("system.markdown", "system.md") }
      end
    end

    it "never suggests a rename onto a slot that already exists, and says to remove the copy" do
      Dir.mktmpdir do |root|
        slot_file(root, "system.md")
        slot_file(root, "system.md.orig")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Prompt::UnknownSlot) { |e|
            expect(e.message).to include("system.md.orig", "system.md is already beside it, so remove it")
            expect(e.message).not_to include("rename")
          }
      end
    end

    # An editor holding a slot open leaves these beside it; lain must still start.
    %w[system.md~ .#system.md .system.md.swp role/dev.md~ role/.dev.md.swp .DS_Store].each do |leftover|
      it "skips #{leftover}, which an editor or the desktop left behind" do
        Dir.mktmpdir do |root|
          slot_file(root, "system.md")
          slot_file(root, leftover)

          expect(described_class.load(root:).render).to include("a fill")
        end
      end
    end

    it "still reads the role and skill directories beside the top-level files" do
      Dir.mktmpdir do |root|
        slot_file(root, "role/dev.md")
        slot_file(root, "skill/review/guidance.md")

        expect(described_class.load(root:).render_role(:dev)).to eq("a fill")
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

    # Purity is checked BEFORE evaluation, per render. That has to hold on the
    # SECOND call too, and after some other hole has rendered successfully in
    # between -- an impure fill that raised once and then resolved (or went
    # quiet) would put a nondeterministic value above the cache line, which is
    # the one failure this whole check exists to prevent.
    it "raises ImpureSlot on EVERY call, including after a sibling hole renders successfully" do
      with_skill_slots(shipped: { %w[create-plan steady] => "steady" },
                       overrides: { %w[create-plan conventions] => "Now: <%= Time.now %>" }) do |slots|
        impure = -> { slots.render_skill("create-plan", "conventions") }

        expect { impure.call }.to raise_error(Lain::Prompt::ImpureSlot, /Time/)
        expect { impure.call }.to raise_error(Lain::Prompt::ImpureSlot, /Time/)
        expect(slots.render_skill("create-plan", "steady")).to eq("steady")
        expect { impure.call }.to raise_error(Lain::Prompt::ImpureSlot, /Time/)
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
