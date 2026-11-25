# Find a literal string in one theme's Liquid files and print each match with a few lines around it. For
# grounding a theme edit before proposing it ("which file draws the buy buttons, and what does Locksmith's
# wrapping look like there?"). Prints theme code, which is the merchant's and not a secret; prod_read.sh
# scrubs anything credential-shaped from the output anyway.
#
# Reads file contents from Locksmith's own asset cache by checksum where it can, and from Shopify only for
# cache misses, paced at 2 requests a second and capped at MAX_FETCH per run (default 80), saying so when
# the cap is reached. Writes nothing; it needs a Shopify session, so it runs under the Shopify read guard.
#   prod_read.sh locksmith bin/locksmith_theme_grep.rb --shopify-read SHOP=<name>.myshopify.com THEME=<theme id> PATTERN=<literal> [IN=<path substring>] [CONTEXT=4] [MAX_FETCH=80] [MAX_MATCHES=40]
shop = Shop.find_by!(shopify_domain: ENV.fetch("SHOP"))
client = shop.shopify_rest_client
theme = Integer(ENV.fetch("THEME"))
pattern = ENV.fetch("PATTERN")
within = ENV["IN"].presence
context = Integer(ENV.fetch("CONTEXT", "4"))
max_fetch = Integer(ENV.fetch("MAX_FETCH", "80"))
max_matches = Integer(ENV.fetch("MAX_MATCHES", "40"))
raise "PATTERN is too short" if pattern.size < 3

assets = client.get(path: "/themes/#{theme}/assets", query: { fields: "key,checksum" }).body["assets"]
candidates = assets.select { |a| a["key"].end_with?(".liquid") && (within.nil? || a["key"].include?(within)) }
puts "theme #{theme}: #{assets.size} assets, #{candidates.size} Liquid files to search for #{pattern.inspect}#{within ? " in paths containing #{within.inspect}" : ""}"

fetched = 0
unread = []
matches = 0
candidates.each do |a|
  bin = a["checksum"].present? && AssetCache.where(shopify_checksum: a["checksum"]).pick(:value_compressed)
  value = bin ? Zlib::Inflate.inflate(bin).force_encoding(Encoding::UTF_8) : nil
  if value.nil?
    if fetched >= max_fetch
      unread << a["key"]
      next
    end
    sleep 0.5
    fetched += 1
    begin
      value = client.get(path: "/themes/#{theme}/assets", query: { "asset[key]" => a["key"], fields: "value" }).body.dig("asset", "value").to_s
    rescue ShopifyAPI::Errors::HttpResponseError => e
      puts "(#{a["key"]} could not be read: HTTP #{e.code})"
      next
    end
  end
  lines = value.scrub.lines
  hits = lines.each_index.select { |i| lines[i].include?(pattern) }
  next if hits.empty?
  puts "", "== #{a["key"]}: #{hits.size} match#{hits.size == 1 ? "" : "es"}"
  hits.each do |i|
    break if matches >= max_matches
    matches += 1
    from = [i - context, 0].max
    to = [i + context, lines.size - 1].min
    puts "-- line #{i + 1}"
    (from..to).each { |j| puts format("%5d%s %s", j + 1, j == i ? ">" : " ", lines[j].chomp[0, 240]) }
  end
end
puts "", "fetched #{fetched} from Shopify; #{matches} matches printed#{matches >= max_matches ? " (MAX_MATCHES reached)" : ""}"
puts "not read (MAX_FETCH reached): #{unread.size} files, e.g. #{unread.first(5).join(", ")}" if unread.any?
