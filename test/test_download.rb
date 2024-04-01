require 'common'

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

  private

    def simple_download(channel, mode=0666)
      channel.sends_ok
      channel.gets_data "C%04o 1234 remote.txt\n" % mode
      channel.sends_ok
      channel.gets_data "a" * 1234
      channel.gets_ok
      channel.sends_ok
    end
end
