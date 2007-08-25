$LOAD_PATH.unshift "#{File.dirname(__FILE__)}/../lib"

require 'net/scp'
require 'net/ssh/test'
require 'test/unit'
require 'mocha'

class Net::SSH::Test::Channel
  def gets_ok
    gets_data "\0"
  end

  def sends_ok
    sends_data "\0"
  end
end

class TestSCP < Test::Unit::TestCase
  include Net::SSH::Test

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

    assert_script { scp.upload!("/path/to/local.txt", "/path/to/remote.txt") }
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

    assert_script { scp.upload!("/path/to/local.txt", "/path/to/remote.txt", :preserve => true) }
  end

  def test_upload_file_with_progress_callback_should_invoke_callback
    flunk
  end

  def test_upload_io_with_recursive_should_error
    flunk
  end

  def test_upload_io_with_preserve_should_error
    flunk
  end

  def test_upload_io_should_transfer_data
    flunk
  end

  def test_upload_io_with_mode_should_honor_mode_as_permissions
    flunk
  end

  def test_upload_directory_without_recursive_should_error
    flunk
  end

  def test_upload_empty_directory_should_create_directory_and_finish
    flunk
  end

  def test_upload_directory_should_recursively_create_and_upload_items
    flunk
  end

  def test_upload_directory_with_reserve_should_send_times_for_all_items
    flunk
  end

  private

    def prepare_file(path, contents, mode=0666, mtime=Time.now, atime=Time.now)
      stat = stub("file::stat", :size => contents.length, :mode => mode, :mtime => mtime, :atime => atime, :directory? => false)

      file = StringIO.new(contents)

      File.stubs(:stat).with(path).returns(stat)
      File.stubs(:directory?).with(path).returns(false)
      File.stubs(:file?).with(path).returns(true)
      File.stubs(:open).with(path, "rb").returns(file)
    end

    def expect_scp_session(arguments)
      story do |session|
        channel = session.opens_channel
        channel.sends_exec "scp #{arguments}"
        yield channel
        channel.sends_eof
        channel.gets_exit_status
        channel.gets_eof
        channel.gets_close
        channel.sends_close
      end
    end

    def scp(options={})
      @scp ||= Net::SCP.new(connection(options))
    end
end
