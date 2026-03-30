require 'minitest/autorun'
require_relative '../lib/nickname_generator'

class TestNicknameGenerator < Minitest::Test
  def setup
    @generator = NicknameGenerator.new
  end

  # ----- RandomStrategy -----
  def test_random_strategy_defaults
    @generator.strategy = RandomStrategy.new
    result = @generator.generate
    # Два слова + число (разделитель '_')
    assert_match(/\A[a-z]+_[a-z]+_\d+\z/, result)
  end

  def test_random_strategy_custom_separator
    @generator.strategy = RandomStrategy.new
    result = @generator.generate(separator: '-', number: true)
    assert_match(/\A[a-z]+-[a-z]+-\d+\z/, result)
  end

  def test_random_strategy_no_number
    @generator.strategy = RandomStrategy.new
    result = @generator.generate(number: false)
    assert_match(/\A[a-z]+_[a-z]+\z/, result)
  end

  # ----- FromNameStrategy -----
  def test_from_name_strategy_basic
    @generator.strategy = FromNameStrategy.new
    result = @generator.generate(name: "John Doe")
    # Префикс + имя (пробелы заменены) + суффикс
    assert_match(/\A[a-z]+_john_doe_[a-z]+\z/, result.downcase)
  end

  def test_from_name_strategy_no_prefix
    @generator.strategy = FromNameStrategy.new
    result = @generator.generate(name: "Jane", prefix: false, suffix: false)
    assert_equal "jane", result.downcase
  end

  def test_from_name_strategy_no_suffix
    @generator.strategy = FromNameStrategy.new
    result = @generator.generate(name: "Jane", suffix: false)
    assert_match(/\A[a-z]+_jane\z/, result.downcase)
  end

  def test_from_name_strategy_empty_name_fallback
    @generator.strategy = FromNameStrategy.new
    result = @generator.generate(name: "", number: false)
    assert_match(/\A[a-z]+_[a-z]+\z/, result)
  end

  # ----- GamerStrategy -----
  def test_gamer_strategy_basic
    @generator.strategy = GamerStrategy.new
    result = @generator.generate(name: "CoolGuy")
    # Формат: префикс_имя_суффикс_число (любые символы, кроме '_')
    assert_match(/\A[^_]+_[^_]+_[^_]+_\d+\z/, result)
    # Проверка leet: если в имени есть 'e', оно должно стать '3'
    if result.downcase.include?('e')
      assert result.include?('3'), "Leet not applied: #{result}"
    end
  end

  def test_gamer_strategy_no_leet
    @generator.strategy = GamerStrategy.new
    result = @generator.generate(name: "CoolGuy", leet: false, suffix: false)
    parts = result.split('_')
    # Ожидаем три части: префикс, имя, число
    assert_equal 3, parts.length
    # Префикс и имя должны содержать только буквы (без leet-цифр)
    assert_match(/\A[a-zA-Z]+\z/, parts[0])
    assert_match(/\A[a-zA-Z]+\z/, parts[1])
    # Число должно быть числом
    assert_match(/\A\d+\z/, parts[2])
  end

  def test_gamer_strategy_wrap_with_x
    @generator.strategy = GamerStrategy.new
    result = @generator.generate(name: "Gamer", wrap_with_x: true,
                                 leet: false, prefix: false, suffix: false, number: false)
    assert_equal "xX_Gamer_Xx", result
  end

  def test_gamer_strategy_without_name
    @generator.strategy = GamerStrategy.new
    result = @generator.generate(prefix: false, suffix: false, number: true)
    # Два слова (могут содержать leet-цифры) + число
    assert_match(/\A[a-zA-Z0-9]+_[a-zA-Z0-9]+_\d+\z/, result)
  end

  # ----- Контекст -----
  def test_strategy_switching
    @generator.strategy = RandomStrategy.new
    assert_kind_of RandomStrategy, @generator.strategy

    @generator.strategy = FromNameStrategy.new
    assert_kind_of FromNameStrategy, @generator.strategy
  end
end