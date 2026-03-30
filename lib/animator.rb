# lib/animator.rb

module Animator
  # Цвета для радужной анимации (ANSI)
  RAINBOW_COLORS = [31, 33, 32, 36, 34, 35].freeze  # красный, жёлтый, зелёный, голубой, синий, фиолетовый

  # Основной метод анимации
  # text   - строка для анимации
  # style  - символ :typewriter, :wave, :blink, :fade, :slide, :bounce, :rainbow, :matrix
  # delay  - задержка между кадрами (секунды)
  # options - дополнительные параметры (например, cycles для bounce, steps для matrix)
  def self.animate(text, style = :none, delay = 0.05, **options)
    frames = send("#{style}_frames", text, **options)
    if frames.empty?
      puts text
      return
    end

    frames.each do |frame|
      print "\r\e[K#{frame}"
      sleep delay
    end
    puts
  end

  private

  # ---------- Существующие анимации ----------
  def self.typewriter_frames(text, **)
    (1..text.length).map { |i| text[0, i] }
  end

  def self.wave_frames(text, cycles = 3, **)
    frames = []
    cycles.times do
      text.length.times do |i|
        frames << text.chars.map.with_index { |ch, idx| idx == i ? ch.upcase : ch.downcase }.join
      end
    end
    frames
  end

  def self.blink_frames(text, **)
    Array.new(4) { [text, ""] }.flatten
  end

  # ---------- Новые анимации ----------

  # fade – то же, что typewriter (постепенное появление)
  def self.fade_frames(text, **)
    typewriter_frames(text)
  end

  # slide – текст выезжает справа (каждый кадр – пробелы + часть текста, выровненные по правому краю)
  def self.slide_frames(text, **)
    frames = []
    (1..text.length).each do |i|
      visible = text[0, i]
      frames << visible.rjust(text.length)   # выравнивание по правому краю
    end
    frames
  end

  # bounce – "подпрыгивание": каждый символ по очереди становится заглавным и возвращается обратно
  # cycles – количество проходов (по умолчанию 2)
  def self.bounce_frames(text, cycles: 2, **)
    frames = []
    cycles.times do
      text.length.times do |i|
        # подъём (заглавный)
        frames << text.chars.map.with_index { |ch, idx| idx == i ? ch.upcase : ch }.join
        # возврат (исходный)
        frames << text
      end
    end
    frames
  end

  # rainbow – "бегущая радуга": каждый символ окрашивается в цвет из палитры, цветовая волна движется
  def self.rainbow_frames(text, colors: RAINBOW_COLORS, **)
    frames = []
    colors.length.times do |offset|
      colored = text.chars.each_with_index.map do |ch, idx|
        color = colors[(idx + offset) % colors.length]
        "\e[#{color}m#{ch}\e[0m"
      end.join
      frames << colored
    end
    frames
  end

  # matrix – эффект "Матрицы": случайные символы постепенно заменяются правильным текстом
  # steps – количество шагов замены (по умолчанию длина текста)
  def self.matrix_frames(text, steps: text.length, **)
    frames = []
    current = text.chars.map { random_char }.join
    frames << current

    (1..steps).each do |i|
      # Выбираем i уникальных позиций для замены
      indices = (0...text.length).to_a.sample(i)
      new_chars = current.chars
      indices.each { |idx| new_chars[idx] = text[idx] }
      current = new_chars.join
      frames << current
    end
    frames
  end

  # Вспомогательный метод – случайный печатный символ
  def self.random_char
    chars = ('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a + ['@', '#', '$', '%', '&', '*']
    chars.sample
  end

  # Если метод _frames не найден, возвращаем пустой массив (анимация не применяется)
  def self.method_missing(method_name, *args, &block)
    if method_name.to_s.end_with?('_frames')
      []
    else
      super
    end
  end

  def self.respond_to_missing?(method_name, include_private = false)
    method_name.to_s.end_with?('_frames') || super
  end
end