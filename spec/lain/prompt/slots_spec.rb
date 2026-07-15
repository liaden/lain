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
end
