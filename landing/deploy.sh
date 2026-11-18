#!/bin/sh
set -eu

cd "$(dirname "$0")"

env_value() {
  grep -E "^$1=" .env | tail -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./deploy.sh" >&2; exit 1; }
[ -f .env ] || { echo ".env not found, copy .env.example" >&2; exit 1; }

DOMAIN=$(env_value DOMAIN | sed -E -e 's#^[a-z]+://##' -e 's#[/:].*$##')
EMAIL=$(env_value LETSENCRYPT_EMAIL)
[ -n "$DOMAIN" ] || { echo "DOMAIN is empty, check .env" >&2; exit 1; }

PORT=$(env_value LANDING_PORT)
PORT=${PORT:-8090}
CERT_DIR=/etc/letsencrypt/live/$DOMAIN

if [ -d /etc/nginx/sites-available ]; then
  CONF=/etc/nginx/sites-available/$DOMAIN.conf
  LINK=/etc/nginx/sites-enabled/$DOMAIN.conf
else
  CONF=/etc/nginx/conf.d/$DOMAIN.conf
  LINK=
fi

docker compose version >/dev/null 2>&1 || { echo "docker compose not found: curl -fsSL https://get.docker.com | sh" >&2; exit 1; }

# The container builds the site and serves it on 127.0.0.1:$PORT; host nginx terminates TLS in front of it
LANDING_PORT=$PORT docker compose up -d --build --remove-orphans
docker image prune -f >/dev/null

i=0
until curl -fsS -o /dev/null "http://127.0.0.1:$PORT/"; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || { echo "container does not answer on 127.0.0.1:$PORT" >&2; docker compose logs --tail 50 >&2; exit 1; }
  sleep 1
done

site_body() {
  cat <<CONF
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
CONF
}

write_http_conf() {
  {
    echo "server {"
    echo "    listen 80;"
    echo "    server_name $DOMAIN;"
    site_body
    echo "}"
  } > "$1"
}

write_https_conf() {
  {
    echo "server {"
    echo "    listen 443 ssl;"
    echo "    http2 on;"
    echo "    server_name $DOMAIN;"
    echo ""
    echo "    ssl_certificate $CERT_DIR/fullchain.pem;"
    echo "    ssl_certificate_key $CERT_DIR/privkey.pem;"
    [ -f /etc/letsencrypt/options-ssl-nginx.conf ] &&
      echo "    include /etc/letsencrypt/options-ssl-nginx.conf;"
    [ -f /etc/letsencrypt/ssl-dhparams.pem ] &&
      echo "    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;"
    echo ""
    site_body
    echo "}"
    echo ""
    echo "server {"
    echo "    listen 80;"
    echo "    server_name $DOMAIN;"
    echo "    return 301 https://\$host\$request_uri;"
    echo "}"
  } > "$1"
}

install_conf() {
  [ -f "$CONF" ] && cp "$CONF" "$CONF.previous"
  cp "$1" "$CONF"
  [ -n "$LINK" ] && ln -sf "$CONF" "$LINK"

  if nginx -t 2>/dev/null; then
    systemctl reload nginx
  else
    nginx -t || true
    if [ -f "$CONF.previous" ]; then mv "$CONF.previous" "$CONF"; else rm -f "$CONF" ${LINK:+"$LINK"}; fi
    echo "nginx config is invalid, the previous one is kept" >&2
    exit 1
  fi
}

HOOK=/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
mkdir -p "$(dirname "$HOOK")"
printf '#!/bin/sh\nsystemctl reload nginx\n' > "$HOOK"
chmod +x "$HOOK"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
  write_http_conf "$TMP"
  install_conf "$TMP"
fi

if [ -n "$EMAIL" ]; then
  set -- --email "$EMAIL"
else
  set -- --register-unsafely-without-email
fi

if ! certbot certonly --nginx --non-interactive --agree-tos "$@" --keep-until-expiring \
  --cert-name "$DOMAIN" -d "$DOMAIN"; then
  [ -f "$CERT_DIR/fullchain.pem" ] || { echo "certbot failed, no certificate yet" >&2; exit 1; }
  echo "certbot failed, keeping the existing certificate" >&2
fi

write_https_conf "$TMP"
install_conf "$TMP"

echo "Done: https://$DOMAIN -> 127.0.0.1:$PORT"
