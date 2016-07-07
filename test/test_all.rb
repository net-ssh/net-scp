Dir.chdir(File.dirname(__FILE__)) do
  (Dir['**/test_*.rb']-["test_all.rb"]).each { |file| require(file) }
end
