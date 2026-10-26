require 'common'
require 'stringio'

class TestQuote < Net::SCP::TestCase
  def test_posix_is_the_default
    assert_equal "scp -t /a\\ b/c.txt", upload_command("/a b/c.txt")
    assert_equal "scp -t /a\\ b/c.txt", upload_command("/a b/c.txt", quote: :posix)
    assert_equal "scp -f /a\\ b/c.txt", download_command("/a b/c.txt")
  end

  def test_posix_escapes_shell_metacharacters
    assert_equal "scp -t /tmp/\\$HOME\\ \\`id\\`\\;\\ rm\\ \\'x\\'\\ \\\"y\\\"\\ a\\\\b",
                 upload_command("/tmp/$HOME `id`; rm 'x' \"y\" a\\b")
  end

  def test_posix_leaves_leading_home_directory_unescaped
    assert_equal "scp -t ~", upload_command("~")
    assert_equal "scp -t ~/", upload_command("~/")
    assert_equal "scp -t ~/x", upload_command("~/x")
    assert_equal "scp -f ~/my\\ dir/\\$x\\;\\ y", download_command("~/my dir/$x; y")
  end

  def test_posix_escapes_other_tildes
    assert_equal "scp -t \\~user/x", upload_command("~user/x")
    assert_equal "scp -t \\~x", upload_command("~x")
    assert_equal "scp -t /a/\\~/x", upload_command("/a/~/x")
    assert_equal "scp -t ./\\~/x", upload_command("./~/x")
  end

  def test_posix_with_shell_option
    assert_equal "bash -c 'scp -t ~/a\\ b\\'\\''c'", upload_command("~/a b'c", shell: "bash")
  end

  def test_windows_double_quotes_and_converts_backslashes
    assert_equal "scp -t \"C:/Program Files/My App/file.txt\"",
                 upload_command("C:\\Program Files\\My App\\file.txt", quote: :windows)
    assert_equal "scp -f \"C:/a b/c.txt\"", download_command("C:\\a b\\c.txt", quote: :windows)
    assert_equal "scp -t \"~\"", upload_command("~", quote: :windows)
    assert_equal "scp -t \"~/x\"", upload_command("~/x", quote: :windows)
    assert_equal "scp -t \"C:/a;b & c 'd' (e) ^f|g<h>\"", upload_command("C:\\a;b & c 'd' (e) ^f|g<h>", quote: :windows)
  end

  def test_windows_rejects_characters_a_shell_would_interpret
    ["C:/a\"b", "C:/$(calc)", "C:/a`b", "C:/%PATH%", "C:/a!b", "C:/a\rb", "C:/a\nb", "C:/a\0b",
     "C:/a\u201Cb", "C:/a\u201Db", "C:/a\u2018b", "C:/a\u2019b", "C:/a\u201Eb"].each do |path|
      assert_raises(ArgumentError, path.inspect) { upload_command(path, quote: :windows) }
      assert_raises(ArgumentError, path.inspect) { download_command(path, quote: :windows) }
    end
  end

  def test_windows_rejects_curly_quotes_in_binary_strings
    assert_raises(ArgumentError) { upload_command("C:/a\u201Cb".b, quote: :windows) }
  end

  def test_windows_download_accepts_basename_of_backslash_path
    file = prepare_file("/path/to/local.txt", "")

    expect_scp_session "-f \"C:/Users/me/remote file.txt\"" do |channel|
      channel.sends_ok
      channel.gets_data "C0666 0 remote file.txt\n"
      channel.sends_ok
      channel.gets_ok
      channel.sends_ok
    end

    assert_scripted { scp.download!("C:\\Users\\me\\remote file.txt", "/path/to/local.txt", quote: :windows) }
    assert_equal "", file.io.string
  end

  def test_none_sends_path_unchanged
    assert_equal "scp -t /a b/$x;`y` 'z' \"w\" ~/v", upload_command("/a b/$x;`y` 'z' \"w\" ~/v", quote: :none)
    assert_equal "scp -f C:\\a b", download_command("C:\\a b", quote: :none)
  end

  def test_callable
    assert_equal "scp -t [/a b]", upload_command("/a b", quote: ->(path) { "[#{path}]" })
  end

  def test_unknown_quote_raises
    assert_raises(ArgumentError) { upload_command("/a", quote: :cmd) }
    assert_raises(ArgumentError) { download_command("/a", quote: "posix") }
  end

  def test_invalid_path_raises_before_opening_channel
    session = stub('session', logger: nil)
    session.expects(:open_channel).never
    assert_raises(ArgumentError) { Net::SCP.new(session).upload!(StringIO.new, "C:/$x", quote: :windows) }
  end

  private

  def upload_command(remote, options = {})
    exec_command { |scp| scp.upload(StringIO.new("x"), remote, options) }
  end

  def download_command(remote, options = {})
    exec_command { |scp| scp.download(remote, StringIO.new, options) }
  end

  def exec_command
    command = nil
    channel = stub('channel')
    channel.stubs(:exec).with { |c| command = c }
    session = stub('session', logger: nil)
    session.stubs(:open_channel).yields(channel).returns(channel)
    yield Net::SCP.new(session)
    command
  end
end
