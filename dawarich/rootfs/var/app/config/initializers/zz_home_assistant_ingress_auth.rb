require 'json'
require 'net/http'
require 'securerandom'
require 'uri'

module HomeAssistantIngressAuth
  SECRET_HEADER = 'HTTP_X_DAWARICH_INGRESS_SECRET'
  USER_ID_HEADER = 'HTTP_X_REMOTE_USER_ID'
  USER_NAME_HEADER = 'HTTP_X_REMOTE_USER_NAME'
  DISPLAY_NAME_HEADER = 'HTTP_X_REMOTE_USER_DISPLAY_NAME'

  SUPERVISOR_AUTH_LIST_URL = 'http://supervisor/auth/list'
  CORE_CONFIG_URL = 'http://supervisor/core/api/config'
  EMAIL_DOMAIN = 'hass.example.com'
  CACHE_TTL = 60

  module_function

  def enabled?
    ENV['INGRESS_AUTH_SECRET'].to_s != ''
  end

  def authenticated_request?(request)
    enabled? && request.get_header(SECRET_HEADER) == ENV['INGRESS_AUTH_SECRET'].to_s && request.get_header(USER_ID_HEADER).to_s != ''
  end

  def user_for(request)
    identity = identity_from_request(request)
    ha_user = home_assistant_user(identity[:user_id])
    config = home_assistant_config
    admin = ha_admin?(ha_user)
    family_name = family_name_from_config(config)

    User.transaction do
      user = find_user(identity[:user_id]) || find_legacy_user(identity[:user_id]) || User.find_or_initialize_by(email: email_for(identity, identity[:user_id]))
      assign_password(user) if user.new_record?
      apply_identity!(user, identity, ha_user, config, admin, family_name)
      ensure_family_membership!(user, family_name)
      user
    end
  end

  def identity_from_request(request)
    {
      user_id: request.get_header(USER_ID_HEADER).to_s.strip,
      user_name: request.get_header(USER_NAME_HEADER).to_s.strip,
      display_name: request.get_header(DISPLAY_NAME_HEADER).to_s.strip
    }
  end

  def find_user(ha_user_id)
    User.where("settings -> 'home_assistant' ->> 'user_id' = ?", ha_user_id).first
  rescue StandardError
    nil
  end

  def find_legacy_user(ha_user_id)
    User.find_by(email: "ha-#{ha_user_id}@homeassistant.local")
  end

  def apply_identity!(user, identity, ha_user, config, admin, family_name)
    preferred_name = identity[:display_name].presence || identity[:user_name].presence

    user.email = unique_email_for(user, identity)
    user.name = preferred_name if preferred_name.present? && user.respond_to?(:name=)
    user.username = preferred_name if preferred_name.present? && user.respond_to?(:username=)
    user.admin = true if admin && user.respond_to?(:admin=)
    user.settings = settings_with_home_assistant(user.settings, identity, ha_user, config, admin, family_name) if user.respond_to?(:settings=)
    user.save! if user.new_record? || user.changed?
  end

  def settings_with_home_assistant(settings, identity, ha_user, config, admin, family_name)
    next_settings = settings.is_a?(Hash) ? settings.deep_dup : {}
    next_settings['home_assistant'] = {
      'user_id' => identity[:user_id],
      'user_name' => identity[:user_name],
      'display_name' => identity[:display_name],
      'admin' => admin,
      'family_name' => family_name,
      'location_name' => config_value(config, 'location_name'),
      'time_zone' => config_value(config, 'time_zone'),
      'latitude' => config_value(config, 'latitude'),
      'longitude' => config_value(config, 'longitude')
    }
    next_settings
  end

  def assign_password(user)
    password = SecureRandom.hex(32)
    user.password = password
    user.password_confirmation = password
  end

  def home_assistant_user(ha_user_id)
    home_assistant_users.find { |user| config_value(user, 'id').to_s == ha_user_id.to_s } || {}
  end

  def home_assistant_users
    cached(:home_assistant_users) do
      data = fetch_json(SUPERVISOR_AUTH_LIST_URL)
      users = config_value(config_value(data, 'data'), 'users') || config_value(data, 'users') || config_value(data, 'data')
      users.is_a?(Array) ? users : []
    end
  end

  def home_assistant_config
    cached(:home_assistant_config) do
      data = fetch_json(CORE_CONFIG_URL)
      data.is_a?(Hash) ? data : {}
    end
  end

  def cached(key)
    cache = (@cache ||= {})
    entry = cache[key]

    return entry[:value] if entry && entry[:expires_at] > Time.now

    cache[key] = { value: yield, expires_at: Time.now + CACHE_TTL }
    cache[key][:value]
  end

  def fetch_json(url)
    token = ENV['SUPERVISOR_TOKEN'].to_s
    return {} if token == ''

    uri = URI.parse(url)
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{token}"
    request['Accept'] = 'application/json'

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 3) do |http|
      http.request(request)
    end

    return {} unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue StandardError => e
    Rails.logger.warn("Home Assistant metadata fetch failed for #{url}: #{e.class}: #{e.message}") if defined?(Rails)
    {}
  end

  def ha_admin?(ha_user)
    return false unless ha_user.is_a?(Hash)

    return true if truthy?(config_value(ha_user, 'is_owner')) || truthy?(config_value(ha_user, 'admin'))

    group_ids = Array(config_value(ha_user, 'group_ids')).map { |group| group.to_s.downcase }
    groups = Array(config_value(ha_user, 'groups')).map { |group| group.is_a?(Hash) ? config_value(group, 'id') : group }.map { |group| group.to_s.downcase }
    (group_ids + groups).include?('admin') || (group_ids + groups).include?('system-admin')
  end

  def truthy?(value)
    value == true || value.to_s.casecmp('true').zero? || value.to_s == '1'
  end

  def email_for(identity, fallback)
    local_part = normalize_local_part(identity[:user_name].presence || identity[:display_name].presence || fallback)
    "#{local_part}@#{EMAIL_DOMAIN}"
  end

  def unique_email_for(user, identity)
    base_email = email_for(identity, identity[:user_id])
    return base_email if email_available?(user, base_email)

    local, domain = base_email.split('@', 2)
    suffix = 2

    loop do
      email = "#{local}-#{suffix}@#{domain}"
      return email if email_available?(user, email)

      suffix += 1
    end
  end

  def email_available?(user, email)
    scope = User.where(email: email)
    scope = scope.where.not(id: user.id) if user.persisted?
    !scope.exists?
  end

  def normalize_local_part(value)
    normalized = ActiveSupport::Inflector.transliterate(value.to_s)
    normalized = normalized.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
    normalized.presence || 'home-assistant-user'
  end

  def family_name_from_config(config)
    location_name = config_value(config, 'location_name').to_s.strip
    time_zone = config_value(config, 'time_zone').to_s.strip
    name = location_name.presence || 'Home Assistant Family'

    if generic_home_name?(name) && time_zone.include?('/')
      region = time_zone.split('/').last.tr('_', ' ')
      name = "#{name} - #{region}" if region.present?
    end

    name
  end

  def generic_home_name?(name)
    %w[home house household].include?(name.to_s.strip.downcase)
  end

  def ensure_family_membership!(user, family_name)
    return unless defined?(Family) && family_name.present?

    family = find_or_create_family(user, family_name)
    attach_user_to_family(user, family) if family
  rescue StandardError => e
    Rails.logger.warn("Home Assistant family provisioning failed: #{e.class}: #{e.message}") if defined?(Rails)
  end

  def find_or_create_family(user, family_name)
    family = Family.find_by(name: family_name)
    return family if family

    if defined?(Families::Create)
      created = create_family_with_service(user, family_name)
      return created if created.is_a?(Family)
      family = Family.find_by(name: family_name)
      return family if family
    end

    family = Family.new(name: family_name)
    set_family_owner(family, user)
    family.save!
    family
  end

  def create_family_with_service(user, family_name)
    service = Families::Create
    attempts = [
      -> { service.new(user, name: family_name).call },
      -> { service.new(user: user, name: family_name).call },
      -> { service.new(user, family_name).call },
      -> { service.call(user, name: family_name) },
      -> { service.call(user: user, name: family_name) }
    ]

    attempts.each do |attempt|
      result = attempt.call
      return result if result
    rescue ArgumentError, NoMethodError
      next
    end

    nil
  end

  def set_family_owner(family, user)
    %w[user_id owner_id creator_id created_by_id].each do |attribute|
      family.public_send("#{attribute}=", user.id) if family.respond_to?("#{attribute}=")
    end

    %w[user owner creator created_by].each do |association|
      family.public_send("#{association}=", user) if family.respond_to?("#{association}=")
    end
  end

  def attach_user_to_family(user, family)
    if family.respond_to?(:users)
      family.users << user unless family.users.where(id: user.id).exists?
      return
    end

    if user.respond_to?(:families)
      user.families << family unless user.families.where(id: family.id).exists?
      return
    end

    user.family = family if user.respond_to?(:family=) && user.family != family
    user.save! if user.changed?
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    nil
  end

  def config_value(hash, key)
    return nil unless hash.respond_to?(:[])

    hash[key] || hash[key.to_sym]
  end
end

ActiveSupport.on_load(:action_controller_base) do
  prepend_before_action :home_assistant_ingress_sign_in

  private

  def home_assistant_ingress_sign_in
    return unless HomeAssistantIngressAuth.authenticated_request?(request)

    user = HomeAssistantIngressAuth.user_for(request)
    request.env['warden'].set_user(user, scope: :user)

    return unless request.path.match?(%r{/(users|admin|account)/sign_in\z|/users/sign_up\z|/users/password/new\z})

    redirect_to(root_path)
  rescue StandardError => e
    Rails.logger.warn("Home Assistant ingress auth failed: #{e.class}: #{e.message}")
  end
end
