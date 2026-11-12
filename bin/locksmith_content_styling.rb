# Switch a Locksmith shop's content styling (the admin shop page's staff-only radio buttons). Runs in locksmith-api
# production through prod_read.sh, with SHOP and VERSION in the environment:
#   prod_read.sh locksmith …/locksmith_content_styling.rb [--write] SHOP=<name>.myshopify.com VERSION=2
# VERSION is "classic" (""), "1" (spacing) or "2" (theme-matched). Prints before and after, and queues the
# reinstall the admin page queues, so the theme picks the new styling up. Refuses if the shop already has it.
domain = ENV.fetch("SHOP")
version = ENV.fetch("VERSION")
version = "" if version == "classic"
abort "VERSION must be classic, 1 or 2" unless ["", "1", "2"].include?(version)

shop = Shop.find_by!(shopify_domain: domain)
show = ->(label) {
  shop.reload
  puts "#{label}: content_styling_version=#{shop.content_styling_version.inspect} installed=#{shop.installed?} " \
       "main theme=#{shop.main_shopify_theme&.id.inspect}"
}
show.("before")
if shop.content_styling_version.to_s == version
  puts "REFUSED: shop already has content styling #{version.inspect}; nothing to change"
else
  shop.update!(content_styling_version: version)
  shop.enqueue_standard_install_job!(comment: "content styling #{version.inspect} by Claude, with Isaac's go")
  show.("after")
end
