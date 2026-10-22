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

  def test_progress_proc_receives_the_byte_count
    stub_scp("abc", "de")
    sizes = []
    URI("scp://user@example.com/file").open(progress_proc: ->(size) { sizes << size }, &:read)
    assert_equal [0, 3, 5], sizes
  end

  def test_content_length_proc_is_called_once_with_the_file_size
    stub_scp("abc", "de")
    lengths = []
    URI("scp://user@example.com/file").open(content_length_proc: ->(length) { lengths << length }, &:read)
    assert_equal [5], lengths
  end

  def test_callbacks_for_an_empty_file
    stub_scp
    lengths = []
    sizes = []
    data = URI("scp://user@example.com/file").open(content_length_proc: ->(length) { lengths << length },
                                                   progress_proc: ->(size) { sizes << size }, &:read)
    assert_equal "", data
    assert_equal [0], lengths
    assert_equal [0], sizes
  end
end
