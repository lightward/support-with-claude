# Grant a Locksmith development store its super-extended trial (a hundred years, Isaac's grant for stores that will
# never see customer traffic). Runs in locksmith-api production through prod_read.sh, with SHOP in the environment:
#   prod_read.sh locksmith …/locksmith_dev_trial.rb [--write] SHOP=<name>.myshopify.com
# Prints the state before and after. Refuses a shop with a subscription. Sets the trial to end a hundred years from
# now and queues the reinstall the admin page's update would queue. No email is sent and no Shopify charge changes.
domain = ENV.fetch("SHOP")

shop = Shop.find_by!(shopify_domain: domain)
puts "contact on file: #{shop.shopify_email.inspect}; Shopify plan: #{shop.shopify_plan_name.inspect}"
show = ->(label) {
  shop.reload
  puts "#{label}: trial_started_at=#{shop.trial_started_at&.iso8601} trial_ends_at=#{shop.trial_ends_at&.iso8601} " \
       "days_left=#{shop.trial_days_left} subscriber=#{shop.subscriber?} active=#{shop.active.inspect} " \
       "installed=#{shop.installed?}"
}
show.("before")
if shop.subscriber?
  puts "REFUSED: shop has a subscription; nothing to extend"
else
  shop.update!(trial_ends_in: "100 years")
  shop.enqueue_standard_install_job!(comment: "development store trial (100 years) by Claude, with Isaac's go")
  show.("after")
end
