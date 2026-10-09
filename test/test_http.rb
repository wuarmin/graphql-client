# frozen_string_literal: true
require "graphql"
require "graphql/client/http"
require "minitest/autorun"
require "minitest/mock"

class TestStrictHTTP < Minitest::Test
  def execute_response(status, body, **options)
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(status).new("1.1", status, "Test response")
    response.instance_variable_set(:@read, true)
    response.body = body
    response["X-Request-Id"] = "request-123"
    adapter = GraphQL::Client::HTTP.new("https://example.com/graphql", **options)
    connection = Minitest::Mock.new
    connection.expect(:request, response, [Net::HTTP::Post])
    result = adapter.stub(:connection, connection) do
      adapter.execute(document: GraphQL.parse("{ name }"))
    end
    connection.verify
    assert_equal(response.to_hash, adapter.last_response)
    result
  end

  def test_graphql_results_are_preserved
    ["200", "400"].each do |status|
      [{ "data" => { "name" => "Luke" } },
       { "errors" => [{ "message" => "Rejected" }] },
       { "data" => nil, "errors" => [{ "message" => "Failed" }] },
       { "data" => { "name" => nil }, "errors" => [{ "message" => "Failed", "path" => ["name"] }] }].each do |result|
        assert_equal(result, execute_response(status, JSON.generate(result), strict: true))
      end
    end
  end

  def test_http_errors_preserve_response
    %w[401 429 502 503 504].each do |status|
      error = assert_raises(GraphQL::Client::HTTP::HTTPError) do
        execute_response(status, "<html>Unavailable</html>", strict: true)
      end
      assert_equal(status.to_i, error.status)
      assert_equal("<html>Unavailable</html>", error.response.body)
      assert_equal("request-123", error.response["X-Request-Id"])
    end
  end

  def test_non_json_responses_preserve_response_and_cause
    %w[200 400].each do |status|
      error = assert_raises(GraphQL::Client::HTTP::InvalidResponseError) do
        execute_response(status, "<html>Unavailable</html>", strict: true)
      end
      assert_equal(status.to_i, error.status)
      assert_equal("<html>Unavailable</html>", error.response.body)
      assert_kind_of(JSON::ParserError, error.cause)
    end
  end

  def test_invalid_graphql_responses
    ["{}", "[]", "null", "42", '{"message":"Unavailable"}'].each do |body|
      error = assert_raises(GraphQL::Client::HTTP::InvalidResponseError) do
        execute_response("200", body, strict: true)
      end
      assert_equal(200, error.status)
      assert_equal(body, error.response.body)
    end
  end

  def test_empty_response
    error = assert_raises(GraphQL::Client::HTTP::InvalidResponseError) do
      execute_response("200", nil, strict: true)
    end
    assert_equal(200, error.status)
  end

  def test_default_behavior_is_preserved
    [{}, { strict: false }].each do |options|
      assert_equal({ "errors" => [{ "message" => "503 Test response" }] }, execute_response("503", "unavailable", **options))
      assert_equal({}, execute_response("200", "{}", **options))
      assert_raises(JSON::ParserError) { execute_response("200", "not json", **options) }
    end
  end

  def test_network_errors_are_not_wrapped
    [Net::ReadTimeout.new, Errno::ECONNREFUSED.new].each do |original|
      adapter = GraphQL::Client::HTTP.new("https://example.com/graphql", strict: true)
      connection = Object.new
      connection.define_singleton_method(:request) { |_request| raise original }
      error = assert_raises(original.class) do
        adapter.stub(:connection, connection) do
          adapter.execute(document: GraphQL.parse("{ name }"))
        end
      end
      assert_same(original, error)
    end
  end
end

class TestHTTP < Minitest::Test
  SWAPI = GraphQL::Client::HTTP.new("https://mpjk0plp9.lp.gql.zone/graphql") do
    def headers(_context)
      { "User-Agent" => "GraphQL/1.0" }
    end
  end

  def test_execute
    skip "TestHTTP disabled by default" unless __FILE__ == $PROGRAM_NAME

    document = GraphQL.parse(<<-'GRAPHQL')
      query getCharacter($id: ID!) {
        character(id: $id) {
          name
        }
      }
    GRAPHQL

    name = "getCharacter"
    variables = { "id" => "1001" }

    expected = {
      "data" => {
        "character" => {
          "name" => "Darth Vader"
        }
      }
    }
    actual = SWAPI.execute(document: document, operation_name: name, variables: variables)
    assert_equal(expected, actual)
  end
end
