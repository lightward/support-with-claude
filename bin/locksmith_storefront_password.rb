# Prints only the storefront password Locksmith holds for a shop, as the last line, for capture into an
# environment variable that is never displayed (Isaac's go each time; #120848):
#   SF_PW=$(bin/prod_read.sh locksmith bin/locksmith_storefront_password.rb SHOP=<name>.myshopify.com | tail -1)
# Prints NONE when the storefront password is off or Locksmith holds none, so the caller can tell.
shop = Shop.find_by!(shopify_domain: ENV.fetch("SHOP"))
value = shop.shopify_password_enabled ? shop.password.to_s : ""
puts(value.presence || "NONE")
