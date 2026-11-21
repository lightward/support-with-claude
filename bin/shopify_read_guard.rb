# The guard prod_read.sh --shopify-read loads before a script, inside Locksmith's Rails app. A script that reads from
# Shopify can't run in a rolled-back transaction, because getting a session can refresh the shop's token and that
# refresh must stick (it's Shopify's protocol, and Isaac's stance is that we stay exposed to it, visibly). So instead:
#
# - Database, at the one place every statement passes (PG::Connection, under Rails and around it): anything that could
#   write is refused (and anything with a second statement in it), except a single-row UPDATE of the shops table that sets only the columns Shopify's token and
#   availability protocol writes (Shop::TokenRefreshConcern::TOKEN_COLUMNS, the granted scopes, the unavailable mark).
#   Each one let through is printed with its columns. No statement timeout: production pools connections through
#   pgbouncer in transaction mode (database.yml), where a session SET would leak to other clients and SET LOCAL needs a
#   transaction this mode can't hold open; the wrapper's 240s wall clock is the bound, and scripts stay narrow.
# - Outbound HTTP, at Net::HTTP (which ShopifyAPI and HTTParty both ride on): GET and HEAD anywhere; POST only to a
#   shop's /admin/oauth/access_token (the refresh, or the one-way legacy exchange), to a GraphQL endpoint with no
#   mutation in its decoded query, and to Rollbar. GraphQL over GET, and streamed bodies, are refused.
# - Background jobs: enqueueing anything is refused, since a job would run later on a worker with no guard.
#
# These catch accidents in scripts that have been read; they don't stop a deliberate bypass. That's why the standing go
# covers only scripts committed in bin/.
require "json"

module ShopifyReadGuard
  PROTOCOL_COLUMNS = (Shop::TokenRefreshConcern::TOKEN_COLUMNS.map(&:to_s) +
    %w[shopify_access_scopes_granted shopify_store_unavailable_at shopify_store_unavailable_reason]).freeze
  READ_ONLY_SHAPES = /\A\s*(SELECT|WITH|SHOW|EXPLAIN|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|DECLARE|FETCH|MOVE|CLOSE|SET\s+((LOCAL|SESSION)\s+)?(statement_timeout|client_min_messages|standard_conforming_strings|intervalstyle|timezone|time\s+zone|application_name|search_path)\b)/i
  WRITE_WORDS = /\b(insert|update|delete|truncate|merge|copy|into|nextval|setval|pg_terminate_backend|pg_cancel_backend|set_config|lo_\w+|drop|alter|create|grant|revoke|vacuum|reindex|cluster|lock|notify|call|do)\b/i

  module_function

  VALUE = %q{(?:\$\d+|NULL|'(?:[^']|'')*'|-?\d+(?:\.\d+)?)} # standard_conforming_strings is on, so a quote is escaped only by doubling
  ASSIGN = %q{"(\w+)"\s*=\s*} + VALUE
  PROTOCOL_UPDATE = /\A\s*UPDATE\s+"shops"\s+SET\s+(#{ASSIGN}(?:\s*,\s*#{ASSIGN})*)\s+WHERE\s+"shops"\."id"\s*=\s*#{VALUE}(?:\s+AND\s+"shops"\."shopify_token"\s*(?:=\s*#{VALUE}|IS\s+NULL))?\s*\z/i
  HARMLESS = /\A\s*(;|DISCARD\s+ALL)\s*\z/i

  def check_sql!(sql)
    sql = sql.to_s
    return if sql.match?(HARMLESS)
    if sql.match?(/;\s*\S/) || sql.match?(/\bE'/i)
      raise ActiveRecord::ReadOnlyError, "[shopify-read] refused a multi-statement or E-string query: #{sql[0, 70]}"
    end
    return if protocol_write?(sql)

    stripped = sql.gsub(/'(?:[^']|'')*'/, "''") # string literals can't write
    writes = !stripped.match?(READ_ONLY_SHAPES) ||
      stripped.gsub(/\bFOR\s+(NO\s+KEY\s+)?UPDATE\b/i, "").match?(WRITE_WORDS) ||
      stripped.match?(/\AEXPLAIN\s+(\(.*\bANALYZE\b.*\)|ANALYZE)/im)
    raise ActiveRecord::ReadOnlyError, "[shopify-read] refused a statement that could write: #{sql[0, 70]}" if writes
  end

  # The only writes let through: the shapes Rails builds for the token protocol's update_columns and update_all
  # (token_refresh_concern.rb), one shop by id, setting protocol columns to plain values.
  def protocol_write?(sql)
    m = sql.match(PROTOCOL_UPDATE) or return false
    cols = m[1].scan(/"(\w+)"\s*=/).flatten.uniq
    return false unless (cols - PROTOCOL_COLUMNS).empty?

    loud = cols.include?("shopify_token_exchange_started_at") ? " (a legacy token exchange: one-way, Shopify's protocol)" : ""
    $stderr.puts "[shopify-read] let through: UPDATE shops (#{cols.join(", ")})#{loud}"
    true
  end

  def check_http!(http, req, body)
    verb = req.method.to_s.upcase
    host = http.address.to_s
    path = req.path.to_s
    return if %w[GET HEAD].include?(verb) && !path.include?("graphql")
    raise "[shopify-read] refused a streamed #{verb} body to #{host}" if req.respond_to?(:body_stream) && req.body_stream
    if verb == "POST"
      return if host.end_with?(".myshopify.com") && path.start_with?("/admin/oauth/access_token")
      return if host == "api.rollbar.com"
      if path.split("?").first.end_with?("graphql.json", "/graphql")
        raw = (body || req.body).to_s
        query = begin
          parsed = JSON.parse(raw)
          parsed.is_a?(Hash) ? parsed["query"].to_s : raw
        rescue JSON::ParserError
          raw
        end
        return unless query.match?(/\bmutation\b/i)
      end
    end
    raise "[shopify-read] refused #{verb} #{host}#{path.split("?").first}"
  end

  module PG
    %i[exec query async_exec async_query sync_exec exec_params async_exec_params sync_exec_params send_query send_query_params].each do |m|
      define_method(m) do |sql, *args, **kw, &blk|
        ShopifyReadGuard.check_sql!(sql)
        super(sql, *args, **kw, &blk)
      end
    end

    %i[prepare async_prepare sync_prepare send_prepare].each do |m|
      define_method(m) do |name, sql, *args, **kw, &blk|
        ShopifyReadGuard.check_sql!(sql)
        super(name, sql, *args, **kw, &blk)
      end
    end

    def copy_data(sql, *args, **kw, &blk)
      ShopifyReadGuard.check_sql!(sql)
      super
    end
  end

  module HTTP
    def request(req, body = nil, &blk)
      ShopifyReadGuard.check_http!(self, req, body)
      super
    end
  end

  module NoJobs
    def push(*) = raise("[shopify-read] refused to enqueue a background job")
    def push_bulk(*) = raise("[shopify-read] refused to enqueue background jobs")
  end
end

::PG::Connection.prepend(ShopifyReadGuard::PG)
::Net::HTTP.prepend(ShopifyReadGuard::HTTP)
::Sidekiq::Client.prepend(ShopifyReadGuard::NoJobs)
