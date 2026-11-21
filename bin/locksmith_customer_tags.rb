# Does a customer tag key see these customers the way the merchant thinks? For each email, in shape only:
# account state, whether the address has capitals, and whether Locksmith's own comparison would match, plus
# near-matches (case, surrounding or doubled space, invisible characters) as diagnostics, with lengths.
# Never prints emails, names, other tags, or the near-matching strings themselves.
#
# The comparison is customer_tag.rb's: the key's value stripped, then `customer.tags contains value`,
# downcasing both sides for conditions created after 1604459000 (2020-11-04) and case-sensitive before;
# missing_customer_tag.rb compares the stripped value case-sensitively. With missing_customer_tag, or an
# inverted condition, a match means NO access.
#
# Admin GraphQL queries only. Needs --write mode only because getting a Shopify session can refresh the
# shop's token (the one write it can cause, Locksmith's own token columns); nothing else is saved.
#   prod_read.sh locksmith bin/locksmith_customer_tags.rb --shopify-read SHOP=<name>.myshopify.com KEY=<key id> EMAILS=<a@x.com>:<b@y.com>
#   prod_read.sh locksmith bin/locksmith_customer_tags.rb --shopify-read SHOP=<name>.myshopify.com TAG=<tag> EMAILS=…   (case rule unknown: both shown)
# The wrapper only passes [A-Za-z0-9._:@/-], so an address with "+" can't be given at all (it fails at the wrapper,
# never as "not found"). Under the case-insensitive rule, a tag differing only in case is a match and also shows as a
# near-match with "case differs true".
INVIS = /[\u200B-\u200D\u2060\uFEFF\u00A0\u202F]/
CASE_INSENSITIVE_AFTER = 1604459000

shop = Shop.find_by!(shopify_domain: ENV.fetch("SHOP"))
if ENV["KEY"].present?
  key = shop.keys.find(Integer(ENV.fetch("KEY")))
  conds = key.conditions.select { |c| %w[customer_tag missing_customer_tag].include?(c.type) }
  abort "key #{key.id} has #{conds.size} customer_tag/missing_customer_tag conditions; this helper needs exactly one" unless conds.size == 1
  cond = conds.first
  tag = cond.value.to_s.strip
  rule = if cond.type == "missing_customer_tag" then :sensitive
         elsif cond.created_at.nil? || cond.created_at.to_i > CASE_INSENSITIVE_AFTER then :insensitive
         else :sensitive
         end
  puts "condition: #{cond.type}#{cond.inverse ? " (inverted)" : ""}, case-#{rule}" \
       "#{(cond.type == "missing_customer_tag") ^ cond.inverse ? "; a match here means NO access" : ""}"
else
  tag = ENV.fetch("TAG").strip
  rule = :unknown
  puts "no condition given: case rule unknown, so both comparisons are shown"
end
emails = ENV.fetch("EMAILS").split(":").map(&:strip).reject(&:empty?)
abort "EMAILS is empty" if emails.empty?

puts "tag: length #{tag.length}, invisible #{tag.scan(INVIS).size}, has capitals #{tag != tag.downcase}"
loose = ->(t) { t.to_s.gsub(INVIS, "").strip.squeeze(" ").downcase }
sensitive = ->(tags) { tags.include?(tag) }
insensitive = ->(tags) { tags.map(&:downcase).include?(tag.downcase) }

client = shop.shopify_graphql_client
query = <<~GQL
  query($q: String!) {
    customers(first: 5, query: $q) { nodes { email state verifiedEmail tags numberOfOrders } }
  }
GQL

emails.each_with_index do |email, i|
  body = client.query(query: query, variables: { q: "email:#{email.to_json}" }).body
  if body["errors"].present?
    puts "customer #{i + 1}: query errors #{Array(body["errors"]).map { |e| e["message"] }.inspect}"
    next
  end
  hits = Array(body.dig("data", "customers", "nodes")).select { |n| n["email"].to_s.casecmp?(email) }
  if hits.empty?
    puts "customer #{i + 1}: no returned customer whose email matches"
    next
  end
  hits.each do |n|
    tags = Array(n["tags"])
    match =
      case rule
      when :sensitive then "locksmith_match=#{sensitive.(tags)}"
      when :insensitive then "locksmith_match=#{insensitive.(tags)}"
      else "match case-sensitive=#{sensitive.(tags)} case-insensitive=#{insensitive.(tags)}"
      end
    near = tags.reject { |t| t == tag }.select { |t| loose.(t) == loose.(tag) }
    puts "customer #{i + 1}: #{match} | state=#{n["state"]} verified=#{n["verifiedEmail"]} orders=#{n["numberOfOrders"]} " \
         "address has capitals=#{n["email"] != n["email"].to_s.downcase} tags=#{tags.size} near-matches=#{near.size}"
    near.each do |t|
      bare = t.gsub(INVIS, "").strip
      puts "  near-match: length #{t.length} (tag #{tag.length}), invisible #{t.scan(INVIS).size}, " \
           "edge space #{t != t.strip}, inner spacing differs #{bare.squeeze(" ") != bare}, case differs #{bare.squeeze(" ") != tag.squeeze(" ") && bare.squeeze(" ").casecmp?(tag.squeeze(" "))}"
    end
  end
end
