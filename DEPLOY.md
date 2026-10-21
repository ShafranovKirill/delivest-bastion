# Деплой бастиона на сервер

Бастион живёт на своём домене, например `bastion.example.com`. Ставить его можно на отдельный сервер или на сервер с одним из сайтов Delivest.

## 0. Что нужно заранее

- Сервер с Ubuntu или Debian и root-доступом.
- Домен для бастиона, у которого A-запись указывает на IP сервера. Проверить: `dig +short bastion.example.com`.
- Открытые порты 80 и 443. Если включён ufw: `ufw allow 'Nginx Full'`.

## 1. Подготовить сервер

Если на сервере уже стоит Delivest, этот шаг пропустите: всё нужное уже установлено.

```bash
apt update && apt upgrade -y
curl -fsSL https://get.docker.com | sh
apt install -y nginx certbot python3-certbot-nginx
```

## 2. Скачать проект

```bash
git clone https://github.com/ShafranovKirill/delivest-bastion.git /root/bastion
cd /root/bastion
cp .env.example .env
```

## 3. Заполнить `.env`

Сгенерируйте секреты:

```bash
openssl rand -base64 48   # SECRET_KEY_BASE
openssl rand -hex 16      # DB_PASSWORD
openssl rand -hex 32      # AGENT_TOKEN
```

```bash
nano .env
```

| Переменная | Что указать |
| --- | --- |
| `PHX_HOST` | домен бастиона без `https://`: `bastion.example.com` |
| `BASTION_PORT` | свободный локальный порт, например `4100`. Если на сервере есть Delivest, порт должен отличаться от его `GATEWAY_PORT` |
| `LETSENCRYPT_EMAIL` | почта для писем Let's Encrypt о сертификате |
| `SECRET_KEY_BASE` | сгенерированное значение |
| `DB_PASSWORD` | сгенерированный пароль базы |
| `ADMIN_LOGIN` / `ADMIN_PASSWORD` | логин и пароль для входа в панель |
| `AGENT_TOKEN` | общий токен агентов, его же указывают в Delivest как `BASTION_TOKEN` |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | уведомления в Telegram, можно оставить пустыми (шаг 7) |

## 4. Подключить nginx и получить сертификат

```bash
./deploy/host-nginx.sh
```

Скрипт создаёт сайт nginx для `PHX_HOST`, получает сертификат Let's Encrypt и включает HTTPS с поддержкой websocket. Запускать его повторно безопасно.

## 5. Запустить

```bash
docker compose pull
docker compose up -d
docker compose logs bastion --tail 20
```

Миграции применяются сами при каждом старте. Откройте `https://bastion.example.com` и войдите с `ADMIN_LOGIN` и `ADMIN_PASSWORD`.

## 6. Подключить сайты Delivest

На каждом сервере с Delivest допишите в `.env` сайта:

```
BASTION_URL=wss://bastion.example.com
BASTION_TOKEN=<AGENT_TOKEN из .env бастиона>
INSTANCE_NAME=Название сети
```

Затем в папке сайта:

```bash
docker compose pull
docker compose up -d
docker logs delivest_agent --tail 20
```

В логах агента должно быть `joined bastion`, а сайт через несколько секунд появится в панели. Если `COMPOSE_PROJECT_NAME` у сайта не `delivest`, контейнер называется `<COMPOSE_PROJECT_NAME>_agent`.

## 7. Уведомления в Telegram

1. Создайте бота у [@BotFather](https://t.me/BotFather) и скопируйте токен.
2. Напишите боту любое сообщение. Для группы добавьте бота в группу и напишите в неё.
3. Узнайте id чата: `curl https://api.telegram.org/bot<ТОКЕН>/getUpdates`, нужно поле `chat.id`.
4. Впишите `TELEGRAM_BOT_TOKEN` и `TELEGRAM_CHAT_ID` в `.env` бастиона и выполните `docker compose up -d`.

Бастион пишет, когда сайт перестаёт отвечать, когда агент пропадает со связи дольше чем на 2 минуты и когда всё снова работает.

## Обновление бастиона

```bash
cd /root/bastion
git pull
docker compose pull
docker compose up -d
```

## Бэкап базы

```bash
docker exec bastion_postgres pg_dump -U postgres bastion | gzip > /root/bastion-$(date +%F).sql.gz
```

В базе хранятся список экземпляров и история команд. Если её потерять, агенты зарегистрируются заново сами.

## Если что-то не работает

| Симптом | Где смотреть |
| --- | --- |
| панель не открывается | `docker compose ps`, `docker compose logs bastion --tail 50`, `nginx -t` |
| certbot не получает сертификат | DNS указывает на сервер? открыт порт 80? |
| сайт не появляется в панели | `docker logs delivest_agent`: совпадает ли `BASTION_TOKEN` с `AGENT_TOKEN`, начинается ли `BASTION_URL` с `wss://` |
| агент пишет `bastion disconnected` | доступен ли домен бастиона с сервера сайта: `curl -I https://bastion.example.com` |
| экземпляр «Не на связи», хотя сайт работает | `docker compose ps` в папке сайта: запущен ли контейнер `agent` |
