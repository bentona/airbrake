module Airbrake
  module Rack
    # Airbrake Rack middleware for Rails and Sinatra applications (or any other
    # Rack-compliant app). Any errors raised by the upstream application will be
    # delivered to Airbrake and re-raised.
    #
    # The middleware automatically sends information about the framework that
    # uses it (name and version).
    #
    # For Rails apps the middleware collects route performance statistics.
    class Middleware
      # @return [Array<Class>] the list of Rack filters that read Rack request
      #   information and append it to notices
      RACK_FILTERS = [
        Airbrake::Rack::ContextFilter,
        Airbrake::Rack::SessionFilter,
        Airbrake::Rack::HttpParamsFilter,
        Airbrake::Rack::HttpHeadersFilter,
        Airbrake::Rack::RouteFilter,

        # Optional filters (must be included by users):
        # Airbrake::Rack::RequestBodyFilter
      ].freeze

      # An Array that holds notifier names, which are known to be associated
      # with particular Airbrake Rack middleware.
      # rubocop:disable Style/ClassVars
      @@known_notifiers = []
      # rubocop:enable Style/ClassVars

      def initialize(app, notifier_name = :default)
        @app = app
        @notifier = Airbrake[notifier_name]

        # Prevent adding same filters to the same notifier.
        return if @@known_notifiers.include?(notifier_name)
        @@known_notifiers << notifier_name

        return unless @notifier
        RACK_FILTERS.each do |filter|
          @notifier.add_filter(filter.new)
        end

        return unless defined?(Rails)
        subscribe_route_stats_hook
      end

      # Rescues any exceptions, sends them to Airbrake and re-raises the
      # exception.
      # @param [Hash] env the Rack environment
      def call(env)
        # rubocop:disable Lint/RescueException
        begin
          response = @app.call(env)
        rescue Exception => ex
          notify_airbrake(ex, env)
          raise ex
        end
        # rubocop:enable Lint/RescueException

        exception = framework_exception(env)
        notify_airbrake(exception, env) if exception

        response
      end

      private

      def notify_airbrake(exception, env)
        notice = @notifier.build_notice(exception)
        return unless notice

        # ActionDispatch::Request correctly captures server port when using SSL:
        # See: https://github.com/airbrake/airbrake/issues/802
        notice.stash[:rack_request] =
          if defined?(ActionDispatch::Request)
            ActionDispatch::Request.new(env)
          elsif defined?(Sinatra::Request)
            Sinatra::Request.new(env)
          else
            ::Rack::Request.new(env)
          end

        @notifier.notify(notice)
      end

      # Web framework middlewares often store rescued exceptions inside the
      # Rack env, but Rack doesn't have a standard key for it:
      #
      # - Rails uses action_dispatch.exception: https://goo.gl/Kd694n
      # - Sinatra uses sinatra.error: https://goo.gl/LLkVL9
      # - Goliath uses rack.exception: https://goo.gl/i7e1nA
      def framework_exception(env)
        env['action_dispatch.exception'] ||
          env['sinatra.error'] ||
          env['rack.exception']
      end

      def subscribe_route_stats_hook
        ActiveSupport::Notifications.subscribe(
          'process_action.action_controller'
        ) do |*args|
          @all_routes ||= find_all_routes

          event = ActiveSupport::Notifications::Event.new(*args)
          payload = event.payload

          if (route = find_route(payload[:params]))
            @notifier.notify_request(
              method: payload[:method],
              route: route,
              status_code: find_status_code(payload),
              start_time: event.time,
              end_time: Time.new
            )
          else
            @config.logger.info(
              "#{LOG_LABEL} Rack::Middleware#route_stats_hook: couldn't find " \
              "a route for path: #{payload[:path]}"
            )
          end
        end
      end

      def find_route(params)
        @all_routes.each do |r|
          if r.defaults[:controller] == params['controller'] &&
             r.defaults[:action] == params['action']
            return r.path.spec.to_s
          end
        end
      end

      # Finds all routes that the app supports, including engines.
      def find_all_routes
        routes = [*::Rails.application.routes.routes.routes]
        ::Rails::Engine.subclasses.each do |engine|
          routes.push(*engine.routes.routes.routes)
        end
        routes
      end

      def find_status_code(payload)
        return payload[:status] if payload[:status]

        if payload[:exception]
          status = ActionDispatch::ExceptionWrapper.status_code_for_exception(
            payload[:exception].first
          )
          status = 500 if status == 0

          return status
        end

        0
      end
    end
  end
end
