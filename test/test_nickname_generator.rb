require_relative 'test_helper'
require_relative '../lib/nickname_generator'


class TestNicknameGenerator < Minitest::Test
  def setup
    @generator = NicknameGenerator.new
  end

  # ----- RandomStrategy -----
  def test_random_strategy_defaults
    strategy = RandomStrategy.new
    strategy.stub(:random_adjective, 'Brave') do
      strategy.stub(:random_noun, 'Tiger') do
        strategy.stub(:rand, 42) do
          @generator.strategy = strategy
          result = @generator.generate
          assert_equal 'brave_tiger_42', result
        end
      end
    end
  end

  def test_random_strategy_custom_separator
    strategy = RandomStrategy.new
    strategy.stub(:random_adjective, 'Wild') do
      strategy.stub(:random_noun, 'Wolf') do
        strategy.stub(:rand, 7) do
          @generator.strategy = strategy
          result = @generator.generate(separator: '-', number: true)
          assert_equal 'wild-wolf-7', result
        end
      end
    end
  end

  def test_random_strategy_no_number
    strategy = RandomStrategy.new
    strategy.stub(:random_adjective, 'Speedy') do
      strategy.stub(:random_noun, 'Rabbit') do
        @generator.strategy = strategy
        result = @generator.generate(number: false)
        assert_equal 'speedy_rabbit', result
      end
    end
  end

  # ----- FromNameStrategy -----
  def test_from_name_strategy_basic
    strategy = FromNameStrategy.new
    strategy.stub(:random_prefix, 'Pro') do
      strategy.stub(:random_suffix, 'Legend') do
        @generator.strategy = strategy
        result = @generator.generate(name: 'John Doe')
        assert_equal 'Pro_john_doe_Legend', result
      end
    end
  end

  def test_from_name_strategy_no_prefix
    @generator.strategy = FromNameStrategy.new
    result = @generator.generate(name: "Jane", prefix: false, suffix: false)
    assert_equal "jane", result.downcase
  end

  def test_from_name_strategy_no_suffix
    strategy = FromNameStrategy.new
    strategy.stub(:random_prefix, 'Mr') do
      @generator.strategy = strategy
      result = @generator.generate(name: 'Jane', suffix: false)
      assert_equal 'Mr_jane', result
    end
  end

  def test_from_name_strategy_empty_name_fallback
    @generator.strategy = FromNameStrategy.new
    result = @generator.generate(name: '', number: false)
    assert_match(/\A[a-z]+_[a-z]+\z/, result)
  end

  # ----- GamerStrategy -----
  def test_gamer_strategy_basic
    strategy = GamerStrategy.new
    strategy.stub(:random_prefix, 'Dark') do
      strategy.stub(:random_suffix, 'Master') do
        strategy.stub(:rand, 77) do
          @generator.strategy = strategy
          result = @generator.generate(name: 'CoolGuy')
          assert_equal 'D4rk_C00lGuy_M4573r_77', result
        end
      end
    end
  end

  def test_gamer_strategy_no_leet
    strategy = GamerStrategy.new
    strategy.stub(:random_prefix, 'Shadow') do
      strategy.stub(:rand, 33) do
        @generator.strategy = strategy
        result = @generator.generate(name: 'CoolGuy', leet: false, suffix: false)
        assert_equal 'Shadow_CoolGuy_33', result
      end
    end
  end

  def test_gamer_strategy_wrap_with_x
    @generator.strategy = GamerStrategy.new
    result = @generator.generate(name: "Gamer", wrap_with_x: true,
                                 leet: false, prefix: false, suffix: false, number: false)
    assert_equal "xX_Gamer_Xx", result
  end

  def test_gamer_strategy_without_name
    strategy = GamerStrategy.new
    strategy.stub(:random_adjective, 'Brave') do
      strategy.stub(:random_noun, 'Tiger') do
        strategy.stub(:rand, 5) do
          @generator.strategy = strategy
          result = @generator.generate(prefix: false, suffix: false, number: true)
          assert_equal 'br4v3_71g3r_5', result
        end
      end
    end
  end

  def test_generation_strategy_requires_implementation
    error = assert_raises(NotImplementedError) { GenerationStrategy.new.generate({}) }
    assert_match(/должен быть реализован/, error.message)
  end

  def test_from_name_with_number_and_without_separator
    strategy = FromNameStrategy.new
    strategy.stub(:random_prefix, 'Dr') do
      strategy.stub(:random_suffix, 'King') do
        strategy.stub(:rand, 9) do
          @generator.strategy = strategy
          result = @generator.generate(
            name: 'Neo',
            separator: '',
            number: true
          )
          assert_equal 'DrNeoKing9', result
        end
      end
    end
  end

  # ----- Контекст -----
  def test_strategy_switching
    @generator.strategy = RandomStrategy.new
    assert_kind_of RandomStrategy, @generator.strategy

    @generator.strategy = FromNameStrategy.new
    assert_kind_of FromNameStrategy, @generator.strategy
  end

  def test_nickname_generator_uses_random_strategy_by_default
    generator = NicknameGenerator.new
    assert_kind_of RandomStrategy, generator.strategy
  end
end
