require 'faker'

# Базовый класс стратегии, содержащий общие константы и вспомогательные методы
class GenerationStrategy
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

  def generate(options)
    raise NotImplementedError, "Метод generate должен быть реализован в подклассе"
  end

  protected

  def random_adjective
    Faker::Adjective.positive.capitalize
  end

  def random_noun
    Faker::Creature::Animal.name.capitalize
  end

  def random_prefix
    PREFIXES.sample
  end

  def random_suffix
    SUFFIXES.sample
  end

  def leet_transform(text)
    text.chars.map { |c| LEET_MAP[c] || c }.join
  end
end

# Стратегия: Случайный ник
class RandomStrategy < GenerationStrategy
  def generate(options = {})
    separator = options[:separator] || '_'
    add_number = options.key?(:number) ? options[:number] : true
    number_range = options[:number_range] || 1..999

    word1 = random_adjective
    word2 = random_noun

    nickname = "#{word1}#{separator}#{word2}"

    if add_number
      nickname << separator unless separator.empty?
      nickname << rand(number_range).to_s
    end

    nickname.downcase.gsub(/\s+/, '')
  end
end
# Количество проходов волны
# Стратегия: Ник из имени
class FromNameStrategy < GenerationStrategy
  def generate(options = {})
    name = options[:name]
    return RandomStrategy.new.generate(options) if name.nil? || name.empty?

    base = name.strip
    separator = options[:separator] || '_'
    add_prefix = options.key?(:prefix) ? options[:prefix] : true
    add_suffix = options.key?(:suffix) ? options[:suffix] : true
    add_number = options.key?(:number) ? options[:number] : false
    number_range = options[:number_range] || 1..999

    nickname = base.gsub(/\s+/, separator)
    nickname = "#{random_prefix}#{separator}#{nickname}" if add_prefix
    nickname = "#{nickname}#{separator}#{random_suffix}" if add_suffix

    if add_number
      nickname << separator unless separator.empty?
      nickname << rand(number_range).to_s
    end

    nickname
  end
end

# Стратегия: Геймерский ник
class GamerStrategy < GenerationStrategy
  def generate(options = {})
    name = options[:name]
    separator = options[:separator] || '_'
    
    base = if name.nil? || name.empty?
             RandomStrategy.new.generate(options.merge(number: false))
           else
             name.strip.gsub(/\s+/, separator)
           end

    add_prefix = options.key?(:prefix) ? options[:prefix] : true
    add_suffix = options.key?(:suffix) ? options[:suffix] : true
    apply_leet = options.key?(:leet) ? options[:leet] : true
    add_number = options.key?(:number) ? options[:number] : true
    number_range = options[:number_range] || 1..999
    wrap = options[:wrap_with_x] || false

    nickname = base
    nickname = leet_transform(nickname) if apply_leet

    if add_prefix
      prefix = apply_leet ? leet_transform(random_prefix) : random_prefix
      nickname = "#{prefix}#{separator}#{nickname}"
    end

    if add_suffix
      suffix = apply_leet ? leet_transform(random_suffix) : random_suffix
      nickname = "#{nickname}#{separator}#{suffix}"
    end

    if add_number
      nickname << separator unless separator.empty?
      nickname << rand(number_range).to_s
    end

    nickname = "xX_#{nickname}_Xx" if wrap
    nickname
  end
end

# Контекст, использующий стратегию
class NicknameGenerator
  attr_accessor :strategy

  def initialize(strategy = RandomStrategy.new)
    @strategy = strategy
  end

  def generate(options = {})
    @strategy.generate(options)
  end
end