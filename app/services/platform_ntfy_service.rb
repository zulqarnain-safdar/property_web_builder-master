# frozen_string_literal: true

# Service for sending platform-level push notifications via ntfy.sh
#
# Unlike NtfyService (which handles per-tenant notifications), this service
# sends notifications to platform administrators about cross-tenant events:
# - User signups
# - Website provisioning
# - Subscription lifecycle changes
# - System health alerts
#
# Configuration via Rails credentials (rails credentials:edit):
#   platform_ntfy:
#     topic: pwb-platform-alerts
#     server_url: https://ntfy.sh  # optional, defaults to https://ntfy.sh
#     access_token: tk_xxxxx       # optional, for private topics
#
# The service is enabled if credentials.platform_ntfy.topic is present.
#
# Usage:
#   PlatformNtfyService.notify_user_signup(user, reserved_subdomain: 'acme')
#   PlatformNtfyService.notify_provisioning_complete(website)
#   PlatformNtfyService.notify_subscription_activated(subscription)
#
class PlatformNtfyService
  # Priority levels (ntfy uses 1-5, with 3 as default)
  PRIORITY_MIN = 1
  PRIORITY_LOW = 2
  PRIORITY_DEFAULT = 3
  PRIORITY_HIGH = 4
  PRIORITY_URGENT = 5

  class << self
    # ===================
    # User Lifecycle Events
    # ===================

    # Notify when a new user signs up
    #
    # @param user [Pwb::User] The newly registered user
    # @param reserved_subdomain [String] The subdomain they reserved
    def notify_user_signup(user, reserved_subdomain: nil)
      return unless enabled?

      publish(
        title: '🎉 New User Signup',
        message: build_signup_message(user, reserved_subdomain),
        priority: PRIORITY_HIGH,
        tags: ['wave', 'bust_in_silhouette'],
        click_url: tenant_admin_user_url(user)
      )
    end

    # Notify when a user verifies their email
    #
    # @param user [Pwb::User] The user who verified email
    def notify_email_verified(user)
      return unless enabled?

      publish(
        title: '✅ Email Verified',
        message: "#{user.email} has verified their email address",
        priority: PRIORITY_DEFAULT,
        tags: ['white_check_mark', 'email'],
        click_url: tenant_admin_user_url(user)
      )
    end

    # Notify when a user completes onboarding
    #
    # @param user [Pwb::User] The user
    # @param website [Pwb::Website] Their new website
    def notify_onboarding_complete(user, website)
      return unless enabled?

      publish(
        title: '🎊 Onboarding Complete',
        message: "#{user.email} finished setup\nWebsite: #{website.subdomain}",
        priority: PRIORITY_HIGH,
        tags: ['tada', 'house'],
        click_url: website_url(website)
      )
    end

    # ===================
    # Website Provisioning Events
    # ===================

    # Notify when website provisioning starts
    #
    # @param website [Pwb::Website] The website being provisioned
    def notify_provisioning_started(website)
      return unless enabled?

      publish(title: '⚙️ Provisioning Started',
        message: build_provisioning_message(website, 'started'),
        priority: PRIORITY_DEFAULT,
        tags: ['gear', 'hourglass'],
        click_url: tenant_admin_website_url(website)
      )
    end

    # Notify when website goes live
    #
    # @param website [Pwb::Website] The website that's now live
    def notify_provisioning_complete(website)
      return unless enabled?

      owner = website.owner
      publish(title: '✅ Website Live',
        message: build_provisioning_message(website, 'complete'),
        priority: PRIORITY_HIGH,
        tags: ['white_check_mark', 'rocket'],
        click_url: website_url(website),
        actions: [
          { type: 'view', label: 'Visit Site', url: website_url(website) },
          { type: 'view', label: 'Admin', url: tenant_admin_website_url(website) }
        ]
      )
    end

    # Notify when provisioning fails
    #
    # @param website [Pwb::Website] The website that failed
    # @param error [String] Error message
    def notify_provisioning_failed(website, error)
      return unless enabled?

      publish(title: '❌ Provisioning Failed',
        message: "Subdomain: #{website.subdomain}\nError: #{error}",
        priority: PRIORITY_URGENT,
        tags: ['x', 'warning'],
        click_url: tenant_admin_website_url(website)
      )
    end

    # ===================
    # Subscription Events
    # ===================

    # Notify when a trial starts
    #
    # @param subscription [Pwb::Subscription] The new subscription
    def notify_trial_started(subscription)
      return unless enabled?

      publish(title: '🆓 Trial Started',
        message: build_subscription_message(subscription, 'trial_started'),
        priority: PRIORITY_DEFAULT,
        tags: ['free', 'clock'],
        click_url: tenant_admin_website_url(subscription.website)
      )
    end

    # Notify when subscription is activated (paid)
    #
    # @param subscription [Pwb::Subscription] The activated subscription
    def notify_subscription_activated(subscription)
      return unless enabled?

      publish(title: '💰 Subscription Activated',
        message: build_subscription_message(subscription, 'activated'),
        priority: PRIORITY_HIGH,
        tags: ['moneybag', 'tada'],
        click_url: tenant_admin_website_url(subscription.website)
      )
    end

    # Notify when trial expires without conversion
    #
    # @param subscription [Pwb::Subscription] The expired subscription
    def notify_trial_expired(subscription)
      return unless enabled?

      publish(title: '⏱️ Trial Expired',
        message: build_subscription_message(subscription, 'trial_expired'),
        priority: PRIORITY_DEFAULT,
        tags: ['hourglass', 'disappointed'],
        click_url: tenant_admin_website_url(subscription.website)
      )
    end

    # Notify when subscription is canceled
    #
    # @param subscription [Pwb::Subscription] The canceled subscription
    # @param reason [String] Cancellation reason
    def notify_subscription_canceled(subscription, reason: nil)
      return unless enabled?

      message = build_subscription_message(subscription, 'canceled')
      message += "\nReason: #{reason}" if reason.present?

      publish(title: '😢 Subscription Canceled',
        message: message,
        priority: PRIORITY_HIGH,
        tags: ['disappointed', 'wave'],
        click_url: tenant_admin_website_url(subscription.website)
      )
    end

    # Notify when payment fails
    #
    # @param subscription [Pwb::Subscription] The subscription
    # @param error_details [String] Payment error details
    def notify_payment_failed(subscription, error_details: nil)
      return unless enabled?

      message = build_subscription_message(subscription, 'payment_failed')
      message += "\nError: #{error_details}" if error_details.present?

      publish(title: '⚠️ Payment Failed',
        message: message,
        priority: PRIORITY_URGENT,
        tags: ['warning', 'credit_card'],
        click_url: tenant_admin_website_url(subscription.website)
      )
    end

    # Notify when plan changes
    #
    # @param subscription [Pwb::Subscription] The subscription
    # @param old_plan [Pwb::Plan] Previous plan
    # @param new_plan [Pwb::Plan] New plan
    def notify_plan_changed(subscription, old_plan, new_plan)
      return unless enabled?

      direction = new_plan.price_cents > old_plan.price_cents ? '⬆️ Upgrade' : '⬇️ Downgrade'

      publish(title: "🔄 Plan Changed (#{direction})",
        message: build_plan_change_message(subscription, old_plan, new_plan),
        priority: PRIORITY_DEFAULT,
        tags: ['arrows_counterclockwise'],
        click_url: tenant_admin_website_url(subscription.website)
      )
    end

    # ===================
    # System Events
    # ===================

    # Send a system alert
    #
    # @param title [String] Alert title
    # @param message [String] Alert message
    # @param priority [Integer] Priority level (default: URGENT)
    def notify_system_alert(title, message, priority: PRIORITY_URGENT)
      return unless enabled?

      publish(title: "🚨 #{title}",
        message: message,
        priority: priority,
        tags: ['rotating_light', 'warning']
      )
    end

    # Send daily summary metrics
    #
    # @param metrics [Hash] Metrics data
    def notify_daily_summary(metrics)
      return unless enabled?

      publish(title: '📊 Daily Platform Summary',
        message: build_daily_summary_message(metrics),
        priority: PRIORITY_LOW,
        tags: ['bar_chart', 'calendar'],
        click_url: tenant_admin_dashboard_url
      )
    end

    # ===================
    # Configuration & Testing
    # ===================

    # Test the platform ntfy configuration
    #
    # @return [Hash] Result with :success and :message keys
    def test_configuration
      return { success: false, message: 'Platform ntfy is not configured. Set credentials.platform_ntfy.topic to enable.' } unless enabled?

      result = publish(title: '✅ Test Notification',
        message: "Platform ntfy is configured correctly!\nTime: #{Time.current.strftime('%Y-%m-%d %H:%M:%S')}",
        priority: PRIORITY_DEFAULT,
        tags: ['white_check_mark', 'test_tube']
      )

      if result
        { success: true, message: 'Test notification sent successfully' }
      else
        { success: false, message: 'Failed to send test notification' }
      end
    end

    # Low-level publish method
    #
    # @param message [String] Notification body
    # @param title [String] Notification title
    # @param priority [Integer] Priority level (1-5)
    # @param tags [Array<String>] Emoji tags
    # @param click_url [String] URL to open on click
    # @param actions [Array<Hash>] Action buttons
    # @return [Boolean] Success status
    def publish(message:, title: nil, priority: PRIORITY_DEFAULT, tags: [], click_url: nil, actions: nil)
      return false unless enabled?
      return false if message.blank?

      headers = build_headers(
        title: title,
        priority: priority,
        tags: tags,
        click_url: click_url,
        actions: actions
      )

      perform_request(topic, message, headers)
    end

    # Check if platform ntfy is enabled
    #
    # @return [Boolean]
    def enabled?
      topic.present?
    end

    private

    # ===================
    # Configuration
    # ===================

    def server_url
      credentials.dig(:platform_ntfy, :server_url).presence || 'https://ntfy.sh'
    end

    def topic
      credentials.dig(:platform_ntfy, :topic)
    end

    def access_token
      credentials.dig(:platform_ntfy, :access_token)
    end

    def credentials
      Rails.application.credentials
    end

    # ===================
    # Message Builders
    # ===================

    def build_signup_message(user, subdomain)
      parts = ["Email: #{user.email}"]
      parts << "Subdomain: #{subdomain}" if subdomain.present?
      parts << "Time: #{Time.current.strftime('%Y-%m-%d %H:%M')}"
      parts.join("\n")
    end

    def build_provisioning_message(website, status)
      owner = website.owner
      parts = ["Subdomain: #{website.subdomain}"]
      parts << "Owner: #{owner.email}" if owner
      parts << "Type: #{website.site_type}" if website.site_type.present?
      parts << "Status: #{status}"
      parts.join("\n")
    end

    def build_subscription_message(subscription, event)
      website = subscription.website
      owner = website&.owner
      plan = subscription.plan

      parts = []
      parts << "Website: #{website&.subdomain || 'Unknown'}"
      parts << "Owner: #{owner&.email || 'Unknown'}"
      parts << "Plan: #{plan&.display_name || 'Unknown'}"

      case event
      when 'trial_started'
        parts << "Trial ends: #{subscription.trial_ends_at&.strftime('%Y-%m-%d')}"
      when 'activated'
        parts << "MRR: #{format_currency(plan&.price_cents)}"
      when 'trial_expired'
        parts << "Was on: #{plan&.display_name}"
      when 'canceled'
        parts << "Lost MRR: #{format_currency(plan&.price_cents)}"
      when 'payment_failed'
        parts << "Amount: #{format_currency(plan&.price_cents)}"
      end

      parts.join("\n")
    end

    def build_plan_change_message(subscription, old_plan, new_plan)
      website = subscription.website
      owner = website&.owner
      mrr_change = new_plan.price_cents - old_plan.price_cents

      parts = []
      parts << "Website: #{website&.subdomain}"
      parts << "Owner: #{owner&.email}"
      parts << "Change: #{old_plan.display_name} → #{new_plan.display_name}"
      parts << "MRR Change: #{mrr_change >= 0 ? '+' : ''}#{format_currency(mrr_change)}"
      parts.join("\n")
    end

    def build_daily_summary_message(metrics)
      parts = []
      parts << "📈 Signups Today: #{metrics[:signups_today] || 0}"
      parts << "🏠 Websites Created: #{metrics[:websites_created] || 0}"
      parts << "💰 Subscriptions Activated: #{metrics[:subscriptions_activated] || 0}"
      parts << "😢 Subscriptions Canceled: #{metrics[:subscriptions_canceled] || 0}"
      parts << ""
      parts << "📊 Totals:"
      parts << "  Active Websites: #{metrics[:total_active_websites] || 0}"
      parts << "  MRR: #{format_currency(metrics[:total_mrr_cents] || 0)}"
      parts.join("\n")
    end

    def format_currency(cents)
      return '$0.00' if cents.nil? || cents == 0

      dollars = cents.to_f / 100
      "$#{'%.2f' % dollars}"
    end

    # ===================
    # URL Builders
    # ===================

    def tenant_admin_domain
      ENV.fetch('TENANT_ADMIN_DOMAIN', 'admin.propertywebbuilder.com')
    end

    def platform_domain
      ENV.fetch('PLATFORM_DOMAIN', 'propertywebbuilder.com')
    end

    def tenant_admin_user_url(user)
      "https://#{tenant_admin_domain}/users/#{user.id}"
    end

    def tenant_admin_website_url(website)
      return nil unless website

      "https://#{tenant_admin_domain}/websites/#{website.id}"
    end

    def tenant_admin_dashboard_url
      "https://#{tenant_admin_domain}/dashboard"
    end

    def website_url(website)
      return nil unless website

      if website.custom_domain.present? && website.custom_domain_verified?
        "https://#{website.custom_domain}"
      else
        "https://#{website.subdomain}.#{platform_domain}"
      end
    end

    # ===================
    # HTTP Request
    # ===================

    def build_headers(title:, priority:, tags:, click_url:, actions:)
      headers = {
        'Content-Type' => 'text/plain; charset=utf-8'
      }

      headers['Title'] = title if title.present?
      headers['Priority'] = priority.to_s if priority != PRIORITY_DEFAULT
      headers['Tags'] = tags.join(',') if tags.present?
      headers['Click'] = click_url if click_url.present?
      headers['Actions'] = format_actions(actions) if actions.present?
      headers['Authorization'] = "Bearer #{access_token}" if access_token.present?

      headers
    end

    def format_actions(actions)
      return nil if actions.blank?

      actions.map do |action|
        parts = ["action=#{action[:type]}", "label=#{action[:label]}"]
        parts << "url=#{action[:url]}" if action[:url]
        parts << "method=#{action[:method]}" if action[:method]
        parts.join(', ')
      end.join('; ')
    end

    def perform_request(topic, message, headers)
      uri = URI.parse("#{server_url}/#{topic}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      
      # In development/test, allow self-signed certificates
      # In production, this should be properly configured
      if Rails.env.development? || Rails.env.test?
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      
      http.open_timeout = 5
      http.read_timeout = 10

      request = Net::HTTP::Post.new(uri.request_uri, headers)
      request.body = message.to_s.encode('UTF-8')

      response = http.request(request)

      if response.is_a?(Net::HTTPSuccess)
        Rails.logger.info("[PlatformNtfy] Notification sent to #{topic}")
        true
      else
        Rails.logger.error("[PlatformNtfy] Failed: #{response.code} - #{response.body&.truncate(200)}")
        false
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      Rails.logger.error("[PlatformNtfy] Timeout: #{e.message}")
      false
    rescue SocketError, Errno::ECONNREFUSED => e
      Rails.logger.error("[PlatformNtfy] Connection failed: #{e.message}")
      false
    rescue StandardError => e
      Rails.logger.error("[PlatformNtfy] Error: #{e.class} - #{e.message}")
      false
    end
  end
end
