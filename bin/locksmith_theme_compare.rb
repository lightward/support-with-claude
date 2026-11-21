# What Locksmith has put into two themes, side by side: each theme's hiding profile (enabled, its hiding
# definitions, and the price/add-to-cart scan's definition identities) and every file carrying Locksmith
# checks (calls to locksmith-variables, counted by variable, plus a raw count of the calls so a call the
# pattern can't parse still shows). For "it works on my old theme but not the new one". Prints file keys,
# block names and counts, never file contents. Counts, not placement: equal counts don't prove the calls sit
# in the same places.
#
# Reads file contents from Locksmith's own asset cache by checksum where it can (read only: it never touches
# the cache's access time), and from Shopify only for cache misses, paced at 2 requests a second and capped
# at MAX_FETCH per run (default 60), saying so when the cap is reached. Skips the suffixes Locksmith itself
# ignores (.css.liquid, .js.liquid, .svg.liquid).
#
# Needs --write mode only because getting a Shopify session can refresh (or, for a legacy token, exchange)
# the shop's token, which writes Locksmith's own token columns, and an error from Shopify can mark the shop
# unavailable, as any Locksmith call to Shopify would. Nothing else is saved.
#   prod_read.sh locksmith bin/locksmith_theme_compare.rb --shopify-read SHOP=<name>.myshopify.com OLD=<theme id> NEW=<theme id> [MAX_FETCH=60]
PAT = /locksmith-variables[^%\n]*?variable:\s*['"]([a-z_]+)['"]/
CALL = /locksmith-variables/
IGNORED = Locksmith::ThemeIntegration::AssetsConcern::ASSET_KEY_SUFFIXES_TO_IGNORE

shop = Shop.find_by!(shopify_domain: ENV.fetch("SHOP"))
client = shop.shopify_rest_client
themes = { "OLD" => Integer(ENV.fetch("OLD")), "NEW" => Integer(ENV.fetch("NEW")) }
max_fetch = Integer(ENV.fetch("MAX_FETCH", "60"))
fetched = 0
capped = false
by_checksum = {}

cached = lambda do |checksum|
  next nil if checksum.blank?
  bin = AssetCache.where(shopify_checksum: checksum).pick(:value_compressed)
  bin && Zlib::Inflate.inflate(bin).force_encoding(Encoding::UTF_8)
end

read = {}
themes.each do |label, id|
  assets = client.get(path: "/themes/#{id}/assets", query: { fields: "key,checksum" }).body["assets"]
  t = Array(shop.shopify_themes(raw: true)).find { |th| th["id"].to_i == id }
  keys = assets.map { |a| a["key"] }
  checks = {}
  unread = []
  assets.select { |a| a["key"].end_with?(".liquid") && IGNORED.none? { |s| a["key"].end_with?(s) } && !a["key"].start_with?("snippets/locksmith") }.each do |a|
    v = by_checksum[a["checksum"]] ||= cached.(a["checksum"])
    if v.nil?
      if fetched >= max_fetch
        capped = true
        unread << a["key"]
        next
      end
      sleep 0.5
      fetched += 1
      begin
        v = client.get(path: "/themes/#{id}/assets", query: { "asset[key]" => a["key"], fields: "value" }).body.dig("asset", "value").to_s
      rescue ShopifyAPI::Errors::HttpResponseError => e
        puts "  (#{a["key"]} could not be read: HTTP #{e.code})"
        unread << a["key"]
        next
      end
      by_checksum[a["checksum"]] = v if a["checksum"].present?
    end
    v = v.scrub
    calls = v.scan(CALL).size
    next if calls.zero?
    vars = v.scan(PAT).flatten.tally
    checks[a["key"]] = { vars: vars, calls: calls }
  end
  read[label] = { keys: keys, checks: checks, unread: unread }

  profile = shop.theme_hiding_profiles.find_by(theme_id: id)
  puts "#{label} #{id}#{t ? " #{t["name"].inspect} (#{t["role"]})" : ""}: #{keys.size} assets, " \
       "#{keys.count { |k| k.start_with?("snippets/locksmith") }} Locksmith snippets"
  if profile
    defs = profile.hiding_definitions.to_a
    puts "  hiding profile: enabled=#{profile.enabled.inspect}, #{defs.size} hiding definitions"
    defs.each { |d| puts "    #{d.file}#{d.block.present? ? " / #{d.block}" : ""} (variable #{d.variable.presence || "product"}, replace=#{d.replace.inspect})" }
    scan = profile.price_hiding_scan.presence
    if scan
      puts "  price-hiding scan: scanned_at=#{scan["scanned_at"].inspect} theme_store_id=#{scan["theme_store_id"].inspect}"
      Locksmith::PriceHidingScanner::CATEGORIES.each do |category|
        data = scan[category].is_a?(Hash) ? scan[category] : {}
        ids = Array(data["definitions"]).map { |d| ThemeHidingProfile.price_hiding_definition_identity(d) }
        puts "    #{category}: strategy=#{data["strategy"].inspect} source=#{data["source"].inspect}, #{ids.size} definitions#{ids.any? ? ": #{ids.join(", ")}" : ""}"
      end
    else
      puts "  price-hiding scan: none (it runs when price hiding is in use or content styling is v2)"
    end
    custom = profile.price_hiding_customizations || {}
    puts "  price-hiding customizations: #{custom.transform_values { |v| v.respond_to?(:size) ? v.size : v }.inspect}" if custom.any?
  else
    puts "  hiding profile: none"
  end
  puts "  #{unread.size} file(s) not read (fetch cap reached, or Shopify refused)" if unread.any?
end

puts "files with Locksmith calls, by variable count and raw call count (OLD | NEW):"
(read["OLD"][:checks].keys | read["NEW"][:checks].keys).sort.each do |k|
  show = lambda do |label|
    c = read[label][:checks][k]
    next "#{c[:vars].inspect} (#{c[:calls]} calls)" if c
    next "not read" if read[label][:unread].include?(k)
    read[label][:keys].include?(k) ? "present, no calls" : "absent"
  end
  o = read["OLD"][:checks][k]
  n = read["NEW"][:checks][k]
  puts "  #{o == n ? " " : "≠"} #{k}: #{show.("OLD")} | #{show.("NEW")}"
end
puts "fetched #{fetched} file(s) from Shopify; the rest came from Locksmith's asset cache#{capped ? "; FETCH CAP REACHED, comparison incomplete" : ""}"

puts "recent installs into these themes:"
ShopInstall.where(shop_id: shop.id, theme_id: themes.values).order(created_at: :desc).limit(6).each do |si|
  state = if !si.stopped_at then "not finished"
          elsif si.error.present? || si.error_summary.present? then "finished with an error"
          else "finished"
          end
  puts "  #{si.created_at.utc} theme #{si.theme_id}#{si.uninstall ? " (uninstall)" : ""}: #{state}; #{si.comment.to_s.truncate(80).inspect}"
end
