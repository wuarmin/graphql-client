# frozen_string_literal: true
require "json"
require "net/http"
require "uri"

module GraphQL
  class Client
    # Public: Basic HTTP network adapter.
    #
    #   GraphQL::Client.new(
    #     execute: GraphQL::Client::HTTP.new("http://graphql-swapi.parseapp.com/")
    #   )
    #
    # Assumes GraphQL endpoint follows the express-graphql endpoint conventions.
    #   https://github.com/graphql/express-graphql#http-usage
    #
    # Production applications should consider implementing their own network
    # adapter. This class exists for trivial stock usage and allows for minimal
    # request header configuration.
    class HTTP
      # Public: An unexpected HTTP status, with the original response attached.
      class HTTPError < StandardError
        attr_reader :response

        def initialize(response, message = "HTTP #{response.code} #{response.message}")
          @response = response
          super(message)
        end

        def status
          response.code.to_i
        end
      end

      # Public: A response that could not be decoded as a GraphQL result.
      class InvalidResponseError < HTTPError
      end

      # Public: Create HTTP adapter instance for a single GraphQL endpoint.
      #
      #   GraphQL::Client::HTTP.new("http://graphql-swapi.parseapp.com/") do
      #     def headers(context)
      #       { "User-Agent": "My Client" }
      #     end
      #   end
      #
      # uri - String endpoint URI
      # strict - Raise HTTPError or InvalidResponseError for transport failures
      # block - Optional block to configure class
      def initialize(uri, strict: false, &block)
        @uri = URI.parse(uri)
        @strict = strict
        singleton_class.class_eval(&block) if block_given?
      end

      # Public: Parsed endpoint URI
      #
      # Returns URI.
      attr_reader :uri

      # Public: Extension point for subclasses to set custom request headers.
      #
      # Returns Hash of String header names and values.
      def headers(_context)
        {}
      end

      # Public: full reponse from last request
      #
      # Returns Hash.
      attr_reader :last_response

      # Public: Make an HTTP request for GraphQL query.
      #
      # Implements Client's "execute" adapter interface.
      #
      # document - The Query GraphQL::Language::Nodes::Document
      # operation_name - The String operation definition name
      # variables - Hash of query variables
      # context - An arbitrary Hash of values which you can access
      #
      # Returns { "data" => ... , "errors" => ... } Hash.
      def execute(document:, operation_name: nil, variables: {}, context: {})
        request = Net::HTTP::Post.new(uri.request_uri)

        request.basic_auth(uri.user, uri.password) if uri.user || uri.password

        request["Accept"] = "application/json"
        request["Content-Type"] = "application/json"
        headers(context).each { |name, value| request[name] = value }

        body = {}
        body["query"] = document.to_query_string
        body["variables"] = variables if variables.any?
        body["operationName"] = operation_name if operation_name
        request.body = JSON.generate(body)

        response = connection.request(request)
        @last_response = response.to_hash
        case response
        when Net::HTTPOK, Net::HTTPBadRequest
          parse_response(response)
        else
          raise HTTPError.new(response) if @strict
          { "errors" => [{ "message" => "#{response.code} #{response.message}" }] }
        end
      end

      # Public: Extension point for subclasses to customize the Net:HTTP client
      #
      # Returns a Net::HTTP object
      def connection
        Net::HTTP.new(uri.host, uri.port).tap do |client|
          client.use_ssl = uri.scheme == "https"
        end
      end

      private

      def parse_response(response)
        result = JSON.parse(@strict ? response.body.to_s : response.body)
        if @strict && !(result.is_a?(Hash) && (result.key?("data") || result.key?("errors")))
          raise InvalidResponseError.new(response, "Invalid GraphQL response (HTTP #{response.code})")
        end
        result
      rescue JSON::ParserError
        raise unless @strict
        raise InvalidResponseError.new(response, "Non-JSON response (HTTP #{response.code})")
      end
    end
  end
end
