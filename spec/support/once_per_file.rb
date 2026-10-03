# frozen_string_literal: true

# A value the first example that asks computes and every later example in the
# file reads, for when several examples put the same question to one slow
# process and differ only in what they assert about the answer. The compute
# block runs in the asking example, so it can use that example's helpers, and
# the value lives only as long as the file's group.
module OncePerFile
  def once(name, &compute)
    before(:context) { (@once_per_file ||= {})[name] = {} }

    # A compute that raises is remembered too, so a failed slow run fails each later example at
    # once instead of running again for every one.
    define_method(name) do
      holder = @once_per_file.fetch(name)
      holder.fetch(:value) do
        raise holder[:error] if holder.key?(:error)

        holder[:value] = instance_exec(&compute)
      rescue StandardError => e
        holder[:error] = e
        raise
      end
    end
  end
end

RSpec.configure { |config| config.extend OncePerFile }
