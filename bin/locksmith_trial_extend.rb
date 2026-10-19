# Extend a Locksmith trial. Runs in locksmith-api production via bin/rails runner, with SHOP and DAYS in the environment:
#   SHOP=<name>.myshopify.com DAYS=15 bin/rails runner /tmp/locksmith_trial_extend.rb
# Prints the state before and after. Refuses if the shop has a subscription, or if the trial already has more than
# 5 days left (someone may have extended it). Sets the trial to end DAYS from now and queues the reinstall the admin
# page's update would queue. No email is sent and no Shopify charge changes.
domain = ENV.fetch("SHOP")
days = Integer(ENV.fetch("DAYS"))
raise "DAYS must be 1..31" unless (1..31).cover?(days)

shop = Shop.find_by!(shopify_domain: domain)
puts "contact on file: #{shop.shopify_email.inspect} (owner #{shop.shopify_shop_owner.inspect})"
show = ->(label) {
  shop.reload
  puts "#{label}: trial_started_at=#{shop.trial_started_at&.iso8601} trial_ends_at=#{shop.trial_ends_at&.iso8601} " \
       "days_left=#{shop.trial_days_left} subscriber=#{shop.subscriber?} suspended=#{shop.suspended.inspect} " \
       "active=#{shop.active.inspect} installed=#{shop.installed?} active_locks=#{shop.locks.active.count}"
}
show.("before")
if shop.subscriber?
  puts "REFUSED: shop has a subscription; nothing to extend"
elsif shop.trial_days_left > 5
  puts "REFUSED: trial already has #{shop.trial_days_left} days left; someone may have extended it"
else
  shop.update!(trial_ends_in: "#{days} days")
  shop.enqueue_standard_install_job!(comment: "trial extension (#{days} days) by Claude, with Isaac's go")
  show.("after")
end
