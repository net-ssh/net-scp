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

    assert_scripted { scp.upload!("/path/to/local.txt", "/path/to/remote.txt") }
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
    progress = Proc.new do |name, sent, total|
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
    assert_scripted { scp.upload!(io, "/path/to/remote.txt", :preserve => true) }
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

    assert_raises(Net::SCP::Error) { scp.upload!("/path/to/local", "/path/to/remote") }
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

  private

    def prepare_file(path, contents, mode=0666, mtime=Time.now, atime=Time.now)
      entry = FileEntry.new(path, contents, mode, mtime, atime)
      entry.stub!
    end

    def prepare_directory(path, mode=0777, mtime=Time.now, atime=Time.now)
      directory = DirectoryEntry.new(path, mode, mtime, atime)
      yield directory if block_given?
      directory.stub!
    end

    class FileEntry
      attr_reader :path, :contents, :mode, :mtime, :atime

      def initialize(path, contents, mode=0666, mtime=Time.now, atime=Time.now)
        @path, @contents, @mode = path, contents, mode
        @mtime, @atime = mtime, atime
      end

      def name
        @name ||= File.basename(path)
      end

      def stub!
        stat = Mocha::Mock.new(false, "file::stat")
        stat.stubs(:size => contents.length, :mode => mode, :mtime => mtime, :atime => atime, :directory? => false)

        File.stubs(:stat).with(path).returns(stat)
        File.stubs(:directory?).with(path).returns(false)
        File.stubs(:file?).with(path).returns(true)
        File.stubs(:open).with(path, "rb").returns(StringIO.new(contents))
      end
    end

    class DirectoryEntry
      attr_reader :path, :mode, :mtime, :atime
      attr_reader :entries

      def initialize(path, mode=0777, mtime=Time.now, atime=Time.now)
        @path, @mode = path, mode
        @mtime, @atime = mtime, atime
        @entries = []
      end

      def name
        @name ||= File.basename(path)
      end

      def file(name, *args)
        entries << FileEntry.new(File.join(path, name), *args)
      end

      def directory(name, *args)
        entry = DirectoryEntry.new(File.join(path, name), *args)
        yield entry if block_given?
        entries << entry
      end

      def stub!
        stat = Mocha::Mock.new(false, "file::stat")
        stat.stubs(:size => 1024, :mode => mode, :mtime => mtime, :atime => atime, :directory? => true)

        File.stubs(:stat).with(path).returns(stat)
        File.stubs(:directory?).with(path).returns(true)
        File.stubs(:file?).with(path).returns(false)
        Dir.stubs(:entries).with(path).returns(%w(. ..) + entries.map { |e| e.name }.sort)

        entries.each { |e| e.stub! }
      end
    end

    def expect_scp_session(arguments)
      story do |session|
        channel = session.opens_channel
        channel.sends_exec "scp #{arguments}"
        yield channel if block_given?
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
