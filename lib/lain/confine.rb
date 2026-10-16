# frozen_string_literal: true

module Lain
  # Confining a bash call: what it may run, read and write ({Profile}), the
  # argv that makes the kernel enforce that ({Launcher}, {Bwrap}), and what it
  # really ran ({Trace}). The sandbox bounds what a program can reach; it does
  # not decide which program may run, which the approval ladder still does.
  module Confine
  end
end
