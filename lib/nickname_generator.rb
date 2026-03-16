require 'singleton'
require 'faker'

class NicknameGenerator
  include Singleton

  # Списки префиксов и суффиксов
  PREFIXES = [
    'xX', 'Mr', 'Mrs', 'Dr', 'Lord', 'Lady', 'Sir', 'King', 'Queen',
    'Pro', 'Ultra', 'Super', 'Mega', 'Hyper', 'Dark', 'Shadow', 'Night',
    'Fire', 'Ice', 'Thunder', 'Lightning', 'Death', 'Silent', 'Fast'
  ].freeze

  SUFFIXES = [
    'Xx', 'Pro', 'Master', 'Killer', 'Slayer', 'Gamer', 'Player', 'Legend',
    'King', 'Queen', 'Boy', 'Girl', 'Man', 'Woman', 'Dude', 'Bro', 'Sis',
    'FTW', 'LOL', 'OMG', '™', '©', '®', 'ツ'
  ].freeze

  LEET_MAP = {
    'a' => '4', 'e' => '3', 'i' => '1', 'o' => '0', 's' => '5', 't' => '7',
    'A' => '4', 'E' => '3', 'I' => '1', 'O' => '0', 'S' => '5', 'T' => '7'
  }.freeze

  # Основной метод генерации с выбором типа
  # options:
  #   :type       - :random, :from_name, :gamer (по умолчанию :random)
  #   :name       - исходное имя (для :from_name и :gamer)
  #   :prefix     - boolean (добавлять префикс, по умолчанию true для соответствующих типов)
  #   :suffix     - boolean (добавлять суффикс, по умолчанию true)
  #   :leet       - boolean (применять leet, для :gamer по умолчанию true)
  #   :wrap_with_x- boolean (обернуть в xX _ Xx, для :gamer)
  #   :separator  - разделитель (по умолчанию '_')
  #   :number     - добавлять число (по умолчанию: для :random true, для остальных false)
  #   :number_range - диапазон числа (по умолчанию 1..999)
  def generate(options = {})
    type = options[:type] || :random
    case type
    when :random
      generate_random(options)
    when :from_name
      generate_from_name(options[:name], options)
    when :gamer
      generate_gamer(options[:name], options)
    else
      raise ArgumentError, "Unknown type: #{type}"
    end
  end

  # Генерация случайного ника (прилагательное + существительное + опционально число)
  def generate_random(options = {})
    separator = options[:separator] || '_'
    add_number = options[:number].nil? ? true : options[:number]
    number_range = options[:number_range] || 1..999

    word1 = random_adjective
    word2 = random_noun

    nickname = "#{word1}#{separator}#{word2}"

    if add_number
      number = rand(number_range)
      nickname << separator unless separator.empty?
      nickname << number.to_s
    end

    nickname.downcase.gsub(/\s+/, '')
  end

  # Генерация ника на основе имени с возможными префиксами/суффиксами
  def generate_from_name(name, options = {})
    return generate_random(options) if name.nil? || name.empty?

    base = name.strip
    separator = options[:separator] || '_'
    add_prefix = options[:prefix].nil? ? true : options[:prefix]
    add_suffix = options[:suffix].nil? ? true : options[:suffix]
    add_number = options[:number].nil? ? false : options[:number]  # по умолчанию без числа
    number_range = options[:number_range] || 1..999

    nickname = base.gsub(/\s+/, separator)

    nickname = "#{random_prefix}#{separator}#{nickname}" if add_prefix
    nickname = "#{nickname}#{separator}#{random_suffix}" if add_suffix

    if add_number
      number = rand(number_range)
      nickname << separator unless separator.empty?
      nickname << number.to_s
    end

    nickname
  end

  # Генерация ника в геймерском стиле: leet + префиксы/суффиксы + обёртка
  def generate_gamer(name = nil, options = {})
    if name.nil? || name.empty?
      base = generate_random(options.merge(number: false))
    else
      base = name.strip.gsub(/\s+/, options[:separator] || '_')
    end

    separator = options[:separator] || '_'
    add_prefix = options[:prefix].nil? ? true : options[:prefix]
    add_suffix = options[:suffix].nil? ? true : options[:suffix]
    apply_leet = options[:leet].nil? ? true : options[:leet]
    add_number = options[:number].nil? ? true : options[:number]
    number_range = options[:number_range] || 1..999
    wrap = options[:wrap_with_x] || false

    nickname = base
    nickname = leet_transform(nickname) if apply_leet

    if add_prefix
      prefix = random_prefix
      prefix = leet_transform(prefix) if apply_leet
      nickname = "#{prefix}#{separator}#{nickname}"
    end

    if add_suffix
      suffix = random_suffix
      suffix = leet_transform(suffix) if apply_leet
      nickname = "#{nickname}#{separator}#{suffix}"
    end

    if add_number
      number = rand(number_range)
      nickname << separator unless separator.empty?
      nickname << number.to_s
    end

    nickname = "xX_#{nickname}_Xx" if wrap

    nickname
  end