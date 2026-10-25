require 'common'
require 'pathname'
require 'tmpdir'
require 'timeout'

class TestUpload < Net::SCP::TestCase
  def test_upload_file_should_transfer_file
    prepare_file("/path/to/local.txt", "a" * 1234)

    expect_scp_session "-t /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0666 1234 local.txt\n"
      channel.gets_ok
      channel.sends_data "a" * 1234
      channel.sends_ok
      channel.gets_ok
    end

    assert_scripted { scp.upload!("/path/to/local.txt", "/path/to/remote.txt") }
  end
  
  def test_upload_file_with_spaces_in_name_should_escape_remote_file_name
    prepare_file("/path/to/local file.txt", "")

    expect_scp_session "-t /path/to/remote\\ file.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0666 0 local file.txt\n"
      channel.gets_ok
      channel.sends_ok
      channel.gets_ok
    end

    assert_scripted { scp.upload!("/path/to/local file.txt", "/path/to/remote file.txt") }
  end
  
  def test_upload_file_with_metacharacters_in_name_should_escape_remote_file_name
    prepare_file("/path/to/local/#{awful_file_name}", "")

    expect_scp_session "-t /path/to/remote/#{escaped_file_name}" do |channel|
      channel.gets_ok
      channel.sends_data "C0666 0 #{awful_file_name}\n"
      channel.gets_ok
      channel.sends_ok
      channel.gets_ok
    end

    assert_scripted { scp.upload!("/path/to/local/#{awful_file_name}", "/path/to/remote/#{awful_file_name}") }
  end

  def test_upload_file_with_preserve_should_send_times
    prepare_file("/path/to/local.txt", "a" * 1234, 0666, Time.at(1234567890, 123456), Time.at(1234543210, 345678))

    expect_scp_session "-t -p /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "T1234567890 123456 1234543210 345678\n"
      channel.gets_ok
      channel.sends_data "C0666 1234 local.txt\n"
      channel.gets_ok
      channel.sends_data "a" * 1234
      channel.sends_ok
      channel.gets_ok
    end

    assert_scripted { scp.upload!("/path/to/local.txt", "/path/to/remote.txt", :preserve => true) }
  end

  def test_upload_file_with_progress_callback_should_invoke_callback
    prepare_file("/path/to/local.txt", "a" * 3000 + "b" * 3000 + "c" * 3000 + "d" * 3000)

    expect_scp_session "-t /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0666 12000 local.txt\n"
      channel.gets_ok
      channel.sends_data "a" * 3000
      channel.sends_data "b" * 3000
      channel.sends_data "c" * 3000
      channel.sends_data "d" * 3000
      channel.sends_ok
      channel.gets_ok
    end

    calls = []
    progress = Proc.new do |ch, name, sent, total|
      calls << [name, sent, total]
    end

    assert_scripted do
      scp.upload!("/path/to/local.txt", "/path/to/remote.txt", :chunk_size => 3000, &progress)
    end

    assert_equal ["/path/to/local.txt",     0, 12000], calls.shift
    assert_equal ["/path/to/local.txt",  3000, 12000], calls.shift
    assert_equal ["/path/to/local.txt",  6000, 12000], calls.shift
    assert_equal ["/path/to/local.txt",  9000, 12000], calls.shift
    assert_equal ["/path/to/local.txt", 12000, 12000], calls.shift
    assert calls.empty?
  end

  def test_upload_io_with_recursive_should_ignore_recursive
    expect_scp_session "-t -r /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0640 1234 remote.txt\n"
      channel.gets_ok
      channel.sends_data "a" * 1234
      channel.sends_ok
      channel.gets_ok
    end

    io = StringIO.new("a" * 1234)
    assert_scripted { scp.upload!(io, "/path/to/remote.txt", :recursive => true) }
  end

  def test_upload_io_with_preserve_should_ignore_preserve
    expect_scp_session "-t -p /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0640 1234 remote.txt\n"
      channel.gets_ok
      channel.sends_data "a" * 1234
      channel.sends_ok
      channel.gets_ok
    end

    io = StringIO.new("a" * 1234)
    assert_scripted { scp.upload!(io, "/path/to/remote.txt", :preserve  => true) }
  end

  def test_upload_io_should_transfer_data
    expect_scp_session "-t /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0640 1234 remote.txt\n"
      channel.gets_ok
      channel.sends_data "a" * 1234
      channel.sends_ok
      channel.gets_ok
    end

    io = StringIO.new("a" * 1234)
    assert_scripted { scp.upload!(io, "/path/to/remote.txt") }
  end

  def test_upload_partially_read_io_should_announce_remaining_bytes
    expect_scp_session "-t /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0640 5 remote.txt\n"
      channel.gets_ok
      channel.sends_data "fghij"
      channel.sends_ok
      channel.gets_ok
    end

    io = StringIO.new("abcdefghij")
    io.pos = 5
    Timeout.timeout(5) do
      assert_scripted { scp.upload!(io, "/path/to/remote.txt") }
    end
    assert !io.closed?
  end

  def test_upload_partially_read_file_object_should_announce_remaining_bytes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "local.txt")
      File.binwrite(path, "abcdef")
      File.chmod(0o644, path)

      expect_scp_session "-t /path/to/remote.txt" do |channel|
        channel.gets_ok
        channel.sends_data "C0644 4 remote.txt\n"
        channel.gets_ok
        channel.sends_data "cdef"
        channel.sends_ok
        channel.gets_ok
      end

      File.open(path, "rb") do |file|
        file.read(2)
        Timeout.timeout(5) do
          assert_scripted { scp.upload!(file, "/path/to/remote.txt") }
        end
        assert !file.closed?
      end
    end
  end

  def test_upload_io_positioned_past_end_should_announce_zero_bytes
    expect_scp_session "-t /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0640 0 remote.txt\n"
      channel.gets_ok
      channel.sends_ok
      channel.gets_ok
    end

    io = StringIO.new("abc")
    io.pos = 10
    Timeout.timeout(5) do
      assert_scripted { scp.upload!(io, "/path/to/remote.txt") }
    end
  end

  def test_upload_io_without_pos_should_announce_its_size
    io = Object.new
    def io.size; 3; end
    def io.read(_length); @read ? nil : (@read = true; "abc"); end

    expect_scp_session "-t /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0640 3 remote.txt\n"
      channel.gets_ok
      channel.sends_data "abc"
      channel.sends_ok
      channel.gets_ok
    end

    Timeout.timeout(5) do
      assert_scripted { scp.upload!(io, "/path/to/remote.txt") }
    end
  end

  def test_upload_io_with_mode_should_honor_mode_as_permissions
    expect_scp_session "-t /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0666 1234 remote.txt\n"
      channel.gets_ok
      channel.sends_data "a" * 1234
      channel.sends_ok
      channel.gets_ok
    end

    io = StringIO.new("a" * 1234)
    assert_scripted { scp.upload!(io, "/path/to/remote.txt", :mode => 0666) }
  end

  def test_upload_directory_without_recursive_should_error
    prepare_directory("/path/to/local")

    expect_scp_session("-t /path/to/remote") do |channel|
      channel.gets_ok
    end

    Net::SSH::Test::Extensions::IO.with_test_extension do
      assert_raises(Net::SCP::Error) { scp.upload!("/path/to/local", "/path/to/remote") }
    end
  end

  def test_upload_empty_directory_should_create_directory_and_finish
    prepare_directory("/path/to/local")

    expect_scp_session("-t -r /path/to/remote") do |channel|
      channel.gets_ok
      channel.sends_data "D0777 0 local\n"
      channel.gets_ok
      channel.sends_data "E\n"
      channel.gets_ok
    end

    assert_scripted { scp.upload!("/path/to/local", "/path/to/remote", :recursive => true) }
  end

  def test_upload_directory_should_recursively_create_and_upload_items
    prepare_directory("/path/to/local") do |d|
      d.file "hello.txt", "hello world\n"
      d.directory "others" do |d2|
        d2.file "data.dat", "abcdefghijklmnopqrstuvwxyz"
      end
      d.file "zoo.doc", "going to the zoo\n"
    end

    expect_scp_session("-t -r /path/to/remote") do |channel|
      channel.gets_ok
      channel.sends_data "D0777 0 local\n"
      channel.gets_ok
      channel.sends_data "C0666 12 hello.txt\n"
      channel.gets_ok
      channel.sends_data "hello world\n"
      channel.sends_ok
      channel.gets_ok
      channel.sends_data "D0777 0 others\n"
      channel.gets_ok
      channel.sends_data "C0666 26 data.dat\n"
      channel.gets_ok
      channel.sends_data "abcdefghijklmnopqrstuvwxyz"
      channel.sends_ok
      channel.gets_ok
      channel.sends_data "E\n"
      channel.gets_ok
      channel.sends_data "C0666 17 zoo.doc\n"
      channel.gets_ok
      channel.sends_data "going to the zoo\n"
      channel.sends_ok
      channel.gets_ok
      channel.sends_data "E\n"
      channel.gets_ok
    end

    assert_scripted { scp.upload!("/path/to/local", "/path/to/remote", :recursive => true) }
  end

  def test_upload_directory_with_preserve_should_send_times_for_all_items
    prepare_directory("/path/to/local", 0755, Time.at(17171717, 191919), Time.at(18181818, 101010)) do |d|
      d.file "hello.txt", "hello world\n", 0640, Time.at(12345, 67890), Time.at(234567, 890)
      d.directory "others", 0770, Time.at(112233, 4455), Time.at(22334455, 667788) do |d2|
        d2.file "data.dat", "abcdefghijklmnopqrstuvwxyz", 0600, Time.at(13579135, 13131), Time.at(7654321, 654321)
      end
      d.file "zoo.doc", "going to the zoo\n", 0444, Time.at(12121212, 131313), Time.at(23232323, 242424)
    end

    expect_scp_session("-t -r -p /path/to/remote") do |channel|
      channel.gets_ok
      channel.sends_data "T17171717 191919 18181818 101010\n"
      channel.gets_ok
      channel.sends_data "D0755 0 local\n"
      channel.gets_ok
      channel.sends_data "T12345 67890 234567 890\n"
      channel.gets_ok
      channel.sends_data "C0640 12 hello.txt\n"
      channel.gets_ok
      channel.sends_data "hello world\n"
      channel.sends_ok
      channel.gets_ok
      channel.sends_data "T112233 4455 22334455 667788\n"
      channel.gets_ok
      channel.sends_data "D0770 0 others\n"
      channel.gets_ok
      channel.sends_data "T13579135 13131 7654321 654321\n"
      channel.gets_ok
      channel.sends_data "C0600 26 data.dat\n"
      channel.gets_ok
      channel.sends_data "abcdefghijklmnopqrstuvwxyz"
      channel.sends_ok
      channel.gets_ok
      channel.sends_data "E\n"
      channel.gets_ok
      channel.sends_data "T12121212 131313 23232323 242424\n"
      channel.gets_ok
      channel.sends_data "C0444 17 zoo.doc\n"
      channel.gets_ok
      channel.sends_data "going to the zoo\n"
      channel.sends_ok
      channel.gets_ok
      channel.sends_data "E\n"
      channel.gets_ok
    end

    assert_scripted { scp.upload!("/path/to/local", "/path/to/remote", :preserve => true, :recursive => true) }
  end

  def test_upload_should_not_block
    prepare_file("/path/to/local.txt", "data")
    story { |s| s.opens_channel(false) }
    assert_scripted { scp.upload("/path/to/local.txt", "/path/to/remote.txt") }
  end

  def test_upload_should_raise_error_if_gets_not_ok
    prepare_file("/path/to/local.txt", "")

    expect_scp_session "-t /path/to/remote.txt" do |channel|
      channel.gets_data "\1"
    end

    Net::SSH::Test::Extensions::IO.with_test_extension do
      e = assert_raises(Net::SCP::Error) { scp.upload!("/path/to/local.txt", "/path/to/remote.txt") }
      assert_equal("\1", e.message)
    end
  end

  def test_upload_pathname_should_read_file_once
    Dir.mktmpdir do |dir|
      path = File.join(dir, "local.txt")
      File.binwrite(path, "abcdef")
      File.chmod(0o644, path)

      expect_scp_session "-t /path/to/remote.txt" do |channel|
        channel.gets_ok
        channel.sends_data "C0644 6 local.txt\n"
        channel.gets_ok
        channel.sends_data "abc"
        channel.sends_data "def"
        channel.sends_ok
        channel.gets_ok
      end

      Timeout.timeout(5) do
        assert_scripted { scp.upload!(Pathname.new(path), "/path/to/remote.txt", chunk_size: 3) }
      end
    end
  end

  def test_upload_file_object_should_be_used_as_io
    Dir.mktmpdir do |dir|
      path = File.join(dir, "local.txt")
      File.binwrite(path, "abcdef")
      File.chmod(0o644, path)

      expect_scp_session "-t /path/to/remote.txt" do |channel|
        channel.gets_ok
        channel.sends_data "C0644 6 remote.txt\n"
        channel.gets_ok
        channel.sends_data "abc"
        channel.sends_data "def"
        channel.sends_ok
        channel.gets_ok
      end

      File.open(path, "rb") do |file|
        file.expects(:to_path).never
        Timeout.timeout(5) do
          assert_scripted { scp.upload!(file, "/path/to/remote.txt", chunk_size: 3) }
        end
        assert !file.closed?
      end
    end
  end

  def test_upload_should_close_local_file_when_remote_exits_with_error
    prepare_file('/path/to/local.txt', 'a' * 1234)
    io = StringIO.new('a' * 1234)
    File.stubs(:open).with('/path/to/local.txt', 'rb').returns(io)

    story do |session|
      channel = session.opens_channel
      channel.sends_exec 'scp -t /path/to/remote.txt'
      channel.gets_ok
      channel.sends_data "C0666 1234 local.txt\n"
      channel.gets_exit_status(1)
      channel.gets_close
      channel.sends_eof
      channel.sends_close
    end

    assert_raises(Net::SCP::Error) do
      assert_scripted { scp.upload!('/path/to/local.txt', '/path/to/remote.txt') }
    end
    assert io.closed?
  end

  def test_upload_should_not_close_caller_io_when_remote_exits_with_error
    io = StringIO.new('a' * 1234)

    story do |session|
      channel = session.opens_channel
      channel.sends_exec 'scp -t /path/to/remote.txt'
      channel.gets_ok
      channel.sends_data "C0640 1234 remote.txt\n"
      channel.gets_exit_status(1)
      channel.gets_close
      channel.sends_eof
      channel.sends_close
    end

    assert_raises(Net::SCP::Error) do
      assert_scripted { scp.upload!(io, '/path/to/remote.txt') }
    end
    assert !io.closed?
  end

  def test_upload_should_raise_error_when_remote_exits_zero_before_final_ack
    prepare_file("/path/to/local.txt", "a" * 1234)

    story do |session|
      channel = session.opens_channel
      channel.sends_exec "scp -t /path/to/remote.txt"
      channel.gets_ok
      channel.sends_data "C0666 1234 local.txt\n"
      channel.gets_ok
      channel.sends_data "a" * 1234
      channel.sends_ok
      channel.gets_exit_status(0)
      channel.gets_eof
      channel.gets_close
      channel.sends_close
    end

    Net::SSH::Test::Extensions::IO.with_test_extension do
      e = assert_raises(Net::SCP::Error) { scp.upload!("/path/to/local.txt", "/path/to/remote.txt") }
      assert_equal "SCP did not finish successfully (channel closed before end of transmission)", e.message
    end
  end

  def test_upload_should_work_when_remote_closes_channel_without_exit_status
    prepare_file("/path/to/local.txt", "a" * 1234)

    story do |session|
      channel = session.opens_channel
      channel.sends_exec "scp -t /path/to/remote.txt"
      channel.gets_ok
      channel.sends_data "C0666 1234 local.txt\n"
      channel.gets_ok
      channel.sends_data "a" * 1234
      channel.sends_ok
      channel.gets_ok
      channel.sends_eof
      channel.gets_close
      channel.sends_close
    end

    assert_scripted { scp.upload!("/path/to/local.txt", "/path/to/remote.txt") }
  end

  def test_upload_should_succeed_when_final_ack_and_close_arrive_together
    prepare_file("/path/to/local.txt", "a" * 1234)

    story do |session|
      channel = session.opens_channel
      channel.sends_exec "scp -t /path/to/remote.txt"
      channel.gets_ok
      channel.sends_data "C0666 1234 local.txt\n"
      channel.gets_ok
      channel.sends_data "a" * 1234
      channel.sends_ok
      channel.gets_ok
      channel.gets_exit_status(0)
      channel.gets_eof
      channel.gets_close
      channel.sends_eof
      channel.sends_close
    end

    deliver_remote_packets_together!
    assert_scripted { scp.upload!("/path/to/local.txt", "/path/to/remote.txt") }
  end

  def test_upload_should_reject_invalid_chunk_size_before_opening_channel
    [0, -1, 1.5, "10", Object.new].each do |chunk_size|
      session = stub(logger: nil)
      session.expects(:open_channel).never
      error = assert_raises(ArgumentError) do
        Net::SCP.new(session).upload(StringIO.new("abc"), "/path/to/remote.txt", chunk_size: chunk_size)
      end
      assert_equal ":chunk_size must be a positive Integer", error.message
    end
  end

  [nil, false, :unset].each do |chunk_size|
    define_method("test_upload_with_#{chunk_size.inspect.delete(':')}_chunk_size_should_use_default_chunk_size") do
      data = "a" * (Net::SCP::Upload::DEFAULT_CHUNK_SIZE + 1)

      expect_scp_session "-t /path/to/remote.txt" do |channel|
        channel.gets_ok
        channel.sends_data "C0640 #{data.bytesize} remote.txt\n"
        channel.gets_ok
        channel.sends_data "a" * Net::SCP::Upload::DEFAULT_CHUNK_SIZE
        channel.sends_data "a"
        channel.sends_ok
        channel.gets_ok
      end

      options = chunk_size == :unset ? {} : { chunk_size: chunk_size }
      assert_scripted { scp.upload!(StringIO.new(data), "/path/to/remote.txt", options) }
    end
  end

  def test_upload_with_custom_chunk_size_should_send_chunks_of_that_size
    expect_scp_session "-t /path/to/remote.txt" do |channel|
      channel.gets_ok
      channel.sends_data "C0640 5 remote.txt\n"
      channel.gets_ok
      channel.sends_data "ab"
      channel.sends_data "cd"
      channel.sends_data "e"
      channel.sends_ok
      channel.gets_ok
    end

    assert_scripted { scp.upload!(StringIO.new("abcde"), "/path/to/remote.txt", chunk_size: 2) }
  end

  def test_upload_directory_should_skip_broken_symlink_and_raise_after_sending_the_rest
    with_local_tree("a.txt" => "a\n", "b-broken" => :broken, "c.txt" => "c\n") do |local|
      expect_scp_session("-t -r /path/to/remote") do |channel|
        channel.gets_ok
        channel.sends_data "D0755 0 local\n"
        channel.gets_ok
        expect_file_upload(channel, "a.txt", "a\n")
        expect_file_upload(channel, "c.txt", "c\n")
        channel.sends_data "E\n"
        channel.gets_ok
      end

      e = assert_scripted_upload_error(local)
      assert_equal "upload incomplete, skipped broken symlinks: #{File.join(local, 'b-broken').inspect}", e.message
      assert_match(/WARN.*#{Regexp.escape(File.join(local, 'b-broken'))}: broken symlink, skipping/, @log.string)
    end
  end

  def test_upload_directory_should_list_every_skipped_broken_symlink
    with_local_tree("a-broken" => :broken, "b.txt" => "b\n", "sub" => { "c-broken" => :broken }) do |local|
      expect_scp_session("-t -r /path/to/remote") do |channel|
        channel.gets_ok
        channel.sends_data "D0755 0 local\n"
        channel.gets_ok
        expect_file_upload(channel, "b.txt", "b\n")
        channel.sends_data "D0755 0 sub\n"
        channel.gets_ok
        channel.sends_data "E\n"
        channel.gets_ok
        channel.sends_data "E\n"
        channel.gets_ok
      end

      e = assert_scripted_upload_error(local)
      skipped = [File.join(local, "a-broken"), File.join(local, "sub", "c-broken")]
      assert_equal "upload incomplete, skipped broken symlinks: #{skipped.map(&:inspect).join(', ')}", e.message
    end
  end

  def test_upload_directory_should_follow_valid_symlinks
    with_local_tree("dir" => { "x.txt" => "x\n" }, "dir-link" => [:symlink, "dir"], "file-link" => [:symlink, "file.txt"], "file.txt" => "f\n") do |local|
      expect_scp_session("-t -r /path/to/remote") do |channel|
        channel.gets_ok
        channel.sends_data "D0755 0 local\n"
        channel.gets_ok
        %w[dir dir-link].each do |name|
          channel.sends_data "D0755 0 #{name}\n"
          channel.gets_ok
          expect_file_upload(channel, "x.txt", "x\n")
          channel.sends_data "E\n"
          channel.gets_ok
        end
        expect_file_upload(channel, "file-link", "f\n")
        expect_file_upload(channel, "file.txt", "f\n")
        channel.sends_data "E\n"
        channel.gets_ok
      end

      assert_scripted { upload_recursively(local) }
      assert_empty @log.string
    end
  end

  def test_upload_directory_without_broken_symlinks_should_not_warn
    with_local_tree("a.txt" => "a\n") do |local|
      expect_scp_session("-t -r /path/to/remote") do |channel|
        channel.gets_ok
        channel.sends_data "D0755 0 local\n"
        channel.gets_ok
        expect_file_upload(channel, "a.txt", "a\n")
        channel.sends_data "E\n"
        channel.gets_ok
      end

      assert_scripted { upload_recursively(local) }
      assert_empty @log.string
    end
  end

  private

  def with_local_tree(entries)
    Dir.mktmpdir("net-scp-test") do |tmp|
      local = File.join(File.realpath(tmp), "local")
      build_local_tree(local, entries)
      @log = StringIO.new
      yield local
    end
  end

  def build_local_tree(dir, entries)
    Dir.mkdir(dir)
    File.chmod(0o755, dir)
    entries.each do |name, value|
      path = File.join(dir, name)
      case value
      when String
        File.binwrite(path, value)
        File.chmod(0o644, path)
      when Hash then build_local_tree(path, value)
      when Array then File.symlink(value.last, path)
      when :broken then File.symlink(File.join(dir, "missing-#{name}"), path)
      end
    end
    Dir.stubs(:entries).with { |path| File.realpath(path) == dir }.returns(%w[. ..] + entries.keys.sort)
  end

  def expect_file_upload(channel, name, contents)
    channel.sends_data "C0644 #{contents.bytesize} #{name}\n"
    channel.gets_ok
    channel.sends_data contents
    channel.sends_ok
    channel.gets_ok
  end

  def upload_recursively(local)
    scp.logger = Logger.new(@log)
    scp.upload!(local, "/path/to/remote", recursive: true)
  end

  def assert_scripted_upload_error(local)
    error = Net::SSH::Test::Extensions::IO.with_test_extension do
      assert_raises(Net::SCP::Error) { upload_recursively(local) }
    end
    assert_scripted { scp.session.process(0) }
    error
  end
end
