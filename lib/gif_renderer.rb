require 'tmpdir'
require 'fileutils'
require 'tempfile'

# Собирает анимированный GIF из текстовых кадров (нужен ImageMagick: magick/convert).
class GifRenderer
  DEFAULT_WIDTH = 520
  DEFAULT_HEIGHT = 140
  DEFAULT_FONT_SIZE = 34
  DEFAULT_BG = '#1a1a2e'
  DEFAULT_FG = '#f0f0f5'
  DEFAULT_DELAY_CS = 9

  # ImageMagick на Windows часто не видит Segoe UI — Arial надёжнее.
  WINDOWS_FONTS = ['Arial', 'Courier-New', 'Consolas'].freeze
  UNIX_FONTS = ['DejaVu-Sans', 'Liberation-Sans', 'FreeSans', 'Arial'].freeze

  def initialize(
    width: DEFAULT_WIDTH,
    height: DEFAULT_HEIGHT,
    font_size: DEFAULT_FONT_SIZE,
    background: DEFAULT_BG,
    foreground: DEFAULT_FG,
    font: nil
  )
    @width = width
    @height = height
    @font_size = font_size
    @background = background
    @foreground = foreground
    @font = font
  end

  def self.available?
    return @available unless @available.nil?

    @available = imagemagick_works?
  end

  def self.install_hint
    if Gem.win_platform?
      [
        'Для GIF установите ImageMagick:',
        'https://imagemagick.org/script/download.php#windows',
        'или: choco install imagemagick',
        'Проверка: magick -version',
        'В .env: TELEGRAM_GIF=1'
      ].join("\n")
    else
      [
        'Для GIF в Codespaces/Linux:',
        'sudo apt-get install -y imagemagick',
        'Проверка: magick -version',
        'Переменная: TELEGRAM_GIF=1 (export или Codespaces Secrets)'
      ].join("\n")
    end
  end

  def available?
    self.class.available?
  end

  # frames: строка или { colored: [{ char:, color: }, ...] } для радуги в GIF
  # @return [String] путь к GIF
  def build(frames, delay_cs: DEFAULT_DELAY_CS)
    raise ArgumentError, 'frames must not be empty' if frames.nil? || frames.empty?

    require 'mini_magick' unless defined?(MiniMagick)

    font = @font
    font = pick_working_font if font.nil? || font.to_s.empty?

    dir = Dir.mktmpdir('nick_gif_')
    frame_paths = frames.each_with_index.map do |frame, i|
      path = File.join(dir, format('frame_%03d.png', i))
      if colored_frame?(frame)
        render_colored_frame_png(frame[:colored], path, font)
      else
        render_frame_png(sanitize_frame(frame), path, font)
      end
      path
    end

    gif_path = File.join(dir, 'animation.gif')
    MiniMagick::Tool::Convert.new do |c|
      frame_paths.each { |p| c << p }
      c.delay delay_cs.to_s
      c.loop '0'
      c << gif_path
    end

    raise MiniMagick::Error, 'GIF file was not created' unless File.file?(gif_path) && File.size(gif_path) > 50

    gif_path
  end

  def self.imagemagick_works?
    require 'mini_magick' unless defined?(MiniMagick)
    MiniMagick.cli_version

    test_dir = Dir.mktmpdir('nick_gif_probe_')
    out = File.join(test_dir, 'probe.gif')
    MiniMagick::Tool::Convert.new do |c|
      c << 'xc:red'
      c << 'xc:blue'
      c.delay '5'
      c.loop '0'
      c << out
    end
    File.file?(out) && File.size(out) > 20
  rescue StandardError
    false
  ensure
    FileUtils.rm_rf(test_dir) if defined?(test_dir) && test_dir
  end

  private

  def colored_frame?(frame)
    frame.is_a?(Hash) && frame[:colored].is_a?(Array) && !frame[:colored].empty?
  end

  def pick_working_font
    candidates = Gem.win_platform? ? WINDOWS_FONTS : UNIX_FONTS
    candidates.find { |name| font_works?(name) }
  end

  def font_works?(font_name)
    test_dir = Dir.mktmpdir('nick_gif_font_')
    out = File.join(test_dir, 't.png')
    render_frame_png('A', out, font_name)
    File.file?(out) && File.size(out) > 80
  rescue StandardError
    false
  ensure
    FileUtils.rm_rf(test_dir) if test_dir
  end

  def sanitize_frame(text)
    s = text.to_s
    s = "\u00A0" if s.strip.empty?
    s.gsub(/\e\[[0-9;]*m/, '')
  end

  # Текст в аргументе caption: (без @file — в Codespaces/Linux policy ImageMagick это блокирует).
  def render_frame_png(text, path, font)
    safe = sanitize_frame(text)
    caption_src = "caption:#{escape_imagemagick_label(safe)}"
    run_frame_convert(caption_src, path, font)
  rescue MiniMagick::Error
    raise if font.nil? || font.to_s.empty?

    run_frame_convert(caption_src, path, nil)
  end

  def run_frame_convert(caption_src, path, font)
    MiniMagick::Tool::Convert.new do |c|
      c.size "#{@width}x#{@height}"
      c.gravity 'center'
      c.background @background
      c.fill @foreground
      c.font font if font && !font.to_s.empty?
      c.pointsize @font_size.to_s
      c << caption_src
      c << to_magick_path(path)
    end
  end

  # Радуга в GIF: у каждой буквы свой цвет (эмодзи ImageMagick не анимирует).
  def render_colored_frame_png(segments, path, font)
    segs = segments.map { |s| { char: s[:char] || s['char'], color: s[:color] || s['color'] } }
    char_w = (@font_size * 0.58).round
    char_w = 12 if char_w < 12
    total_w = segs.length * char_w
    start_x = [((@width - total_w) / 2.0).round, 8].max
    baseline_y = ((@height + @font_size) / 2.0).round

    MiniMagick::Tool::Convert.new do |c|
      c.size "#{@width}x#{@height}"
      c << "xc:#{@background}"
      segs.each_with_index do |seg, i|
        x = start_x + (i * char_w)
        ch = seg[:char].to_s
        ch = "\u00A0" if ch.empty?
        escaped = escape_draw_text(ch)
        c.fill seg[:color]
        c.font font if font && !font.to_s.empty?
        c.pointsize @font_size.to_s
        c.draw "text #{x},#{baseline_y} '#{escaped}'"
      end
      c << to_magick_path(path)
    end
  end

  def escape_draw_text(ch)
    ch.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
  end

  def escape_imagemagick_label(text)
    text.to_s
        .gsub('\\', '\\\\')
        .gsub(':', '\\:')
        .gsub("'", "\\'")
        .gsub('%', '%%')
        .gsub('#', '\\#')
        .gsub('[', '\\[')
        .gsub(']', '\\]')
  end

  def to_magick_path(path)
    path.to_s.tr('\\', '/')
  end
end
