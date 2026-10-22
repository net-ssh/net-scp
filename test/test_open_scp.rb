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

  def test_download_is_written_into_the_open_uri_buffer_as_it_arrives
    first = "a" * 6000
    second = "b" * 6000
    fake = stub_scp(first, second)
    buf = OpenURI::Buffer.new
    sizes = []
    fake.after_write = -> { sizes << buf.size }

    URI("scp://user@example.com/file").buffer_open(buf, nil, {})

    assert_equal [6000, 12000], sizes
    assert_kind_of Tempfile, buf.io
    assert_equal first + second, buf.io.read
  end

  def test_empty_download
    stub_scp
    assert_equal "", URI("scp://user@example.com/file").open(&:read)
  end
end
