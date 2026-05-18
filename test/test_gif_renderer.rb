require_relative 'test_helper'
require_relative '../lib/gif_renderer'

class TestGifRenderer < Minitest::Test
  def test_build_raises_on_empty_frames
    renderer = GifRenderer.new
    assert_raises(ArgumentError) { renderer.build([]) }
  end

  def test_build_creates_gif_when_imagemagick_available
    skip 'ImageMagick not installed' unless GifRenderer.available?

    renderer = GifRenderer.new
    path = renderer.build(%w[a ab abc], delay_cs: 5)
    assert File.file?(path)
    assert path.end_with?('.gif')
    assert_operator File.size(path), :>, 100
  ensure
    FileUtils.rm_rf(File.dirname(path)) if defined?(path) && path
  end

  def test_install_hint_mentions_imagemagick
    assert_includes GifRenderer.install_hint, 'ImageMagick'
  end
end
