require 'logger'
require 'fileutils'
require 'timeout'
require 'telegram/bot'
require_relative 'nickname_generator'
require_relative 'animator'
require_relative 'gif_renderer'
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
  DEFAULT_GIF_DELAY_CS = 9
  GIF_BUILD_TIMEOUT_SEC = 45
  RAINBOW_GIF_COLORS = %w[#E53935 #FB8C00 #FDD835 #43A047 #1E88E5 #8E24AA].freeze
  NICK_COMMANDS = %w[/random /from_name /gamer].freeze

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
          if gif_output_enabled? && nick_gif_response?(command, response)
            err = deliver_gif(bot, message.chat.id, nickname_gif_frames(response))
            bot.api.send_message(chat_id: message.chat.id, text: err) if err
          else
            bot.api.send_message(chat_id: message.chat.id, text: response)
          end
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

  # TELEGRAM_GIF=0 → текст в одном сообщении; иначе GIF (если есть ImageMagick).
  def deliver_animation(bot, chat_id, args)
    error, frames, style, clipped, = animation_prepare(args)
    return error if error

    if frames.nil? || frames.empty?
      frames = [clipped.to_s]
    end

    frames = frames.take(MAX_TELEGRAM_ANIM_FRAMES)

    unless gif_output_enabled?
      bot.logger.info('/animate: TELEGRAM_GIF=0, text animation')
      return deliver_animation_text(bot, chat_id, animation_text_frames(style, clipped, frames))
    end

    gif_frames = frames_for_gif(style, clipped, frames)
    deliver_gif(bot, chat_id, gif_frames, style: style, text: clipped)
  end

  def deliver_gif(bot, chat_id, frames, style: nil, text: nil)
    frames = normalize_gif_frames(frames)
    return 'Нет кадров для GIF.' if frames.empty?

    unless GifRenderer.available?
      bot.logger.warn('ImageMagick not available for GIF')
      deliver_animation_text(bot, chat_id, animation_text_frames(style, text, frames))
      return gif_setup_hint
    end

    delay_cs = Integer(ENV.fetch('TELEGRAM_GIF_DELAY_CS', DEFAULT_GIF_DELAY_CS))
    renderer = GifRenderer.new
    gif_path = Timeout.timeout(GIF_BUILD_TIMEOUT_SEC) do
      renderer.build(frames, delay_cs: delay_cs)
    end

    upload = Faraday::UploadIO.new(gif_path, 'image/gif')
    resp = Timeout.timeout(GIF_BUILD_TIMEOUT_SEC) do
      bot.api.send_animation(chat_id: chat_id, animation: upload)
    end
    return nil if resp.is_a?(Hash) && resp['ok']

    retry_after = telegram_retry_after(resp)
    if retry_after
      bot.logger.warn("send_animation rate limited: #{retry_after}s")
      return rate_limit_message(retry_after)
    end

    hint = api_error_hint(resp)
    bot.logger.warn("send_animation failed: #{hint}")
    deliver_animation_text(bot, chat_id, text_frames_from_gif(frames))
    "GIF не отправился (#{hint}). Показана текстовая анимация."
  rescue Timeout::Error
    bot.logger.warn('GIF build/send timed out')
    deliver_animation_text(bot, chat_id, text_frames_from_gif(frames))
    'GIF: таймаут. Показана текстовая анимация.'
  rescue MiniMagick::Error, Errno::ENOENT, Faraday::TimeoutError, Faraday::ConnectionFailed => e
    bot.logger.error("GIF failed: #{e.class}: #{e.message}")
    return rate_limit_message(parse_retry_after(e.message)) if rate_limited_message?(e.message)

    deliver_animation_text(bot, chat_id, text_frames_from_gif(frames))
    "GIF: #{e.message}\nПоказана текстовая анимация."
  rescue StandardError => e
    bot.logger.error("GIF unexpected error: #{e.class}: #{e.message}")
    return rate_limit_message(parse_retry_after(e.message)) if rate_limited_message?(e.message)

    deliver_animation_text(bot, chat_id, text_frames_from_gif(frames))
    "GIF: #{e.message}\nПоказана текстовая анимация."
  ensure
    cleanup_gif_workdir(gif_path) if defined?(gif_path) && gif_path
  end

  def gif_setup_hint
    [
      'GIF недоступен на этом ПК.',
      GifRenderer.install_hint,
      'Сейчас отправлена текстовая анимация (сообщение меняется по кадрам).'
    ].join("\n")
  end

  # Запасной режим без ImageMagick: одно сообщение + edit_message_text.
  def deliver_animation_text(bot, chat_id, frames)
    delay = Float(ENV.fetch('TELEGRAM_ANIM_DELAY', DEFAULT_ANIM_DELAY_SEC))
    slides = frames.map { |frame| truncate_for_telegram(frame.to_s) }

    first = slides.first.to_s
    resp = bot.api.send_message(chat_id: chat_id, text: first)
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
      unless edit.is_a?(Hash) && edit['ok']
        retry_after = telegram_retry_after(edit)
        if retry_after
          bot.logger.warn("edit_message_text rate limited: #{retry_after}s")
          return rate_limit_message(retry_after)
        end
        bot.logger.warn("edit_message_text: #{edit.inspect}")
      end
    rescue StandardError => e
      bot.logger.warn("edit_message_text failed: #{e.class}: #{e.message}")
      return rate_limit_message(parse_retry_after(e.message)) if rate_limited_message?(e.message)

      break
    end

    nil
  end

  def gif_output_enabled?
    ENV.fetch('TELEGRAM_GIF', '1') != '0'
  end

  def nick_gif_response?(command, response)
    return false unless NICK_COMMANDS.include?(command)
    return false if response.to_s.start_with?('Usage:')

    true
  end

  def nickname_gif_frames(nickname)
    clipped = clip_animation_text(nickname.to_s)
    telegram_animation_frames(:typewriter, clipped).map { |line| strip_ansi(line.to_s) }
  end

  def cleanup_gif_workdir(gif_path)
    dir = File.dirname(gif_path)
    FileUtils.rm_rf(dir) if dir && File.directory?(dir)
  rescue StandardError
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

  def telegram_retry_after(resp)
    return nil unless resp.is_a?(Hash) && resp['error_code'] == 429

    params = resp['parameters']
    params = JSON.parse(params) if params.is_a?(String)
    (params && (params['retry_after'] || params[:retry_after])) || 60
  end

  def rate_limit_message(seconds)
    sec = seconds.to_i
    sec = 30 if sec <= 0
    "Слишком много запросов к Telegram. Подождите #{sec} сек и попробуйте снова."
  end

  def rate_limited_message?(message)
    msg = message.to_s
    msg.include?('429') || msg.include?('Too Many Requests') || msg.include?('retry after')
  end

  def parse_retry_after(message)
    m = message.to_s.match(/retry after (\d+)/i)
    m ? m[1].to_i : 60
  end

  def frames_for_gif(style, text, default_frames)
    return rainbow_gif_colored_frames(text) if style == :rainbow

    default_frames
  end

  def rainbow_gif_colored_frames(text)
    RAINBOW_GIF_COLORS.size.times.map do |offset|
      colored = text.chars.map.with_index do |ch, idx|
        { char: ch, color: RAINBOW_GIF_COLORS[(idx + offset) % RAINBOW_GIF_COLORS.size] }
      end
      { colored: colored }
    end
  end

  def normalize_gif_frames(frames)
    Array(frames).reject(&:nil?).map do |f|
      next f if f.is_a?(Hash) && f[:colored]

      strip_ansi(f.to_s)
    end
  end

  def text_frames_from_gif(frames)
    normalize_gif_frames(frames).map do |f|
      if f.is_a?(Hash) && f[:colored]
        f[:colored].map { |s| s[:char] || s['char'] }.join
      else
        f.to_s
      end
    end
  end

  # Текстовый fallback: для rainbow — эмодзи-кадры, не сырой Hash.
  def animation_text_frames(style, text, frames)
    return rainbow_frames_for_telegram(text) if style == :rainbow && text && !text.to_s.strip.empty?

    list = Array(frames)
    return text_frames_from_gif(list) if list.any? { |f| f.is_a?(Hash) && f[:colored] }

    list.map { |f| strip_ansi(f.to_s) }
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

  # Текстовый режим (TELEGRAM_GIF=0): эмодзи-радуга в чате.
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
      '/animate <style> <text> — example: /animate wave Maxim',
      'GIF: TELEGRAM_GIF=1 + ImageMagick (magick). TELEGRAM_GIF=0 = only text animation',
      "Available styles: #{SUPPORTED_ANIMATIONS.join(', ')}"
    ].join("\n")
  end
end
