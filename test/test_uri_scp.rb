require 'common'
require 'uri/scp'

class TestURISCP < Net::SCP::TestCase
  def test_query_options_are_parsed
    uri = URI.parse("scp://example.com/file?port=22&ciphers=aes128-ctr,aes256-ctr")
    assert_equal({ port: 22, ciphers: ["aes128-ctr", "aes256-ctr"] }, uri.options)
  end

  def test_valueless_entries_and_empty_separators_are_accepted
    uri = URI.parse("scp://example.com/file?flag&&port=22&")
    assert_equal({ flag: [], port: 22 }, uri.options)
  end

  def test_options_follow_query_changes
    uri = URI.parse("scp://example.com/file?port=22")
    uri.query = "port=2222"
    assert_equal({ port: 2222 }, uri.options)
    uri.query = nil
    assert_equal({}, uri.options)
  end

  def test_options_are_kept_while_query_is_unchanged
    uri = URI.parse("scp://example.com/file?port=22")
    uri.options[:verbose] = true
    assert_equal({ port: 22, verbose: true }, uri.options)
  end
end
