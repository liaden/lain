require "lain"; require "tmpdir"; require "fileutils"
Dir.mktmpdir do |d|
  home = File.join(d, "home"); proj = File.join(d, "proj"); other = File.join(d, "other")
  FileUtils.mkdir_p([home, proj, other])
  File.write(File.join(other, ".npmrc"), "x")
  s = Lain::Sensitivity.new(home: home, cwd: proj, root: proj)
  pol = Lain::Sensitivity::Policy.new(sensitivity: s, home: home, root: proj)
  c = pol.confined(roots: [proj])
  path = File.join(other, ".npmrc")
  p plain: pol.judge(path, cwd: proj)
  v = c.judge(path, cwd: proj)
  p confined: v, oracle_approvable: v.oracle_approvable?
end
