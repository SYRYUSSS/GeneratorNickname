module Animator
  def self.animate(text, style = :none)
    case style
    when :typewriter
      typewriter(text)
    when :wave
      wave(text)
    when :blink
      blink(text)
    else
      puts text
    end
  end

  private

  def self.typewriter(text)
    text.each_char do |char|
      print char
      sleep 0.05
    end
    puts
  end

  def self.wave(text)
    3.times do 
      text.length.times do |i|
        # Поднимаем текущий символ в верхний регистр, остальные в нижний
        animated = text.chars.map.with_index do |char, index|
          index == i ? char.upcase : char.downcase
        end.join
        
        print "\r\e[K#{animated}" 
        sleep 0.05
      end
    end
    # Финальный вывод оригинального текста
    print "\r\e[K#{text}\n"
  end

  def self.blink(text)
    4.times do
      print "\r\e[K#{text}"
      sleep 0.3
      print "\r\e[K"
      sleep 0.2
    end
    puts text
  end
end