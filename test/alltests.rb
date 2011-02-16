testsdir = File.expand_path("..", __FILE__)

$: << testsdir

Dir.chdir(testsdir) do
  Dir['**/test_*.rb'].each { |file| require(file) }
end
