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
end
