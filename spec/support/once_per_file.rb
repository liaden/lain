# frozen_string_literal: true

# A value the first example that asks computes and every later example in the
# file reads, for when several examples put the same question to one slow
# process and differ only in what they assert about the answer. The compute
# block runs in the asking example, so it can use that example's helpers, and
# the value lives only as long as the file's group.
module OncePerFile
  def once(name, &compute)
    before(:context) { (@once_per_file ||= {})[name] = {} }

    define_method(name) do
      holder = @once_per_file.fetch(name)
      holder.fetch(:value) { holder[:value] = instance_exec(&compute) }
    end
  end
end

RSpec.configure { |config| config.extend OncePerFile }
