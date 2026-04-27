require_relative 'test_helper'
require 'open3'
require 'rbconfig'

class TestCli < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  GENERATE_BIN = File.join(ROOT, 'bin', 'generate_nickname')
  TELEGRAM_BIN = File.join(ROOT, 'bin', 'telegram_nickname_bot')

  def run_cmd(*args)
    Open3.capture3(RbConfig.ruby, GENERATE_BIN, *args)
  end

  def test_generate_nickname_help
    out, err, status = run_cmd('--help')
    assert status.success?
    assert_equal '', err
    assert_includes out, 'Usage: generate_nickname'
  end

  def test_generate_nickname_random_without_animation
    out, err, status = run_cmd('--type', 'random', '--no-number', '--anim', 'none')
    assert status.success?
    assert_equal '', err
    assert_match(/\A[a-z]+_[a-z]+\n\z/, out)
  end

  def test_generate_nickname_from_name
    out, _err, status = run_cmd('--type', 'from_name', '--name', 'John Doe', '--no-number', '--anim', 'none')
    assert status.success?
    assert_match(/john_doe/i, out)
  end

  def test_telegram_bot_bin_requires_token
    out, err, status = Open3.capture3({ 'TELEGRAM_BOT_TOKEN' => '' }, RbConfig.ruby, TELEGRAM_BIN)
    assert_equal '', out
    refute status.success?
    assert_includes err, 'TELEGRAM_BOT_TOKEN is required'
  end
end
