require 'common'
require 'uri/open-scp'

class TestOpenSCP < Net::SCP::TestCase
  # Stands in for Net::SCP#download! of a single file, reporting progress the way Net::SCP::Download does.
  class FakeSCP
    attr_reader :remote, :local, :options
    attr_accessor :after_write

    def initialize(chunks)
      @chunks = chunks
    end

    def download!(remote, local = nil, options = {}, &progress)
      @remote = remote
      @local = local
      @options = options
      io = local || StringIO.new(String.new)
      total = @chunks.sum(&:bytesize)
      sent = 0
      progress&.call(:channel, File.basename(remote), sent, total)
      @chunks.each do |chunk|
        io.write(chunk)
        after_write&.call
        sent += chunk.bytesize
        progress&.call(:channel, File.basename(remote), sent, total)
      end
      local ? true : io.string
    end
  end

  def stub_scp(*chunks)
    fake = FakeSCP.new(chunks)
    Net::SCP.expects(:start).with { |*args| @start_args = args }.yields(fake)
    fake
  end

  def test_uri_port_and_password_are_passed_to_ssh
    stub_scp("data")
    assert_equal "data", URI("scp://user:secret@example.com:2222/file").open(&:read)
    assert_equal ["example.com", "user", { port: 2222, password: "secret" }], @start_args
  end

  def test_uri_without_password_does_not_set_one
    stub_scp("data")
    URI("scp://user@example.com/file").open(&:read)
    assert_equal ["example.com", "user", { port: 22 }], @start_args
  end

  def test_explicit_ssh_options_take_precedence_over_uri
    stub_scp("data")
    URI("scp://user:secret@example.com:2222/file").open(ssh: { port: 3333, password: "override", keys_only: true }, &:read)
    assert_equal ["example.com", "user", { port: 3333, password: "override", keys_only: true }], @start_args
  end
end
