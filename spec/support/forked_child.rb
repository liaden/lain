# frozen_string_literal: true

require "English"
require "json"

# A child forked from a spec worker that already holds `lain`, standing in for
# a process the spec would otherwise boot cold. The worker's traps,
# descriptors and at_exit hooks are not the child's: it resets the first,
# closes the second, and ends in `exit!` however it ends, because the worker's
# hooks delete directories other examples still use.
module ForkedChild
  module_function

  # The outer ensure catches a signal that lands before live's own is armed.
  # @param errors [String] the file a raise's message is appended to
  # @yieldreturn [Integer] the child's exit status
  # @return [Integer] the child's pid
  def start(errors, &life)
    Process.fork do
      live(errors, &life)
    ensure
      exit!(1)
    end
  end

  # The nested ensure keeps the exit status when writing the error fails; the
  # outer ensure in start already keeps the worker's hooks from running.
  def live(errors)
    status = 1
    reset_traps
    status = yield
  ensure
    begin
      File.write(errors, $ERROR_INFO.full_message, mode: "a") if $ERROR_INFO
    ensure
      exit!(status)
    end
  end

  # PIPE stays ignored, as Ruby sets it at boot, so a write to a gone peer raises EPIPE.
  def reset_traps
    Signal.list.except("EXIT", "PIPE").each_key { |name| reset_trap(name) }
  end

  def reset_trap(name)
    trap(name, "SYSTEM_DEFAULT")
  rescue ArgumentError, Errno::EINVAL
    nil
  end

  # A worker descriptor left open keeps its far end alive, a PTY master among
  # them. Each worker IO gives up its fd first, or its finalizer would later
  # close a number the child reused. IO.for_fd refuses the VM's own.
  def close_inherited
    ObjectSpace.each_object(IO).reject { |io| io.closed? || [$stdin, $stdout, $stderr].include?(io) }
               .each { |io| io.autoclose = false }
    Dir.children("/proc/self/fd").map(&:to_i).select { |fd| fd > 2 }.each { |number| close_fd(number) }
  end

  def close_fd(number)
    IO.for_fd(number).close
  rescue ArgumentError, Errno::EBADF
    nil
  end

  # @param script [String] Ruby source, run at the top level
  # @param file [String] the name its backtraces carry
  # @return [Integer] 0, or the status it exited with
  def evaluate(script, file)
    TOPLEVEL_BINDING.eval(script, file)
    0
  rescue SystemExit => e
    e.status
  end

  # Runs the block in a throwaway fork of the worker carrying an at_exit hook
  # and TERM and INT traps, so none outlives the example. The hook fires only
  # in a process that inherited it and ran it.
  # @param dir [String] where the answer and the hook's mark are written
  # @yieldreturn [Object] JSON-able
  # @return [Array(Object, Boolean)] the block's answer, and whether the hook ran
  def in_a_worker_with_hooks(dir, &)
    answer = File.join(dir, "answer.json")
    ran = File.join(dir, "at_exit ran")
    Process.wait(Process.fork { answer_from_worker(answer, ran, &) })
    [answered(answer), File.exist?(ran)]
  end

  def answer_from_worker(answer, ran)
    worker = Process.pid
    at_exit { File.write(ran, "") unless Process.pid == worker }
    %w[TERM INT].each { |name| trap(name) { nil } }
    File.write(answer, JSON.generate("value" => yield))
  ensure
    begin
      File.write(answer, JSON.generate("error" => $ERROR_INFO.full_message)) if $ERROR_INFO
    ensure
      exit!(0)
    end
  end

  def answered(answer)
    parsed = JSON.parse(File.read(answer))
    raise "the throwaway worker raised:\n#{parsed["error"]}" if parsed.key?("error")

    parsed["value"]
  end
end
