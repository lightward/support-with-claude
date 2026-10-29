# Lift a new Mechanic shop's first-week email pacing (25 at once, then about one an hour, email_action.rb), moving it
# onto the per-minute limiter older shops use. The same checkbox as the admin shop form. Runs in mechanic-api
# production through prod_read.sh, with Isaac's go on every run; dry-run first (the default mode rolls back):
#   prod_read.sh mechanic ~/dev/support-with-claude/bin/mechanic_bypass_new_shop_email_limit.rb [--write] SHOP=<name>.myshopify.com
# Prints the state before and after; writes nothing if the bypass is already set.
domain = ENV.fetch("SHOP")
shop = Shop.find_by!(shopify_domain: domain)
show = ->(label) {
  shop.reload
  puts "#{label}: bypass_daily_email_limit_for_new_shops=#{shop.is_bypass_daily_email_limit_for_new_shops.inspect} " \
       "emails_per_minute_limit=#{shop.emails_per_minute_limit} approved_for_email=#{shop.approved_for_email} " \
       "created=#{shop.created_at.to_date} first_week_ends=#{(shop.created_at + 1.week).to_date}"
}
show.("before")
if shop.is_bypass_daily_email_limit_for_new_shops
  puts "already bypassed; nothing written"
else
  shop.update!(is_bypass_daily_email_limit_for_new_shops: true)
  show.("after")
end
