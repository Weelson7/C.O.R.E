#!/usr/bin/env bash
set -euo pipefail

# configure_nginx_ingress.sh - extend Nginx routing to all available services
# Usage: configure_nginx_ingress.sh <services-file> <nginx-config-dir> [enable-ssl]

if [ "$#" -lt 2 ]; then
  echo "Usage: configure_nginx_ingress.sh <services-file> <nginx-config-dir> [enable-ssl]" >&2
  exit 1
fi

services_file="$1"
nginx_dir="$2"
enable_ssl="${3:-false}"

[ -f "$services_file" ] || {
  echo "Services file not found: $services_file" >&2
  exit 1
}

[ -d "$nginx_dir" ] || mkdir -p "$nginx_dir"

template_http() {
  local service_id="$1"
  local service_path="$2"
  local service_port="$3"

  cat <<EOF
upstream ${service_id}_backend {
    server localhost:${service_port};
}

server {
    listen 80;
    server_name ${service_id}.core.local;
    
    location / {
        proxy_pass http://${service_id}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF
}

template_https() {
  local service_id="$1"
  local service_path="$2"
  local service_port="$3"

  cat <<EOF
upstream ${service_id}_backend {
    server localhost:${service_port};
}

server {
    listen 443 ssl http2;
    server_name ${service_id}.core.local;
    
    ssl_certificate /etc/nginx/ssl/core.crt;
    ssl_certificate_key /etc/nginx/ssl/core.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    location / {
        proxy_pass http://${service_id}_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}

server {
    listen 80;
    server_name ${service_id}.core.local;
    return 301 https://\$server_name\$request_uri;
}
EOF
}

echo "Generating Nginx ingress configs for all services..."

# Track generated configs
generated_count=0

while IFS= read -r service_line; do
  if [ -z "$service_line" ]; then continue; fi
  
  service_id=$(echo "$service_line" | jq -r '.id')
  service_path=$(echo "$service_line" | jq -r '.path // empty')
  service_port=$(echo "$service_line" | jq -r '.port // 8080')

  [ -z "$service_id" ] && continue

  config_file="${nginx_dir}/site-${service_id}.conf"

  if [ "$enable_ssl" = "true" ] || [ "$enable_ssl" = "1" ]; then
    template_https "$service_id" "$service_path" "$service_port" > "$config_file"
    echo "  ✓ $config_file (HTTPS)"
  else
    template_http "$service_id" "$service_path" "$service_port" > "$config_file"
    echo "  ✓ $config_file (HTTP)"
  fi

  generated_count=$((generated_count + 1))
done < <(jq -c '.[]' "$services_file" 2>/dev/null)

echo ""
echo "Generated $generated_count Nginx site configurations"
echo "Reload Nginx: nginx -s reload"
echo ""
echo "DNS entries needed (add to /etc/hosts or DNS server):"
jq -r '.[] | "\(.id).core.local"' "$services_file" 2>/dev/null | sort | uniq | \
  while IFS= read -r hostname; do
    echo "  127.0.0.1 $hostname"
  done

echo ""
[ "$enable_ssl" = "true" ] || [ "$enable_ssl" = "1" ] && {
  echo "SSL Certificates required:"
  echo "  /etc/nginx/ssl/core.crt"
  echo "  /etc/nginx/ssl/core.key"
  echo "Generate with: openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout core.key -out core.crt"
}
