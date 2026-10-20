#!/bin/bash
# A shop's setup as Markdown, from production: the app's support report, read-only. Locksmith by default; --mechanic
# for Mechanic (mechanic-api #2448, released in v298).
#
#   support_shop.sh [--mechanic] <shop>[.myshopify.com] [sender email]
#
# Isaac has given a standing go for these reads (2026-10-20), so the before-acting hook lets this script through
# without a go line. It can only render the report, so the standing go covers exactly that much: anything else in
# production still goes through prod_read.sh, with a go each time.
#
# <shop> can also be a storefront domain (www.example.com): its public /meta.json names the shop, so a ticket without a
# Beacon still gets its report.
set -euo pipefail
app=locksmith; report="Locksmith::SupportReport"
if [[ "${1:-}" == "--mechanic" ]]; then app=mechanic; report="Mechanic::SupportReport"; shift; fi
shop="${1:?usage: support_shop.sh <shop or storefront domain> [sender email]}"
sender="${2:-}"
if [[ "$shop" == *.* && "$shop" != *.myshopify.com ]]; then
  [[ "$shop" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "not a domain: $shop" >&2; exit 2; }
  resolved=$(curl -sfL --max-time 15 "https://$shop/meta.json" | python3 -I -c 'import sys,json; print(json.load(sys.stdin).get("myshopify_domain",""))' 2>/dev/null || true)
  [[ -n "$resolved" ]] || { echo "couldn't find a Shopify store at $shop (no /meta.json)" >&2; exit 2; }
  echo "($shop is $resolved)" >&2
  shop="$resolved"
fi
[[ "$shop" =~ ^[a-z0-9][a-z0-9-]*(\.myshopify\.com)?$ ]] || { echo "not a shop handle: $shop" >&2; exit 2; }
[[ -z "$sender" || "$sender" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$ ]] || { echo "not an email this script accepts: $sender" >&2; exit 2; }
shop="${shop%.myshopify.com}.myshopify.com"

script=$(mktemp -t support_shop.XXXXXX)
trap 'rm -f "$script"' EXIT
cat > "$script" <<'RUBY'
shop = Shop.find_by(shopify_domain: ENV.fetch("SHOP"))
abort("no shop #{ENV.fetch("SHOP")}") unless shop
puts REPORT.new(shop, sender: ENV["SENDER"].presence).to_markdown
RUBY
sed -i '' "s/REPORT/$report/" "$script"
"$(dirname "$0")/prod_read.sh" "$app" "$script" "SHOP=$shop" ${sender:+"SENDER=$sender"}
