# Checks bin/shopify_read_guard.rb's SQL and HTTP decisions locally, without Rails: each case says whether the guard
# should allow it. Run after any change to the guard: ruby -rjson -rstringio bin/test_shopify_read_guard.rb (from
# ~/dev/locksmith-api, for its Ruby). Every line should start with "ok".
module Shop; module TokenRefreshConcern; TOKEN_COLUMNS = %i[shopify_token shopify_token_expires_at shopify_refresh_token shopify_refresh_token_expires_at shopify_token_refresh_failed_at shopify_token_exchange_started_at]; end; end
module ActiveRecord; class ReadOnlyError < StandardError; end; end
src = File.read(File.join(__dir__, "shopify_read_guard.rb")).split("::PG::Connection.prepend").first
eval(src)
G = ShopifyReadGuard
def t(label, expect_ok)
  yield
  puts "#{expect_ok ? "ok  " : "FAIL"} allowed:  #{label}"
rescue => e
  puts "#{expect_ok ? "FAIL" : "ok  "} refused:  #{label}"
end
$stderr = File.open(File::NULL, "w")
t("select", true) { G.check_sql!(%(SELECT "shops".* FROM "shops" WHERE "shops"."id" = $1 LIMIT $2)) }
t("select for update", true) { G.check_sql!(%(SELECT * FROM shops WHERE id = 1 FOR UPDATE)) }
t("advisory lock", true) { G.check_sql!(%(SELECT pg_try_advisory_lock(123))) }
t("set statement_timeout", true) { G.check_sql!(%(SET statement_timeout = '30s')) }
t("begin/commit", true) { G.check_sql!("BEGIN"); G.check_sql!("COMMIT") }
t("string literal mentioning delete", true) { G.check_sql!(%(SELECT * FROM locks WHERE name = 'delete me')) }
t("token refresh update", true) { G.check_sql!(%(UPDATE "shops" SET "shopify_token" = $1, "shopify_token_expires_at" = $2 WHERE "shops"."id" = $3 AND "shops"."shopify_token" = $4)) }
t("unavailable mark", true) { G.check_sql!(%(UPDATE "shops" SET "shopify_store_unavailable_at" = $1, "shopify_store_unavailable_reason" = $2 WHERE "shops"."id" = $3)) }
t("shops update other column", false) { G.check_sql!(%(UPDATE "shops" SET "enabled" = $1 WHERE "shops"."id" = $2)) }
t("shops update_all no where", false) { G.check_sql!(%(UPDATE "shops" SET "shopify_token_refresh_failed_at" = $1)) }
t("shops update + second statement", false) { G.check_sql!(%(UPDATE "shops" SET "shopify_token" = 'x' WHERE "shops"."id" = 1; DELETE FROM locks)) }
t("update locks", false) { G.check_sql!(%(UPDATE locks SET updated_at = now() WHERE id = -1)) }
t("insert", false) { G.check_sql!(%(INSERT INTO asset_caches VALUES (1))) }
t("cte delete", false) { G.check_sql!(%(WITH d AS (DELETE FROM locks RETURNING id) SELECT * FROM d)) }
t("explain analyze delete", false) { G.check_sql!(%(EXPLAIN ANALYZE DELETE FROM locks)) }
t("select into", false) { G.check_sql!(%(SELECT * INTO newtable FROM locks)) }
t("nextval", false) { G.check_sql!(%(SELECT nextval('locks_id_seq'))) }
t("connect-time SETs", true) { G.check_sql!("SET client_min_messages TO 'warning'"); G.check_sql!("SET standard_conforming_strings = on"); G.check_sql!("SET intervalstyle = iso_8601"); G.check_sql!("SET SESSION timezone TO 'UTC'") }
t("set role", false) { G.check_sql!(%(SET ROLE postgres)) }
t("refresh CAS update_all", true) { G.check_sql!(%(UPDATE "shops" SET "shopify_token" = $1, "shopify_token_expires_at" = $2, "shopify_refresh_token" = $3, "shopify_refresh_token_expires_at" = $4, "shopify_token_refresh_failed_at" = $5, "shopify_token_exchange_started_at" = $6 WHERE "shops"."id" = $7 AND "shops"."shopify_token" = $8)) }
t("inlined values", true) { G.check_sql!(%(UPDATE "shops" SET "shopify_token_refresh_failed_at" = '2026-11-21 15:00:00' WHERE "shops"."id" = 42)) }
t("scopes update", true) { G.check_sql!(%(UPDATE "shops" SET "shopify_access_scopes_granted" = $1 WHERE "shops"."id" = $2)) }
t("advisory helper trailing ;", true) { G.check_sql!(%(select pg_try_advisory_xact_lock(123) as success;)) }
t("verify ;", true) { G.check_sql!(";") }
t("discard all", true) { G.check_sql!("DISCARD ALL") }
t("where id OR true", false) { G.check_sql!(%(UPDATE "shops" SET "shopify_token" = $1 WHERE "shops"."id" = 1 OR true)) }
t("where id = id", false) { G.check_sql!(%(UPDATE "shops" SET "shopify_token" = $1 WHERE "shops"."id" = "shops"."id")) }
t("set to function", false) { G.check_sql!(%(UPDATE "shops" SET "shopify_token" = pg_terminate_backend(1)::text WHERE "shops"."id" = 1)) }
t("set to subselect", false) { G.check_sql!(%(UPDATE "shops" SET "shopify_token" = (SELECT 'x') WHERE "shops"."id" = 1)) }
t("E-string smuggle", false) { G.check_sql!(%(SELECT E'\\'' , 1; DELETE FROM locks --')) }
t("Rails type map (a 'e' literal)", true) { G.check_sql!(%(SELECT t.oid, t.typname FROM pg_type as t WHERE t.typtype IN ('r', 'e', 'd') OR t.typinput = 'array_in(cstring,oid,integer)'::regprocedure)) }
t("two statements", false) { G.check_sql!(%(SELECT 1; DELETE FROM locks)) }
Req = Struct.new(:method, :path, :body, :body_stream)
Http = Struct.new(:address)
t("GET admin rest", true) { G.check_http!(Http.new("x.myshopify.com"), Req.new("GET", "/admin/api/2026-07/themes.json", nil), nil) }
t("POST graphql query", true) { G.check_http!(Http.new("x.myshopify.com"), Req.new("POST", "/admin/api/2026-07/graphql.json", { query: "{ shop { name } }" }.to_json), nil) }
t("POST graphql mutation", false) { G.check_http!(Http.new("x.myshopify.com"), Req.new("POST", "/admin/api/2026-07/graphql.json", { query: "mutation { x }" }.to_json), nil) }
t("POST graphql escaped mutation", false) { G.check_http!(Http.new("x.myshopify.com"), Req.new("POST", "/admin/api/2026-07/graphql.json", '{"query":"\\u006dutation { x }"}'), nil) }
t("GET graphql", false) { G.check_http!(Http.new("x.myshopify.com"), Req.new("GET", "/admin/api/2026-07/graphql.json?query=mutation", nil), nil) }
t("POST token endpoint", true) { G.check_http!(Http.new("x.myshopify.com"), Req.new("POST", "/admin/oauth/access_token", "a=b"), nil) }
t("PUT asset", false) { G.check_http!(Http.new("x.myshopify.com"), Req.new("PUT", "/admin/api/2026-07/themes/1/assets.json", "{}"), nil) }
t("POST klaviyo", false) { G.check_http!(Http.new("a.klaviyo.com"), Req.new("POST", "/api/profiles", "{}"), nil) }
t("POST rollbar", true) { G.check_http!(Http.new("api.rollbar.com"), Req.new("POST", "/api/1/item/", "{}"), nil) }
t("POST graphql streamed body", false) { G.check_http!(Http.new("x.myshopify.com"), Req.new("POST", "/admin/api/2026-07/graphql.json", nil, StringIO.new("mutation")), nil) }
