require 'logger'
require 'telegram/bot'
require_relative 'nickname_generator'
require_relative 'animator'
require 'dotenv/load'

TOKEN = ENV['TELEGRAM_BOT_TOKEN']
TELEGRAM_API_PROXY_ENV_KEYS = %w[
  TELEGRAM_HTTP_PROXY HTTPS_PROXY https_proxy HTTP_PROXY http_proxy
].freeze

# Прокси для доступа к api.telegram.org (если прямое соединение блокируется).
# Поддерживаются TELEGRAM_HTTP_PROXY или стандартные HTTPS_PROXY / HTTP_PROXY.
module TelegramApiConnectionWithProxy
  def conn
    p = http_proxy_url
    if p
      @conn ||= Faraday.new(url: url, proxy: p) do |faraday|
        faraday.request :multipart
        faraday.request :url_encoded
        faraday.adapter Telegram::Bot.configuration.adapter
        faraday.options.timeout = Telegram::Bot.configuration.connection_timeout
        faraday.options.open_timeout = Telegram::Bot.configuration.connection_open_timeout
      end
    else
      super
    end
  end

  private

  def http_proxy_url
    TELEGRAM_API_PROXY_ENV_KEYS.each do |key|
      val = ENV[key]
      next if val.nil? || val.strip.empty?

      return val.strip
    end
    nil
  end
end

Telegram::Bot::Api.prepend(TelegramApiConnectionWithProxy)

# В telegram-bot-ruby 1.0.x log_incoming_message использует Kernel#format с неверной
# строкой формата — на части версий Ruby это падает при каждом входящем сообщении.
# Переопределяем безопасным логированием, чтобы апдейты доходили до обработчика.
#
# Дополнительно логируем каждый ответ getUpdates: если строк «Poll: …» нет — запросы
# к API не доходят; если «0 update(s)» есть, а «Incoming…» нет — пишете не тому боту
# или второй процесс забирает апдейты тем же токеном.
class Telegram::Bot::Client
  def fetch_updates
    response = api.getUpdates(options)
    unless response['ok']
      logger.warn("getUpdates: not ok — #{response.inspect}")
      return
    end

    batch = response['result']
    batch = [] unless batch.is_a?(Array)
    logger.info("Poll: getUpdates returned #{batch.size} update(s) (long wait is normal)")

    batch.each do |data|
      yield handle_update(Telegram::Bot::Types::Update.new(data))
    end
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
    logger.info("Poll: #{e.class}, retrying…")
    retry
  end

  private

  def log_incoming_message(message)
    if message.nil?
      logger.info('Incoming update: no text message in this update (skipped)')
      return
    end

    uid = message.respond_to?(:from) && message.from ? message.from.id : nil
    text = message.respond_to?(:text) ? message.text : nil
    logger.info("Incoming message: text=#{text.inspect} uid=#{uid.inspect}")
  end
end

class TelegramNicknameBot
  SUPPORTED_TYPES = %i[random from_name gamer].freeze
  SUPPORTED_ANIMATIONS = %i[typewriter wave blink fade slide bounce rainbow matrix none].freeze

  # Лимиты превью в Telegram (одно сообщение ≤ 4096 символов; длинные строки дают сотни кадров).
  MAX_TELEGRAM_ANIM_FRAMES = 48
  MAX_TELEGRAM_ANIM_TEXT_CHARS = 96
  # Rainbow: эмодзи на символ — лимит исходника, чтобы не пробить лимит Telegram.
  MAX_RAINBOW_SOURCE_CHARS = 56
  DEFAULT_ANIM_DELAY_SEC = 0.09

  def initialize(token: ENV['TELEGRAM_BOT_TOKEN'], generator_factory: NicknameGenerator)
    @token = token
    @generator_factory = generator_factory
  end

  def run
    raise ArgumentError, 'TELEGRAM_BOT_TOKEN is required' if @token.nil? || @token.strip.empty?

    logger = Logger.new($stderr)
    logger.level = Logger::INFO

    proxy = TELEGRAM_API_PROXY_ENV_KEYS.map { |k| ENV[k] }.compact.find { |v| !v.to_s.strip.empty? }&.strip
    logger.info("Using HTTP proxy for Telegram API: #{proxy}") if proxy

    Telegram::Bot::Client.run(@token, logger: logger) do |bot|
      me = bot.api.get_me
      bot.logger.info("getMe: #{me.inspect}") if me

      info = bot.api.get_webhook_info
      bot.logger.info("getWebhookInfo (before): #{info.inspect}") if info

      # Long polling (listen) не получает апдейты, пока активен webhook — сбрасываем.
      deleted = bot.api.delete_webhook(drop_pending_updates: false)
      bot.logger.info("deleteWebhook: #{deleted.inspect}")

      info_after = bot.api.get_webhook_info
      bot.logger.info("getWebhookInfo (after): #{info_after.inspect}") if info_after

      if info_after.is_a?(Hash) && info_after['ok'] &&
         info_after.dig('result', 'url').to_s != ''
        bot.logger.warn(
          'Webhook URL is still set; getUpdates may stay empty. ' \
          'Remove webhook in Bot settings or call deleteWebhook again.'
        )
      end

      bot.listen do |message|
        next unless message&.respond_to?(:chat) && message.chat

        begin
          text = message.respond_to?(:text) && message.text ? message.text.to_s : ''
          command, *args = text.strip.split(/\s+/)
          command = '/help' if command.nil? || command.empty?
          command = normalize_command(command)

          if command == '/animate'
            err = deliver_animation(bot, message.chat.id, args)
            bot.api.send_message(chat_id: message.chat.id, text: err) if err
            next
          end

          response = handle_message(text)
          bot.api.send_message(chat_id: message.chat.id, text: response)
        rescue StandardError => e
          bot.logger.error("#{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
          begin
            bot.api.send_message(
              chat_id: message.chat.id,
              text: "Ошибка: #{e.message}"
            )
          rescue StandardError => send_error
            bot.logger.error("send_message failed: #{send_error.class}: #{send_error.message}")
          end
        end
      end
    end
  end

  def handle_message(text)
    command, *args = text.to_s.strip.split(/\s+/)
    command = '/help' if command.nil? || command.empty?
    command = normalize_command(command)

    case command
    when '/start'
      start_text
    when '/help'
      help_text
    when '/random'
      build_generator(:random).generate
    when '/from_name'
      name = args.join(' ')
      return "Usage: /from_name <name>" if name.strip.empty?

      build_generator(:from_name).generate(name: name)
    when '/gamer'
      name = args.join(' ')
      options = name.strip.empty? ? {} : { name: name }
      build_generator(:gamer).generate(options)
    else
      "Unknown command: #{command}\n\n#{help_text}"
    end
  end

  private

  def normalize_command(command)
    return command unless command.start_with?('/') && command.include?('@')

    command.split('@', 2).first
  end

  def build_generator(type)
    raise ArgumentError, "Unsupported type: #{type}" unless SUPPORTED_TYPES.include?(type)

    strategy = case type
               when :from_name then FromNameStrategy.new
               when :gamer then GamerStrategy.new
               else RandomStrategy.new
               end

    @generator_factory.new(strategy)
  end

  # Разбор /animate и подготовка кадров (используется тестами через send).
  def animation_prepare(args)
    empty = ['Usage: /animate <style> <text>', nil, nil, nil, nil]
    return empty if args.empty?

    style = args.shift.to_s.downcase.to_sym
    text = args.join(' ')
    return empty if text.strip.empty?
    return ["Unsupported style: #{style}", nil, nil, nil, nil] unless SUPPORTED_ANIMATIONS.include?(style)

    stripped = text.strip
    clipped = clip_animation_text(stripped)

    frames = telegram_animation_frames(style, clipped).map { |line| strip_ansi(line.to_s) }
    note_clipped = clipped != stripped

    [nil, frames, style, clipped, note_clipped]
  rescue NoMethodError
    ['Неизвестный стиль анимации.', nil, nil, nil, nil]
  end

  # Живая анимация: первое сообщение + edit_message_text по кадрам (как перерисовка в CLI).
  def deliver_animation(bot, chat_id, args)
    error, frames, style, clipped, = animation_prepare(args)
    return error if error

    delay = Float(ENV.fetch('TELEGRAM_ANIM_DELAY', DEFAULT_ANIM_DELAY_SEC))

    if frames.nil? || frames.empty?
      msg = clipped.to_s
      resp = bot.api.send_message(
        chat_id: chat_id,
        text: truncate_for_telegram(msg)
      )
      return nil if resp.is_a?(Hash) && resp['ok']

      return api_error_hint(resp)
    end

    frames = frames.take(MAX_TELEGRAM_ANIM_FRAMES)

    slides = frames.map { |frame| truncate_for_telegram(frame.to_s) }

    first = slides.first.to_s

    resp = bot.api.send_message(
      chat_id: chat_id,
      text: first
    )
    return api_error_hint(resp) unless resp.is_a?(Hash) && resp['ok']

    mid = resp.dig('result', 'message_id')
    return 'Не удалось получить message_id от Telegram.' unless mid

    slides.drop(1).each do |slide|
      sleep(delay)
      edit = bot.api.edit_message_text(
        chat_id: chat_id,
        message_id: mid,
        text: slide
      )
      bot.logger.warn("edit_message_text: #{edit.inspect}") unless edit.is_a?(Hash) && edit['ok']
    rescue StandardError => e
      bot.logger.warn("edit_message_text failed: #{e.class}: #{e.message}")
      break
    end

    nil
  end

  def truncate_for_telegram(text)
    s = text.to_s
    return "\u2063#{s}" if s.strip.empty?

    max = 4090
    return s if s.bytesize <= max

    s.byteslice(0, max) + '…'
  end

  def api_error_hint(resp)
    return 'Не удалось отправить сообщение.' unless resp.is_a?(Hash)

    desc = resp['description'] || resp.dig('parameters', 'retry_after')
    desc ? "Telegram: #{desc}" : 'Не удалось отправить сообщение.'
  end

  def clip_animation_text(text)
    return text if text.length <= MAX_TELEGRAM_ANIM_TEXT_CHARS

    "#{text[0, MAX_TELEGRAM_ANIM_TEXT_CHARS]}…"
  end

  def strip_ansi(str)
    str.gsub(/\e\[[0-9;]*m/, '')
  end

  # Кадры под Telegram: ANSI из Animator убираем; стили сознательно отличаются друг от друга.
  def telegram_animation_frames(style, text)
    len = text.length

    case style
    when :rainbow
      src = len > MAX_RAINBOW_SOURCE_CHARS ? "#{text[0, MAX_RAINBOW_SOURCE_CHARS]}…" : text
      rainbow_frames_for_telegram(src)
    when :fade
      # Отличается от typewriter: «ступенчатое» проявление (1,2,4,8,… до конца).
      telegram_logarithmic_fade_frames(text)
    when :typewriter
      Animator.typewriter_frames(text)
    when :wave
      cycles =
        if len > 32
          1
        elsif len > 18
          2
        else
          3
        end
      Animator.wave_frames(text, cycles: cycles)
    when :bounce
      cycles = len > 30 ? 1 : len > 14 ? 2 : 3
      Animator.bounce_frames(text, cycles: cycles)
    when :blink
      Animator.blink_frames(text)
    when :slide
      Animator.slide_frames(text)
    when :matrix
      Animator.matrix_frames(text, steps: [len, 18].min)
    when :none
      Animator.send(:none_frames, text)
    else
      Animator.send("#{style}_frames", text)
    end
  end

  # Радуга как раньше: полоса эмодзи «перетекает» по символам (ANSI в Telegram не видны).
  def rainbow_frames_for_telegram(text)
    palette = %w[🔴 🟠 🟡 🟢 🔵 🟣]
    palette.size.times.map do |offset|
      text.chars.each_with_index.map do |ch, idx|
        "#{palette[(idx + offset) % palette.size]}#{ch}"
      end.join
    end
  end

  def telegram_logarithmic_fade_frames(text)
    return [] if text.empty?

    max_len = text.length
    lengths = []
    n = 1
    while n < max_len
      lengths << n
      n *= 2
    end
    lengths << max_len
    lengths.uniq.sort.map { |i| text[0, i] }
  end

  def start_text
    [
      'Nickname Generator Bot is ready.',
      'Use /help to see all commands.'
    ].join("\n")
  end

  def help_text
    [
      'Commands:',
      '/start - welcome message',
      '/help - show this help',
      '/random - generate random nickname',
      '/from_name <name> - generate nickname from your name',
      '/gamer <name?> - generate gamer nickname, name is optional',
      '/animate <style> <text> — одно сообщение, текст меняется по кадрам',
      "Available styles: #{SUPPORTED_ANIMATIONS.join(', ')}"
    ].join("\n")
  end
end
