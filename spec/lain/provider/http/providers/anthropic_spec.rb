# frozen_string_literal: true

RSpec.describe Lain::Provider::HTTP::Providers::Anthropic do
  # The class is assembled from the OUTSIDE: `anthropic.rb` names none of its
  # three mixins, and each of `anthropic/{chat,streaming,tools}.rb` includes
  # itself as it loads. That inversion is what breaks the require cycle those
  # three would otherwise form with the file that defines the class they reopen
  # -- and the price of it is that the class is only complete once every one of
  # them has been read, which is `eager_load`'s guarantee and nothing else's.
  #
  # So this is where that guarantee is cashed. Without it, a fourth module added
  # under `anthropic/` and never mixed in is not a NameError at boot -- it is a
  # `NoMethodError` on a live request path, from a class that looks fine.
  #
  # The expected set is READ OFF THE DIRECTORY rather than typed here, for the
  # same reason: a hand-written list is a second place to forget the new file.
  describe "how the wire protocol is assembled" do
    def mixin_files
      root = Lain::LOADER.dirs.first
      Dir.children(File.join(root, "lain/provider/http/providers/anthropic")).grep(/\.rb\z/).sort
    end

    # The loader's own inflector, not a `capitalize` here: a file whose name
    # needs an acronym rule would otherwise be looked up under a constant the
    # loader never defines, and the spec would report a missing mixin that is
    # really a missing camelization.
    def expected_mixins
      mixin_files.map do |file|
        described_class.const_get(Lain::LOADER.inflector.camelize(File.basename(file, ".rb"), file))
      end
    end

    it "finds the three files that each mix themselves in" do
      expect(mixin_files).to eq(%w[chat.rb streaming.rb tools.rb])
    end

    it "includes every module those files define" do
      missing = expected_mixins.reject { |mod| described_class.include?(mod) }

      expect(missing).to be_empty,
                         "#{missing.join(", ")} sits under anthropic/ and is not mixed into " \
                         "#{described_class}. Add `include` at the foot of its own file, the way its " \
                         "siblings do -- or, if it is not a mixin at all, say so here."
    end

    # Named as well as derived, because the sweep above is satisfied by a class
    # with no mixin files at all, and these three are the payload assembly the
    # provider would silently lose. Asked of `private_method_defined?`: each
    # mixin is a `module_function` module, so what an `include` grafts on is a
    # PRIVATE instance method, and `instance_methods` answers false for every
    # one of them whether or not the include happened.
    it "answers the messages those mixins carry" do
      absent = %i[render_payload completion_url parse_tool_calls]
               .reject { |message| described_class.private_method_defined?(message) }

      expect(absent).to be_empty
    end
  end
end
