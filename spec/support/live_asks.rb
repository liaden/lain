# frozen_string_literal: true

# Records every ask of the live disk made inside a block, so a spec over recorded facts can say none was made.
module LiveAsks
  # @return [Array<String>] each live-disk call the block made
  def live_asks
    asked = []
    stub_const("Lain::FileFacts::LIVE", recording_live(asked))
    { File => %i[realpath symlink? exist? file? directory? readlink stat lstat open new],
      Dir => %i[glob children each_child entries exist?] }.each do |owner, names|
      names.each { |name| record_class_call(owner, name, asked) }
    end
    yield
    asked
  end

  def recording_live(asked)
    live = Lain::FileFacts::LIVE
    Object.new.tap do |recorder|
      Lain::FileFacts::Live.instance_methods(false).each do |name|
        recorder.define_singleton_method(name) do |*args, **kw, &block|
          asked << "FileFacts::Live##{name}"
          live.public_send(name, *args, **kw, &block)
        end
      end
    end
  end

  def record_class_call(owner, name, asked)
    allow(owner).to receive(name).and_wrap_original do |original, *args, **kw, &block|
      asked << "#{owner}.#{name}"
      original.call(*args, **kw, &block)
    end
  end
end

RSpec.configure { |config| config.include LiveAsks }
