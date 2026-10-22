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

  def test_ipv6_host_is_passed_without_brackets
    stub_scp("data")
    URI("scp://user@[::1]:2222/path").open(&:read)
    assert_equal ["::1", "user"], @start_args.first(2)
  end

  def test_user_password_and_path_are_percent_decoded_once
    fake = stub_scp("data")
    URI("scp://us%65r%2Bx:p%40ss%3Aw+rd@example.com/dir%2Fsub/a%20b+c%2541%C3%A9").open(&:read)
    assert_equal ["example.com", "user+x"], @start_args.first(2)
    assert_equal "p@ss:w+rd", fake.options[:password]
    assert_equal "/dir/sub/a b+c%41é", fake.remote
    assert_equal Encoding::UTF_8, fake.remote.encoding
  end
end
