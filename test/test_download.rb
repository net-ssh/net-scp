require 'common'
require 'pathname'
require 'tmpdir'
require 'timeout'

class TestDownload < Net::SCP::TestCase
  def test_download_file_should_transfer_file
    file = prepare_file("/path/to/local.txt", "a" * 1234)

    expect_scp_session "-f /path/to/remote.txt" do |channel|
      simple_download(channel)
    end

    assert_scripted { scp.download!("/path/to/remote.txt", "/path/to/local.txt") }
    assert_equal "a" * 1234, file.io.string
  end

  def test_download_file_with_spaces_in_name_should_escape_remote_file_name
    _file = prepare_file("/path/to/local file.txt", "")

    expect_scp_session "-f /path/to/remote\\ file.txt" do |channel|
      channel.sends_ok
      channel.gets_data "C0666 0 local file.txt\n"
      channel.sends_ok
      channel.gets_ok
      channel.sends_ok
    end

    assert_scripted { scp.download!("/path/to/remote file.txt", "/path/to/local file.txt") }
  end

  def test_download_file_with_metacharacters_in_name_should_escape_remote_file_name
    _file = prepare_file("/path/to/local/#{awful_file_name}", "")

    expect_scp_session "-f /path/to/remote/#{escaped_file_name}" do |channel|
      channel.sends_ok
      channel.gets_data "C0666 0 #{awful_file_name}\n"
      channel.sends_ok
      channel.gets_ok
      channel.sends_ok
    end

    assert_scripted { scp.download!("/path/to/remote/#{awful_file_name}", "/path/to/local/#{awful_file_name}") }
  end

  def test_download_with_preserve_should_send_times
    file = prepare_file("/path/to/local.txt", "a" * 1234, 0644, Time.at(1234567890, 123456), Time.at(12121212, 232323))

    expect_scp_session "-f -p /path/to/remote.txt" do |channel|
      channel.sends_ok
      channel.gets_data "T1234567890 123456 12121212 232323\n"
      simple_download(channel, 0644)
    end

    File.expects(:utime).with(Time.at(12121212, 232323), Time.at(1234567890, 123456), "/path/to/local.txt")
    assert_scripted { scp.download!("/path/to/remote.txt", "/path/to/local.txt", :preserve => true) }
    assert_equal "a" * 1234, file.io.string
  end

  def test_download_with_error_should_respond_with_error_text
    story do |session|
      channel = session.opens_channel
      channel.sends_exec "scp -f /path/to/remote.txt"

      channel.sends_ok
      channel.gets_data "\x01File not found: /path/to/remote.txt\n"
      channel.sends_ok

      channel.gets_eof
      channel.gets_exit_status(1)
      channel.gets_close
      channel.sends_close
    end

    error = nil
    Net::SSH::Test::Extensions::IO.with_test_extension do
    begin
      scp.download!("/path/to/remote.txt")
    rescue
      error = $!
    end
    end
    assert_equal Net::SCP::Error, error.class
    assert_equal "SCP did not finish successfully (1): File not found: /path/to/remote.txt\n", error.message
  end

  def test_download_with_progress_callback_should_invoke_callback
    prepare_file("/path/to/local.txt", "a" * 3000 + "b" * 3000 + "c" * 3000 + "d" * 3000)

    expect_scp_session "-f /path/to/remote.txt" do |channel|
      channel.sends_ok
      channel.gets_data "C0666 12000 remote.txt\n"
      channel.sends_ok
      channel.gets_data "a" * 3000
      channel.inject_remote_delay!
      channel.gets_data "b" * 3000
      channel.inject_remote_delay!
      channel.gets_data "c" * 3000
      channel.inject_remote_delay!
      channel.gets_data "d" * 3000
      channel.gets_ok
      channel.sends_ok
    end

    calls = []
    progress = Proc.new { |ch, *args| calls << args }

    assert_scripted do
      scp.download!("/path/to/remote.txt", "/path/to/local.txt", &progress)
    end

    assert_equal ["/path/to/local.txt",     0, 12000], calls.shift
    assert_equal ["/path/to/local.txt",  3000, 12000], calls.shift
    assert_equal ["/path/to/local.txt",  6000, 12000], calls.shift
    assert_equal ["/path/to/local.txt",  9000, 12000], calls.shift
    assert_equal ["/path/to/local.txt", 12000, 12000], calls.shift
    assert calls.empty?
  end

  def test_download_io_with_recursive_should_raise_error
    expect_scp_session "-f -r /path/to/remote.txt"
    Net::SSH::Test::Extensions::IO.with_test_extension do
      assert_raises(Net::SCP::Error) { scp.download!("/path/to/remote.txt", StringIO.new, :recursive => true) }
    end
  end

  def test_download_io_with_preserve_should_ignore_preserve
    expect_scp_session "-f -p /path/to/remote.txt" do |channel|
      simple_download(channel)
    end

    io = StringIO.new
    assert_scripted { scp.download!("/path/to/remote.txt", io, :preserve => true) }
    assert_equal "a" * 1234, io.string
  end

  def test_download_io_should_transfer_data
    expect_scp_session "-f /path/to/remote.txt" do |channel|
      simple_download(channel)
    end

    io = StringIO.new
    assert_scripted { scp.download!("/path/to/remote.txt", io) }
    assert_equal "a" * 1234, io.string
  end

  def test_download_bang_without_target_should_return_string
    expect_scp_session "-f /path/to/remote.txt" do |channel|
      simple_download(channel)
    end

    assert_scripted do
      assert_equal "a" * 1234, scp.download!("/path/to/remote.txt")
    end
  end

  def test_download_directory_without_recursive_should_raise_error
    expect_scp_session "-f /path/to/remote" do |channel|
      channel.sends_ok
      channel.gets_data "D0755 0 remote\n"
    end

    Net::SSH::Test::Extensions::IO.with_test_extension do
      assert_raises(Net::SCP::Error) { scp.download!("/path/to/remote") }
    end
  end

  def test_download_should_raise_error_if_gets_not_ok
    prepare_file("/path/to/local.txt", "")

    expect_scp_session "-f /path/to/remote.txt" do |channel|
      channel.sends_ok
      channel.gets_data "C0666 0 remote.txt\n"
      channel.sends_ok
      channel.gets_data "\1"
    end

    Net::SSH::Test::Extensions::IO.with_test_extension do
      e = assert_raises(Net::SCP::Error) { scp.download!("/path/to/remote.txt", "/path/to/local.txt") }
      assert_equal("\1", e.message)
    end
  end

  def test_download_directory_should_raise_error_if_local_exists_and_is_not_directory
    File.stubs(:exist?).with("/path/to/local").returns(true)
    File.stubs(:exist?).with("/path/to/local/remote").returns(true)
    File.stubs(:directory?).with("/path/to/local/remote").returns(false)

    expect_scp_session "-f -r /path/to/remote" do |channel|
      channel.sends_ok
      channel.gets_data "D0755 0 remote\n"
      channel.sends_ok
      channel.gets_data "E\n"
      channel.sends_ok
    end

    Net::SSH::Test::Extensions::IO.with_test_extension do
      e = assert_raises(Net::SCP::Error) { scp.download!("/path/to/remote", "/path/to/local", :recursive => true) }
      assert_match(/exists and is not a directory/, e.message)
    end
  end

  def test_download_directory_should_create_directory_and_files_locally
    file = nil
    prepare_directory "/path/to/local" do |dir|
      dir.directory "remote" do |dir2|
        dir2.directory "sub" do |dir3|
          file = dir3.file "remote.txt", ""
        end
      end
    end

    expect_scp_session "-f -r /path/to/remote" do |channel|
      channel.sends_ok
      channel.gets_data "D0755 0 remote\n"
      channel.sends_ok
      channel.gets_data "D0755 0 sub\n"
      simple_download(channel)
      channel.gets_data "E\n"
      channel.sends_ok
      channel.gets_data "E\n"
      channel.sends_ok
    end

    Net::SSH::Test::Extensions::IO.with_test_extension do
      scp.download!("/path/to/remote", "/path/to/local", :recursive => true, :ssh => { :verbose => :debug })
    end
    assert_equal "a" * 1234, file.io.string
  end

  def test_download_should_work_when_remote_closes_channel_without_exit_status
    file = prepare_file('/path/to/local.txt', 'a' * 1234)

    story do |session|
      channel = session.opens_channel
      channel.sends_exec 'scp -f /path/to/remote.txt'
      simple_download(channel)
      # Remote closes without sending an exit-status
      channel.gets_close
      # We just send eof and close the channel
      channel.sends_eof
      channel.sends_close
    end

    assert_scripted { scp.download!('/path/to/remote.txt', '/path/to/local.txt') }
    assert_equal 'a' * 1234, file.io.string
  end

  def test_download_should_raise_error_when_remote_closes_channel_before_end
    prepare_file('/path/to/local.txt', 'a' * 1234)

    story do |session|
      channel = session.opens_channel
      channel.sends_exec 'scp -f /path/to/remote.txt'
      channel.sends_ok
      channel.gets_data "C0666 1234 remote.txt\n"
      channel.sends_ok
      channel.gets_data 'a' * 500
      # We should have received 1234 bytes and \0 but remote closed before the end
      channel.gets_close
      # We just send eof and close the channel
      channel.sends_eof
      channel.sends_close
    end

    error = nil
    begin
      assert_scripted { scp.download!('/path/to/remote.txt', '/path/to/local.txt') }
    rescue => e
      error = e
    end

    assert_equal Net::SCP::Error, error.class
    assert_equal 'SCP did not finish successfully (channel closed before end of transmission)', error.message
  end

  def test_download_file_into_directory_should_use_remote_name
    file = nil
    prepare_directory "/path/to/local" do |dir|
      file = dir.file "remote.txt", ""
    end

    expect_scp_session "-f /path/to/remote.txt" do |channel|
      simple_download(channel)
    end

    assert_scripted { scp.download!("/path/to/remote.txt", "/path/to/local") }
    assert_equal "a" * 1234, file.io.string
  end

  UNSAFE_NAMES = {
    "parent_relative" => "../x",
    "nested" => "a/b",
    "absolute" => "/abs",
    "parent" => "..",
    "current" => ".",
    "empty" => "",
    "nul" => "a\0b"
  }

  UNSAFE_NAMES.each do |label, name|
    define_method("test_recursive_download_should_reject_#{label}_file_name") do
      assert_rejects_name("-f -r /path/to/remote", "C0644 3 #{name}\n", :recursive => true)
    end

    define_method("test_recursive_download_should_reject_#{label}_directory_name") do
      assert_rejects_name("-f -r /path/to/remote", "D0755 0 #{name}\n", :recursive => true)
    end

    define_method("test_download_into_directory_should_reject_#{label}_file_name") do
      assert_rejects_name("-f /path/to/remote", "C0644 3 #{name}\n")
    end
  end

  def test_download_into_pathname_should_write_all_chunks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "local.txt")

      expect_scp_session "-f /path/to/remote.txt" do |channel|
        chunked_download(channel)
      end

      Timeout.timeout(5) do
        assert_scripted { scp.download!("/path/to/remote.txt", Pathname.new(path)) }
      end
      assert_equal "abcdef", File.binread(path)
    end
  end

  def test_download_into_file_object_should_be_used_as_io
    Dir.mktmpdir do |dir|
      path = File.join(dir, "local.txt")

      expect_scp_session "-f /path/to/remote.txt" do |channel|
        chunked_download(channel)
      end

      File.open(path, "wb") do |file|
        file.expects(:to_path).never
        Timeout.timeout(5) do
          assert_scripted { scp.download!("/path/to/remote.txt", file) }
        end
        assert !file.closed?
      end
      assert_equal "abcdef", File.binread(path)
    end
  end

  def test_download_should_close_local_file_when_remote_exits_with_error
    file = prepare_file('/path/to/local.txt', 'a' * 1234)

    story do |session|
      channel = session.opens_channel
      channel.sends_exec 'scp -f /path/to/remote.txt'
      channel.sends_ok
      channel.gets_data "C0666 1234 remote.txt\n"
      channel.sends_ok
      channel.gets_data 'a' * 500
      channel.gets_exit_status(1)
      channel.gets_close
      channel.sends_eof
      channel.sends_close
    end

    assert_raises(Net::SCP::Error) do
      assert_scripted { scp.download!('/path/to/remote.txt', '/path/to/local.txt') }
    end
    assert file.io.closed?
  end

  def test_download_should_not_close_caller_io_when_remote_exits_with_error
    story do |session|
      channel = session.opens_channel
      channel.sends_exec 'scp -f /path/to/remote.txt'
      channel.sends_ok
      channel.gets_data "C0666 1234 remote.txt\n"
      channel.sends_ok
      channel.gets_data 'a' * 500
      channel.gets_exit_status(1)
      channel.gets_close
      channel.sends_eof
      channel.sends_close
    end

    io = StringIO.new
    assert_raises(Net::SCP::Error) do
      assert_scripted { scp.download!('/path/to/remote.txt', io) }
    end
    assert !io.closed?
    assert_equal 'a' * 500, io.string
  end

  def test_download_should_raise_error_when_remote_exits_zero_before_end
    prepare_file('/path/to/local.txt', 'a' * 1234)

    story do |session|
      channel = session.opens_channel
      channel.sends_exec 'scp -f /path/to/remote.txt'
      channel.sends_ok
      channel.gets_data "C0666 1234 remote.txt\n"
      channel.sends_ok
      channel.gets_data 'a' * 500
      channel.gets_exit_status(0)
      channel.gets_eof
      channel.gets_close
      channel.sends_eof
      channel.sends_close
    end

    Net::SSH::Test::Extensions::IO.with_test_extension do
      e = assert_raises(Net::SCP::Error) { scp.download!('/path/to/remote.txt', '/path/to/local.txt') }
      assert_equal 'SCP did not finish successfully (channel closed before end of transmission)', e.message
    end
  end

  def test_download_should_succeed_when_last_data_and_close_arrive_together
    file = prepare_file('/path/to/local.txt', 'a' * 1234)

    story do |session|
      channel = session.opens_channel
      channel.sends_exec 'scp -f /path/to/remote.txt'
      channel.sends_ok
      channel.gets_data "C0666 1234 remote.txt\n"
      channel.sends_ok
      channel.gets_data 'a' * 1234
      channel.gets_ok
      channel.gets_exit_status(0)
      channel.gets_eof
      channel.gets_close
      channel.sends_ok
      channel.sends_eof
      channel.sends_close
    end

    deliver_remote_packets_together!
    assert_scripted { scp.download!('/path/to/remote.txt', '/path/to/local.txt') }
    assert_equal 'a' * 1234, file.io.string
  end

  { 04755 => 0755, 02755 => 0755, 01777 => 0777, 06777 => 0777, 0644 => 0644, 0444 => 0644 }.each do |sent, expected|
    define_method("test_download_file_should_create_mode_%04o_as_%04o" % [sent, expected]) do
      io = StringIO.new
      File.stubs(:directory?).with("/path/to/local.txt").returns(false)
      File.expects(:new).with("/path/to/local.txt", "wb", expected).returns(io)

      expect_scp_session "-f /path/to/remote.txt" do |channel|
        simple_download(channel, sent)
      end

      assert_scripted { scp.download!("/path/to/remote.txt", "/path/to/local.txt") }
      assert_equal "a" * 1234, io.string
    end
  end

  def test_download_with_preserve_should_still_strip_special_mode_bits
    io = StringIO.new
    File.stubs(:directory?).with("/path/to/local.txt").returns(false)
    File.expects(:new).with("/path/to/local.txt", "wb", 0755).returns(io)

    expect_scp_session "-f -p /path/to/remote.txt" do |channel|
      simple_download(channel, 06755)
    end

    assert_scripted { scp.download!("/path/to/remote.txt", "/path/to/local.txt", :preserve => true) }
  end

  { 04755 => 0755, 01777 => 0777, 0750 => 0750, 0500 => 0700 }.each do |sent, expected|
    define_method("test_download_directory_should_create_mode_%04o_as_%04o" % [sent, expected]) do
      Dir.expects(:mkdir).with("/path/to/local")
      Dir.expects(:mkdir).with("/path/to/local/remote", expected)

      expect_scp_session "-f -r /path/to/remote" do |channel|
        channel.sends_ok
        channel.gets_data "D%04o 0 remote\n" % sent
        channel.sends_ok
        channel.gets_data "E\n"
        channel.sends_ok
      end

      assert_scripted { scp.download!("/path/to/remote", "/path/to/local", :recursive => true) }
    end
  end

  def test_download_into_directory_should_reject_name_not_matching_request
    assert_rejects_unrequested_name("-f /path/to/remote.txt", "/path/to/remote.txt", "C0644 3 .bashrc\n")
  end

  def test_download_into_directory_should_reject_name_not_matching_glob
    assert_rejects_unrequested_name("-f /path/to/\\*.txt", "/path/to/*.txt", "C0644 3 remote.sh\n")
  end

  def test_recursive_download_should_reject_top_level_name_not_matching_request
    assert_rejects_unrequested_name("-f -r /path/to/remote", "/path/to/remote", "D0700 0 .ssh\n", :recursive => true)
  end

  def test_recursive_download_should_reject_top_level_file_not_matching_request
    assert_rejects_unrequested_name("-f -r /path/to/remote", "/path/to/remote", "C0644 3 .bashrc\n", :recursive => true)
  end

  {
    "glob" => ["/path/to/*.txt", "/path/to/\\*.txt", "remote.txt"],
    "glob_with_leading_dot" => ["/path/to/*", "/path/to/\\*", ".profile"],
    "brace" => ["/path/to/{a,remote}.txt", "/path/to/\\{a,remote\\}.txt", "remote.txt"],
    "literal_brackets" => ["/path/to/remote[1].txt", "/path/to/remote\\[1\\].txt", "remote[1].txt"],
    "trailing_slash" => ["/path/to/remote.txt/", "/path/to/remote.txt/", "remote.txt"]
  }.each do |label, (remote, escaped, name)|
    define_method("test_download_into_directory_should_accept_#{label}_match") do
      file = nil
      prepare_directory "/path/to/local" do |dir|
        file = dir.file name, ""
      end

      expect_scp_session "-f #{escaped}" do |channel|
        simple_download(channel, 0666, name)
      end

      assert_scripted { scp.download!(remote, "/path/to/local") }
      assert_equal "a" * 1234, file.io.string
    end
  end

  def test_download_into_directory_should_refuse_to_follow_symlink_at_server_named_path
    omit "File::NOFOLLOW not supported" unless defined?(File::NOFOLLOW)
    with_tmpdir do |tmp|
      Dir.mkdir("#{tmp}/local")
      File.write("#{tmp}/victim", "original")
      File.symlink("#{tmp}/victim", "#{tmp}/local/remote.txt")

      expect_scp_session "-f /path/to/remote.txt" do |channel|
        channel.sends_ok
        channel.gets_data "C0644 3 remote.txt\n"
      end

      Net::SSH::Test::Extensions::IO.with_test_extension do
        e = assert_raises(Net::SCP::Error) { scp.download!("/path/to/remote.txt", "#{tmp}/local") }
        assert_match(/symlink/, e.message)
      end
      assert_equal "original", File.read("#{tmp}/victim")
    end
  end

  def test_recursive_download_should_refuse_to_follow_symlink_at_server_named_file
    omit "File::NOFOLLOW not supported" unless defined?(File::NOFOLLOW)
    with_tmpdir do |tmp|
      Dir.mkdir("#{tmp}/local")
      Dir.mkdir("#{tmp}/local/remote")
      File.write("#{tmp}/victim", "original")
      File.symlink("#{tmp}/victim", "#{tmp}/local/remote/file.txt")

      expect_scp_session "-f -r /path/to/remote" do |channel|
        channel.sends_ok
        channel.gets_data "D0755 0 remote\n"
        channel.sends_ok
        channel.gets_data "C0644 3 file.txt\n"
      end

      Net::SSH::Test::Extensions::IO.with_test_extension do
        e = assert_raises(Net::SCP::Error) { scp.download!("/path/to/remote", "#{tmp}/local", :recursive => true) }
        assert_match(/symlink/, e.message)
      end
      assert_equal "original", File.read("#{tmp}/victim")
    end
  end

  def test_recursive_download_should_refuse_to_descend_into_symlinked_directory
    with_tmpdir do |tmp|
      Dir.mkdir("#{tmp}/local")
      Dir.mkdir("#{tmp}/outside")
      File.symlink("#{tmp}/outside", "#{tmp}/local/remote")

      expect_scp_session "-f -r /path/to/remote" do |channel|
        channel.sends_ok
        channel.gets_data "D0755 0 remote\n"
      end

      Net::SSH::Test::Extensions::IO.with_test_extension do
        e = assert_raises(Net::SCP::Error) { scp.download!("/path/to/remote", "#{tmp}/local", :recursive => true) }
        assert_match(/symlink/, e.message)
      end
      assert_equal [], Dir.children("#{tmp}/outside")
    end
  end

  def test_download_to_symlinked_file_given_by_caller_should_write_through_it
    with_tmpdir do |tmp|
      File.write("#{tmp}/target.txt", "")
      File.symlink("#{tmp}/target.txt", "#{tmp}/link.txt")

      expect_scp_session "-f /path/to/remote.txt" do |channel|
        simple_download(channel)
      end

      assert_scripted { scp.download!("/path/to/remote.txt", "#{tmp}/link.txt") }
      assert_equal "a" * 1234, File.read("#{tmp}/target.txt")
    end
  end

  def test_download_into_symlinked_directory_given_by_caller_should_write_through_it
    with_tmpdir do |tmp|
      Dir.mkdir("#{tmp}/target")
      File.symlink("#{tmp}/target", "#{tmp}/link")

      expect_scp_session "-f /path/to/remote.txt" do |channel|
        simple_download(channel)
      end

      assert_scripted { scp.download!("/path/to/remote.txt", "#{tmp}/link") }
      assert_equal "a" * 1234, File.read("#{tmp}/target/remote.txt")
    end
  end

  def test_recursive_download_into_symlinked_directory_given_by_caller_should_write_through_it
    with_tmpdir do |tmp|
      Dir.mkdir("#{tmp}/target")
      File.symlink("#{tmp}/target", "#{tmp}/link")

      expect_scp_session "-f -r /path/to/remote" do |channel|
        channel.sends_ok
        channel.gets_data "D0755 0 remote\n"
        simple_download(channel)
        channel.gets_data "E\n"
        channel.sends_ok
      end

      assert_scripted { scp.download!("/path/to/remote", "#{tmp}/link", :recursive => true) }
      assert_equal "a" * 1234, File.read("#{tmp}/target/remote/remote.txt")
    end
  end

  def test_recursive_download_with_preserve_should_keep_directory_times_after_creating_its_files
    with_tmpdir do |tmp|
      expect_scp_session "-f -r -p /path/to/remote" do |channel|
        channel.sends_ok
        channel.gets_data "T1000000000 123456 1000000010 234567\n"
        channel.sends_ok
        channel.gets_data "D0755 0 remote\n"
        channel.sends_ok
        channel.gets_data "T1100000000 0 1100000010 0\n"
        simple_download(channel, 0644)
        channel.gets_data "E\n"
        channel.sends_ok
      end

      assert_scripted { scp.download!("/path/to/remote", "#{tmp}/local", :recursive => true, :preserve => true) }
      assert_equal Time.at(1000000000, 123456), File.mtime("#{tmp}/local/remote")
      assert_equal Time.at(1000000010, 234567), File.atime("#{tmp}/local/remote")
      assert_equal Time.at(1100000000), File.mtime("#{tmp}/local/remote/remote.txt")
    end
  end

  def test_recursive_download_with_preserve_should_keep_nested_directory_times
    with_tmpdir do |tmp|
      expect_scp_session "-f -r -p /path/to/remote" do |channel|
        channel.sends_ok
        channel.gets_data "T1000000000 0 1000000010 0\n"
        channel.sends_ok
        channel.gets_data "D0755 0 remote\n"
        channel.sends_ok
        channel.gets_data "T1200000000 0 1200000010 0\n"
        channel.sends_ok
        channel.gets_data "D0755 0 sub\n"
        channel.sends_ok
        channel.gets_data "T1100000000 0 1100000010 0\n"
        simple_download(channel, 0644)
        channel.gets_data "E\n"
        channel.sends_ok
        channel.gets_data "E\n"
        channel.sends_ok
      end

      assert_scripted { scp.download!("/path/to/remote", "#{tmp}/local", :recursive => true, :preserve => true) }
      assert_equal Time.at(1000000000), File.mtime("#{tmp}/local/remote")
      assert_equal Time.at(1200000000), File.mtime("#{tmp}/local/remote/sub")
      assert_equal Time.at(1100000000), File.mtime("#{tmp}/local/remote/sub/remote.txt")
      assert_equal Time.at(1100000010), File.atime("#{tmp}/local/remote/sub/remote.txt")
    end
  end

  def test_recursive_download_without_preserve_should_not_set_directory_times
    with_tmpdir do |tmp|
      expect_scp_session "-f -r /path/to/remote" do |channel|
        channel.sends_ok
        channel.gets_data "D0755 0 remote\n"
        simple_download(channel)
        channel.gets_data "E\n"
        channel.sends_ok
      end

      File.expects(:utime).never
      assert_scripted { scp.download!("/path/to/remote", "#{tmp}/local", :recursive => true) }
      assert_equal "a" * 1234, File.read("#{tmp}/local/remote/remote.txt")
    end
  end

  private

    def with_tmpdir
      Dir.mktmpdir("net-scp-test") { |tmp| yield File.realpath(tmp) }
    end

    def assert_rejects_unrequested_name(arguments, remote, directive, options = {})
      prepare_directory "/path/to/local"
      File.expects(:new).never
      Dir.expects(:mkdir).with { |path, *| path != "/path/to/local" }.never

      expect_scp_session arguments do |channel|
        channel.sends_ok
        channel.gets_data directive
      end

      Net::SSH::Test::Extensions::IO.with_test_extension do
        e = assert_raises(Net::SCP::Error) { scp.download!(remote, "/path/to/local", options) }
        assert_match(/\Afile name from server does not match request: /, e.message)
      end
    end

    def assert_rejects_name(arguments, directive, options = {})
      prepare_directory "/path/to/local"
      File.expects(:new).never
      Dir.expects(:mkdir).with { |path, *| path != "/path/to/local" }.never

      expect_scp_session arguments do |channel|
        channel.sends_ok
        channel.gets_data directive
      end

      Net::SSH::Test::Extensions::IO.with_test_extension do
        e = assert_raises(Net::SCP::Error) { scp.download!("/path/to/remote", "/path/to/local", options) }
        assert_match(/\Ainvalid file name from server: /, e.message)
      end
    end

    def chunked_download(channel)
      channel.sends_ok
      channel.gets_data "C0644 6 remote.txt\n"
      channel.sends_ok
      channel.gets_data "abc"
      channel.inject_remote_delay!
      channel.gets_data "def"
      channel.gets_ok
      channel.sends_ok
    end

    def simple_download(channel, mode=0666, name="remote.txt")
      channel.sends_ok
      channel.gets_data "C%04o 1234 #{name}\n" % mode
      channel.sends_ok
      channel.gets_data "a" * 1234
      channel.gets_ok
      channel.sends_ok
    end
end
