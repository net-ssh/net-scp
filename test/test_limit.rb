require 'common'
require 'stringio'

class TestLimit < Net::SCP::TestCase
  def test_upload_should_pass_limit_to_scp
    assert_equal "scp -t -l 8000 /a.txt", upload_command("/a.txt", limit: 8000)
  end

  def test_download_should_pass_limit_to_scp
    assert_equal "scp -f -l 8000 /a.txt", download_command("/a.txt", limit: 8000)
  end

  def test_recursive_should_pass_limit_after_other_flags
    assert_equal "scp -t -r -p -l 1 /a", upload_command("/a", recursive: true, preserve: true, limit: 1)
    assert_equal "scp -f -r -l 1 /a", download_command("/a", recursive: true, limit: 1)
  end

  def test_no_limit_should_not_pass_l
    assert_equal "scp -t /a.txt", upload_command("/a.txt")
    assert_equal "scp -f /a.txt", download_command("/a.txt")
    assert_equal "scp -t /a.txt", upload_command("/a.txt", limit: nil)
  end

  def test_invalid_limit_should_raise_before_opening_channel
    [0, -1, 8000.0, "8000", "8000 x; touch /tmp/pwned;", false, :fast].each do |limit|
      session = stub('session', logger: nil)
      session.expects(:open_channel).never
      scp = Net::SCP.new(session)
      error = assert_raises(ArgumentError) { scp.upload(StringIO.new("x"), "/a.txt", limit: limit) }
      assert_equal ":limit must be a positive Integer", error.message
      assert_raises(ArgumentError) { scp.download("/a.txt", StringIO.new, limit: limit) }
    end
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
