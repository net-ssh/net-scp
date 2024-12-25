require "rubygems"
require "rake"
require "rake/clean"
require "rdoc/task"
require "bundler/gem_tasks"

desc "When releasing make sure NET_SSH_BUILDGEM_SIGNED is set"
task :check_NET_SSH_BUILDGEM_SIGNED do
  raise "NET_SSH_BUILDGEM_SIGNED should be set to release" unless ENV['NET_SSH_BUILDGEM_SIGNED']
end

Rake::Task[:release].enhance [:check_NET_SSH_BUILDGEM_SIGNED]
Rake::Task[:release].prerequisites.unshift(:check_NET_SSH_BUILDGEM_SIGNED)

task default: ["build"]
CLEAN.include [ 'pkg', 'rdoc' ]
name = "net-scp"

require_relative "lib/net/scp/version"
version = Net::SCP::Version::CURRENT

namespace :cert do
  desc "Update public cert from private - only run if public is expired"
  task :update_public_when_expired do
    require 'openssl'
    require 'time'
    raw = File.read "net-scp-public_cert.pem"
    certificate = OpenSSL::X509::Certificate.new raw
    raise Exception, "Not yet expired: #{certificate.not_after}" unless certificate.not_after < Time.now
    sh "gem cert --build netssh@solutious.com --days 365*5 --private-key /mnt/gem/net-ssh-private_key.pem"
    sh "mv gem-public_cert.pem net-scp-public_cert.pem"
    sh "gem cert --add net-scp-public_cert.pem"
  end
end

if false
  begin
    require "jeweler"
    Jeweler::Tasks.new do |s|
      s.version = version
      s.name = name
      s.summary = "A pure Ruby implementation of the SCP client protocol"
      s.description = s.summary
      s.email = "net-ssh@solutious.com"
      s.homepage = "https://github.com/net-ssh/net-scp"
      s.authors = ["Jamis Buck", "Delano Mandelbaum"]

      s.add_dependency 'net-ssh', ">=2.6.5"

      s.add_development_dependency 'test-unit'
      s.add_development_dependency 'mocha'

      s.license = "MIT"

      s.signing_key = File.join('/mnt/gem/', 'gem-private_key.pem')
      s.cert_chain  = ['gem-public_cert.pem']
    end
    Jeweler::GemcutterTasks.new
  rescue LoadError
    puts "Jeweler (or a dependency) not available. Install it with: sudo gem install jeweler"
  end
end

require 'rake/testtask'
Rake::TestTask.new do |t|
  t.libs = ["lib", "test"]
end

extra_files = %w[LICENSE.txt THANKS.txt CHANGES.txt ]
RDoc::Task.new do |rdoc|
  rdoc.rdoc_dir = "rdoc"
  rdoc.title = "#{name} #{version}"
  rdoc.generator = 'hanna' # gem install hanna-nouveau
  rdoc.main = 'README.md'
  rdoc.rdoc_files.include("README*")
  rdoc.rdoc_files.include("bin/*.rb")
  rdoc.rdoc_files.include("lib/**/*.rb")
  extra_files.each { |file|
    rdoc.rdoc_files.include(file) if File.exist?(file)
  }
end

def change_version(&block)
  version_file = 'lib/net/scp/version.rb'
  require_relative version_file
  pre = Net::SCP::Version::PRE
  tiny = Net::SCP::Version::TINY
  result = block[pre: pre, tiny: Net::SCP::Version::TINY]
  raise ArgumentError, "Version change logic should always return a pre" unless result.key?(:pre)

  new_pre = result[:pre]
  new_tiny = result[:tiny] || tiny
  found = { pre: false, tiny: false }
  File.open("#{version_file}.new", "w") do |f|
    File.readlines(version_file).each do |line|
      match =
        if pre.nil?
          /^(\s+PRE\s+=\s+)nil(\s*)$/.match(line)
        else
          /^(\s+PRE\s+=\s+")#{pre}("\s*)$/.match(line)
        end
      if match
        prefix = match[1]
        postfix = match[2]
        prefix.delete_suffix!('"')
        postfix.delete_prefix!('"')
        new_line = "#{prefix}#{new_pre.inspect}#{postfix}"
        puts "Changing:\n  - #{line}  + #{new_line}"
        line = new_line
        found[:pre] = true
      end

      if new_tiny != tiny
        match = /^(\s+TINY\s+=\s+)#{tiny}(\s*)$/.match(line)
        if match
          prefix = match[1]
          postfix = match[2]
          new_line = "#{prefix}#{new_tiny}#{postfix}"
          puts "Changing:\n  - #{line}  + #{new_line}"
          line = new_line
          found[:tiny] = true
        end
      end

      f.write(line)
    end
    raise ArgumentError, "Cound not find line: PRE = \"#{pre}\" in #{version_file}" unless found[:pre]
    raise ArgumentError, "Cound not find line: TINY = \"#{tiny}\" in #{version_file}" unless found[:tiny] || new_tiny == tiny
  end

  FileUtils.mv version_file, "#{version_file}.old"
  FileUtils.mv "#{version_file}.new", version_file
end

namespace :vbump do
  desc "Final release"
  task :final do
    change_version do |pre:, tiny:|
      _ = tiny
      if pre.nil?
        { tiny: tiny + 1, pre: nil }
      else
        raise ArgumentError, "Unexpected pre: #{pre}" if pre.nil?

        { pre: nil }
      end
    end
  end

  desc "Increment prerelease"
  task :pre, [:type] do |_t, args|
    change_version do |pre:, tiny:|
      puts " PRE => #{pre.inspect}"
      match = /^([a-z]+)(\d+)/.match(pre)
      raise ArgumentError, "Unexpected pre: #{pre}" if match.nil? && args[:type].nil?

      if match.nil? || (!args[:type].nil? && args[:type] != match[1])
        if pre.nil?
          { pre: "#{args[:type]}1", tiny: tiny + 1 }
        else
          { pre: "#{args[:type]}1" }
        end
      else
        { pre: "#{match[1]}#{match[2].to_i + 1}" }
      end
    end
  end
end
