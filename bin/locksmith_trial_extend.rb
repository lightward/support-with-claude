# Extend a Locksmith trial. Runs in locksmith-api production through prod_read.sh, with SHOP and either DAYS or UNTIL:
#   prod_read.sh locksmith …/locksmith_trial_extend.rb [--write] SHOP=<name>.myshopify.com DAYS=15
#   prod_read.sh locksmith …/locksmith_trial_extend.rb [--write] SHOP=<name>.myshopify.com UNTIL=2026-11-20
# Prints the state before and after. Refuses if the shop has a subscription. With DAYS, refuses a trial that already
# has more than 5 days left (someone may have extended it) and sets it to end DAYS from now. With UNTIL (a merchant
# asking for "through <date>", #119338), refuses only if the trial already ends later, and sets it to end once that
# date has ended everywhere (noon UTC the next day, the end of the date at UTC-12). Queues the reinstall the admin
# page's update would queue. No email is sent and no Shopify charge changes.
domain = ENV.fetch("SHOP")
days = ENV["DAYS"] && Integer(ENV["DAYS"])
until_date = ENV["UNTIL"] && Date.iso8601(ENV["UNTIL"])
raise "give DAYS or UNTIL, not both" unless days.nil? ^ until_date.nil?
raise "DAYS must be 1..31" if days && !(1..31).cover?(days)

shop = Shop.find_by!(shopify_domain: domain)
puts "contact on file: #{shop.shopify_email.inspect} (owner #{shop.shopify_shop_owner.inspect})"
show = ->(label) {
  shop.reload
  puts "#{label}: trial_started_at=#{shop.trial_started_at&.iso8601} trial_ends_at=#{shop.trial_ends_at&.iso8601} " \
       "days_left=#{shop.trial_days_left} subscriber=#{shop.subscriber?} suspended=#{shop.suspended.inspect} " \
       "active=#{shop.active.inspect} installed=#{shop.installed?} active_locks=#{shop.locks.active.count}"
}
show.("before")
if until_date
  ends_at = (until_date + 1).in_time_zone("UTC") + 12.hours
  # A guard against a typo'd year, not a policy: gifts get sized to the need, past a month when Isaac says so (#119915).
  raise "UNTIL must be within 120 days" if ends_at > 120.days.from_now
  seconds = (ends_at - Time.now.utc).round
end
if shop.subscriber?
  puts "REFUSED: shop has a subscription; nothing to extend"
elsif days && shop.trial_days_left > 5
  puts "REFUSED: trial already has #{shop.trial_days_left} days left; someone may have extended it"
elsif until_date && shop.trial_ends_at && shop.trial_ends_at >= ends_at
  puts "REFUSED: trial already ends #{shop.trial_ends_at.iso8601}, on or after #{ends_at.iso8601}"
else
  shop.update!(trial_ends_in: days ? "#{days} days" : "#{seconds} seconds")
  shop.enqueue_standard_install_job!(comment: "trial extension (#{days ? "#{days} days" : "until #{until_date}"}) by Claude, with Isaac's go")
  show.("after")
end
