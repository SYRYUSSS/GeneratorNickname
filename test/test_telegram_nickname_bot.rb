require_relative 'test_helper'
require_relative '../lib/telegram_nickname_bot'

class TestTelegramNicknameBot < Minitest::Test
  FakeGenerator = Struct.new(:strategy) do
    attr_reader :last_options

    def generate(options = {})
      @last_options = options
      case strategy
      when RandomStrategy then 'random_nick'
      when FromNameStrategy then "from_name:#{options[:name]}"
      when GamerStrategy then options[:name] ? "gamer:#{options[:name]}" : 'gamer_default'
      else 'unknown'
      end
    end
  end

  def setup
    @bot = TelegramNicknameBot.new(token: 'token', generator_factory: FakeGenerator)
  end

  def test_start_command
    response = @bot.handle_message('/start')
    assert_includes response, 'Nickname Generator Bot is ready.'
  end

  def test_help_command
    response = @bot.handle_message('/help')
    assert_includes response, '/random'
    assert_includes response, '/animate <style> <text>'
  end

  def test_random_command
    assert_equal 'random_nick', @bot.handle_message('/random')
  end

  def test_from_name_command
    assert_equal 'from_name:John Doe', @bot.handle_message('/from_name John Doe')
  end

  def test_from_name_command_without_name
    assert_equal 'Usage: /from_name <name>', @bot.handle_message('/from_name')
  end

  def test_gamer_command_with_name
    assert_equal 'gamer:PlayerOne', @bot.handle_message('/gamer PlayerOne')
  end

  def test_gamer_command_without_name
    assert_equal 'gamer_default', @bot.handle_message('/gamer')
  end

  def test_animation_prepare_typewriter
    Animator.stub(:typewriter_frames, %w[h he hey]) do
      err, frames, style, = @bot.send(:animation_prepare, %w[typewriter hey])
      assert_nil err
      assert_equal :typewriter, style
      assert_equal %w[h he hey], frames
    end
  end

  def test_animation_prepare_rainbow_uses_emoji_strip
    err, frames, style, = @bot.send(:animation_prepare, %w[rainbow abc])
    assert_nil err
    assert_equal :rainbow, style
    assert_match(/🔴/, frames.first)
    assert_match(/abc/, frames.first)
  end

  def test_fade_differs_from_typewriter
    err_tw, frames_tw, = @bot.send(:animation_prepare, %w[typewriter hello])
    err_fd, frames_fd, = @bot.send(:animation_prepare, %w[fade hello])
    assert_nil err_tw
    assert_nil err_fd
    refute_equal frames_tw.size, frames_fd.size
  end

  def test_animate_with_unknown_style
    err, = @bot.send(:animation_prepare, %w[unknown text])
    assert_equal 'Unsupported style: unknown', err
  end

  def test_animate_without_text
    err, = @bot.send(:animation_prepare, ['wave'])
    assert_equal 'Usage: /animate <style> <text>', err
  end

  def test_unknown_command
    response = @bot.handle_message('/unknown')
    assert_includes response, 'Unknown command: /unknown'
    assert_includes response, 'Commands:'
  end

  def test_empty_message_falls_back_to_help
    response = @bot.handle_message(' ')
    assert_includes response, 'Commands:'
  end

  def test_build_generator_rejects_unknown_type
    error = assert_raises(ArgumentError) { @bot.send(:build_generator, :other) }
    assert_equal 'Unsupported type: other', error.message
  end

  def test_run_requires_token
    bot = TelegramNicknameBot.new(token: ' ')
    error = assert_raises(ArgumentError) { bot.run }
    assert_equal 'TELEGRAM_BOT_TOKEN is required', error.message
  end
end
