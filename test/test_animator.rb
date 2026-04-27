require_relative 'test_helper'
require_relative '../lib/animator'

class TestAnimator < Minitest::Test
  def test_typewriter_frames
    assert_equal %w[h he hey], Animator.send(:typewriter_frames, 'hey')
  end

  def test_wave_frames_cycles
    frames = Animator.send(:wave_frames, 'ab', cycles: 2)
    assert_equal ['Ab', 'aB', 'Ab', 'aB'], frames
  end

  def test_blink_frames
    assert_equal ['yo', '', 'yo', '', 'yo', '', 'yo', ''], Animator.send(:blink_frames, 'yo')
  end

  def test_fade_frames_aliases_typewriter
    assert_equal Animator.send(:typewriter_frames, 'abc'), Animator.send(:fade_frames, 'abc')
  end

  def test_slide_frames
    assert_equal ['  a', ' ab', 'abc'], Animator.send(:slide_frames, 'abc')
  end

  def test_bounce_frames
    assert_equal ['Ab', 'ab', 'aB', 'ab'], Animator.send(:bounce_frames, 'ab', cycles: 1)
  end

  def test_rainbow_frames
    frames = Animator.send(:rainbow_frames, 'ab', colors: [31, 32])
    assert_equal 2, frames.length
    assert_includes frames[0], "\e[31ma\e[0m"
    assert_includes frames[0], "\e[32mb\e[0m"
  end

  def test_matrix_frames
    Animator.stub(:random_char, 'x') do
      frames = Animator.send(:matrix_frames, 'ab', steps: 2)
      assert_equal 3, frames.length
      assert_equal 'xx', frames.first
      assert_equal 'ab', frames.last
    end
  end

  def test_method_missing_for_unknown_frames
    assert_equal [], Animator.send(:unknown_frames, 'text')
  end

  def test_respond_to_missing_for_unknown_frames
    assert Animator.respond_to?(:any_new_frames, true)
  end

  def test_animate_prints_plain_text_for_none
    out, = capture_io do
      Animator.animate('hello', :none, 0)
    end
    assert_includes out, 'hello'
  end
end
