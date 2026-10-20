require "lain"; require "tmpdir"; require "fileutils"
Dir.mktmpdir do |d|
  home = File.join(d, "home"); proj = File.join(d, "proj")
  FileUtils.mkdir_p([File.join(home, "Documents"), proj])
  File.write(File.join(home, ".npmrc"), "x")
  File.write(File.join(proj, "plain.txt"), "x")
  File.symlink(File.join(home, ".npmrc"), File.join(home, "Documents", "notes"))
  File.symlink(File.join(home, "Documents", "secret_dir_link"), File.join(proj, "x")) rescue nil
  s = Lain::Sensitivity.new(home: home, cwd: proj, root: proj)
  pol = Lain::Sensitivity::Policy.new(sensitivity: s, home: home, root: proj)
  a = File.join(home, "Documents", "notes")
  p written: s.classify(a), landing: s.classify(File.join(home, ".npmrc"))
  v = pol.judge(a, cwd: proj)
  p judged: v, oracle_approvable: v.oracle_approvable?
  # reverse: link named like a credential, landing out of scope
  File.write(File.join(home, "Documents", "plain"), "x")
  File.symlink(File.join(home, "Documents", "plain"), File.join(proj, ".npmrc"))
  b = File.join(proj, ".npmrc")
  v2 = pol.judge(b, cwd: proj)
  p judged2: v2, oracle_approvable: v2.oracle_approvable?
end
