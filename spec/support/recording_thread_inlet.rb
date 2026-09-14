# frozen_string_literal: true

# What the editor's inlet is, from {Lain::Frontend::Neovim::ThreadView}'s side: it
# takes the anchor's identity and the rendered conversation, and answers why it
# did not land. Shared because BOTH halves of the thread pane need it: the Ruby
# view's own spec builds one to read back what it posted, and `51_thread.lua`'s
# spec builds one to obtain a REAL rendering to drive into the editor -- the
# lines production would send, rather than a fixture written twice.
class RecordingThreadInlet
  attr_reader :posts

  def initialize(refusal: nil)
    @posts = []
    @refusal = refusal
  end

  def set_thread(anchor, lines)
    @posts << [anchor, lines]
    @refusal
  end
end
