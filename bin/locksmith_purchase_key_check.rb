# Would a "has purchased…" key recognize the product the merchant means? The key compares its text, stripped
# and lowercased, against each order line's SKU, line title, product id, variant id, current product title and
# selling plan id; a value starting "tag:" compares product tags, case-sensitively
# (app/lib/locksmith/key_conditions/purchased_product.rb). This prints every purchased_product condition on the
# key with its options, then, for each, the shop's products today that could carry that text, and which field
# matches the way the key compares.
#
# What it can't see: orders (Locksmith has no orders scope; the merchant checks those in their admin), and a
# line's title or SKU as they were at purchase. A product renamed or deleted since can still match past orders,
# so a zero here means "nothing in today's catalog", never "no order can match".
# The key also only looks at a customer's latest 50 orders (20 inside another paginated list past its first page).
#
# Admin GraphQL product queries only. Needs --write mode only because getting a Shopify session can refresh
# (or, for a legacy token, exchange) the shop's token, which writes Locksmith's own token columns, and an
# error from Shopify can mark the shop unavailable, as any Locksmith call to Shopify would. Nothing else is saved.
#   prod_read.sh locksmith bin/locksmith_purchase_key_check.rb --shopify-read SHOP=<name>.myshopify.com KEY=<key id>
def search_quote(s) = "\"#{s.gsub(/[\\"]/) { "\\#{_1}" }}\""

shop = Shop.find_by!(shopify_domain: ENV.fetch("SHOP"))
key = shop.keys.find(Integer(ENV.fetch("KEY")))
conds = key.conditions.select { |c| c.type == "purchased_product" }
abort "key #{key.id} has no purchased_product condition" if conds.empty?
client = shop.shopify_graphql_client
run = lambda do |q, fields|
  body = client.query(query: "query($q: String!) { products(first: 25, query: $q) { nodes { #{fields} } } }", variables: { q: q }).body
  if body["errors"].present?
    puts "  (search #{q.inspect} failed: #{Array(body["errors"]).map { |e| e["message"] }.inspect})"
    return []
  end
  Array(body.dig("data", "products", "nodes"))
end

conds.each_with_index do |cond, ci|
  raw = cond.value.to_s
  puts "condition #{ci + 1} of #{conds.size}#{cond.inverse ? " (INVERTED: a match means no access)" : ""}: value length #{raw.strip.length}, " \
       "ignore_cancelled=#{cond.purchased_ignore_cancelled.inspect} ignore_unpaid=#{cond.purchased_ignore_unpaid.inspect} " \
       "ignore_unfulfilled=#{cond.purchased_ignore_unfulfilled.inspect} days_max=#{cond.try(:purchased_days_ago_max).inspect} " \
       "times_max=#{cond.try(:purchased_times_max).inspect}"
  if cond.try(:purchased_times_max).present?
    puts "  times_max is set: the key passes whenever the matching purchase count is at most #{cond.purchased_times_max}, " \
         "and that includes zero, so a customer who never bought it (or a signed-out visitor) passes too"
  end
  if raw.blank?
    puts "  blank value: matches the product being viewed"
    next
  end
  if raw.strip == "*"
    puts "  value is *: any purchase passes"
    next
  end

  if (m = raw.match(/^tag:(.+)$/)) # the app tests the unstripped value, as here
    tag = m[1].strip
    nodes = run.(%(tag:#{search_quote(tag)}), "title status tags")
    puts "  tag mode: #{nodes.size} product(s) found by tag search#{nodes.size == 25 ? " (first 25 only)" : ""}"
    nodes.each { |p| puts "    #{p["title"].inspect} status=#{p["status"]} tag exact (case-sensitive)=#{p["tags"].include?(tag)}" }
    next
  end

  want = raw.strip.downcase
  fields = "id title status variants(first: 100) { nodes { id title sku } }"
  found = {}
  if want.match?(/\A\d+\z/)
    puts "  value is numeric: the key may match it as a product, variant or selling plan id"
    { "product" => "Product", "variant" => "ProductVariant" }.each do |label, kind|
      body = client.query(query: "query($id: ID!) { node(id: $id) { id ... on Product { title status } ... on ProductVariant { title product { title status } } } }",
        variables: { id: "gid://shopify/#{kind}/#{want}" }).body
      n = body.dig("data", "node")
      shown = if body["errors"].present? then "lookup failed: #{Array(body["errors"]).map { |e| e["message"] }.inspect}"
              elsif n.nil? then "nothing today"
              elsif n["product"] then "variant #{n["title"].inspect} of #{n.dig("product", "title").inspect}"
              else "#{n["title"].inspect} status=#{n["status"]}"
              end
      puts "    as a #{label} id: #{shown}"
    end
    puts "    (selling plan ids not checked)"
  end
  [%(title:#{search_quote(raw.strip)}), %(sku:#{search_quote(raw.strip)})].each { |q| run.(q, fields).each { |p| found[p["id"]] = p } }
  words = raw.strip.split(/\s+/).map { |w| w.gsub(/[^\p{Alnum}]/, "") }.reject(&:empty?).first(3)
  run.(words.map { |w| "title:#{w}*" }.join(" "), fields).each { |p| found[p["id"]] = p } if words.any?
  puts "  title/sku mode: #{found.size} candidate product(s) in today's catalog (each search returns at most 25)"
  puts "    (zero means nothing today; a since-renamed or deleted product can still match past orders)" if found.empty?
  found.each_value do |p|
    puts "    #{p["title"].inspect} status=#{p["status"]} product title matches=#{p["title"].to_s.strip.downcase == want}"
    puts "      (first 100 variants only)" if p.dig("variants", "nodes").size == 100
    p.dig("variants", "nodes").each do |v|
      line_title = v["title"] == "Default Title" ? p["title"] : "#{p["title"]} - #{v["title"]}"
      puts "      variant #{v["title"].inspect}: sku matches=#{v["sku"].to_s.strip.downcase == want} " \
           "line title would match (per Shopify's line_item.title, as of purchase)=#{line_title.strip.downcase == want}"
    end
  end
end
