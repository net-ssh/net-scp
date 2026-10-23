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

  def test_ipv6_host_is_passed_without_brackets
    stub_scp("data")
    URI("scp://user@[::1]:2222/path").open(&:read)
    assert_equal ["::1", "user"], @start_args.first(2)
  end

  def test_user_password_and_path_are_percent_decoded_once
    fake = stub_scp("data")
    URI("scp://us%65r%2Bx:p%40ss%3Aw+rd@example.com/dir%2Fsub/a%20b+c%2541%C3%A9").open(&:read)
    assert_equal ["example.com", "user+x", { port: 22, password: "p@ss:w+rd" }], @start_args
    assert_equal "/dir/sub/a b+c%41é", fake.remote
    assert_equal Encoding::UTF_8, fake.remote.encoding
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
