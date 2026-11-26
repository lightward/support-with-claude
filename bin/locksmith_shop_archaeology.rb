# What Locksmith's own records say about one shop's history with it, for a merchant who asks who installed it, what
# was charged and who changed locks (#121470). Read-only. It prints the facts the merchant is owed about her own shop:
# her staff's names and emails, dates, amounts, and lock ids. It prints no tokens, passcodes or secrets.
#
# What Locksmith keeps, from the code (locksmith-api):
#   - shops: created_at (when this shop's record was first made, which survives uninstalls: an uninstall nils
#     shopify_token, Shop#record_uninstalled!; but ShopVacuumWorker destroys a shop two years uninstalled with no
#     charge and no activity, and a reinstall then makes a new record), subscription_charge_id / subscription_price /
#     latest_subscription_started_at / latest_subscription_cancelled_at (the current charge, synced from Shopify,
#     concerns/shop/subscription_concern.rb:98-142), trial_started_at / trial_length. last_installed_at is the last
#     THEME install (shop_install.rb:204), not the app install.
#   - staff_members: one per Shopify staff account that has opened Locksmith (StaffMember.adopt_shopify_user!, from
#     the token response's associated_user), with created_at as its first arrival and last_seen_at. Nothing records
#     who authorised the app install itself (on the OAuth install path the installer usually gets a staff record within
#     moments of the install, auth_controller.rb:49-53: an inference, said as one). staff records exist since
#     2021-11-25; a staff record is keyed by the Shopify user id and moves to the shop it was last adopted from, so an
#     agency person who opened Locksmith on several stores may show a first arrival from elsewhere, or be missing here.
#   - subscription_price_changes: price changes made through Locksmith, with status and dates (since 2026-11-06).
#   - app uninstalls aren't kept: a processed webhook is destroyed at once. Partners' store page lists them.
#   - locks / keys: created_at and updated_at only (updated_at moves on any save of the lock or its keys, by anyone,
#     Lightward's admin included, and some of Locksmith's own changes don't move it). There is no PaperTrail and no audit table, so who created or
#     changed a lock isn't recorded. asset_changes are theme edits made by Lightward staff (user_id → users).
#
# With SHOPIFY=1 under --shopify-read it also reads, from Shopify, every subscription this app has had on the shop
# (currentAppInstallation.allSubscriptions: name, status, price, created, current period end, test). That's a query
# with no mutations. Getting the session can refresh the shop's token, which the guard allows and prints.
#   prod_read.sh locksmith bin/locksmith_shop_archaeology.rb --shopify-read SHOP=<name>.myshopify.com [SHOPIFY=1]
# (always under --shopify-read, the standing go for committed scripts; without SHOPIFY=1 it reaches nothing outside)
# What only Shopify's Partners dashboard shows: every install, uninstall and charge event, and each invoice. Nothing
# we can see says which account approved an install or a charge.

shop = Shop.find_by!(shopify_domain: ENV.fetch("SHOP"))
t = ->(v) { v ? v.utc.strftime("%Y-%m-%d %H:%M UTC") : "none" }

puts "== shop"
puts "record first made: #{t.(shop.created_at)} (this record; a shop vacuumed after two years uninstalled starts a new one)"
puts "app installed now: #{shop.shopify_token.present?}"
puts "last theme install (Locksmith's code put in a theme, not the app install): #{t.(shop.last_installed_at)}"
puts "trial started: #{t.(shop.trial_started_at)}, trial length: #{shop.trial_length ? "#{(shop.trial_length / 86_400.0).round(1)} days" : "none"}"
puts "current charge id: #{shop.subscription_charge_id.inspect}, price: #{shop[:subscription_price].inspect}, custom price: #{shop.custom_subscription_price.inspect}"
puts "latest subscription started: #{t.(shop.latest_subscription_started_at)}, latest cancelled: #{t.(shop.latest_subscription_cancelled_at)}"
puts "shop owner per Shopify: #{shop.shopify_shop_owner.inspect}; shop email: #{shop.shopify_email.inspect}"

puts "\n== staff who have opened Locksmith, as recorded since 2021-11-25 (first arrival = record made; nothing records who installed the app, though the installer usually arrives within moments of an install)"
shop.staff_members.order(:created_at).each do |s|
  puts "- #{[s.first_name, s.last_name].compact.join(" ")} <#{s.email}> owner=#{s.account_owner.inspect} collaborator=#{s.collaborator.inspect} first arrived #{t.(s.created_at)}, last seen #{t.(s.last_seen_at)}"
end

puts "\n== price changes made through Locksmith (recorded since 2026-11-06)"
changes = SubscriptionPriceChange.where(shop_id: shop.id).order(:created_at)
puts "- none" if changes.empty?
changes.each { |c| puts "- #{t.(c.created_at)} → $#{c.price} (was custom: #{c.previous_custom_subscription_price.inspect}) status=#{c.status}, updated #{t.(c.updated_at)}" }


puts "\n== locks (created, and last saved: a save of the lock or its keys, by anyone; who isn't recorded)"
key_counts = Key.where(shop_id: shop.id).group(:lock_id).count
shop.locks.select(:id, :created_at, :updated_at, :active).order(:created_at).each do |l|
  puts "- lock #{l.id}: created #{t.(l.created_at)}, last saved #{t.(l.updated_at)}, active=#{l.active.inspect}, keys #{key_counts.fetch(l.id, 0)}"
end

puts "\n== theme edits by Lightward staff (asset_changes)"
edits = shop.asset_changes.select(:created_at, :asset_key, :theme_id, :user_id).order(:created_at).to_a
puts "- none" if edits.empty?
names = User.where(id: edits.map(&:user_id).uniq).pluck(:id, :name).to_h
edits.each { |a| puts "- #{t.(a.created_at)} #{a.asset_key} on theme #{a.theme_id} by #{names[a.user_id] || "user #{a.user_id}"}" }

if ENV["SHOPIFY"] == "1"
  puts "\n== the subscriptions this installation of the app has had on the shop, per Shopify (oldest first, up to 50; an earlier installation's aren't here: Partners lists them)"
  q = <<~GQL
    { currentAppInstallation { allSubscriptions(first: 50, sortKey: CREATED_AT) { pageInfo { hasNextPage } nodes {
        name status createdAt currentPeriodEnd test trialDays
        lineItems { plan { pricingDetails { ... on AppRecurringPricing { price { amount currencyCode } interval } } } }
    } } } }
  GQL
  body = shop.shopify_graphql_client.query(query: q).body
  abort "Shopify said: #{Array(body["errors"]).map { it["message"] }.inspect}" if body["errors"].present?
  Array(body.dig("data", "currentAppInstallation", "allSubscriptions", "nodes")).each do |s|
    price = s["lineItems"].filter_map { it.dig("plan", "pricingDetails", "price") }.map { "#{it["amount"]} #{it["currencyCode"]}" }.join(", ")
    puts "- #{s["createdAt"]} #{s["name"].inspect} #{price} status=#{s["status"]} test=#{s["test"]} trialDays=#{s["trialDays"]} periodEnd=#{s["currentPeriodEnd"].inspect}"
  end
  puts "- (more than 50: the newest aren't shown)" if body.dig("data", "currentAppInstallation", "allSubscriptions", "pageInfo", "hasNextPage")
end
