# Delivest Bastion

Единая панель для всех экземпляров [Delivest](https://github.com/ShafranovKirill/delivest). Агент каждого экземпляра сам подключается к бастиону по websocket и регистрируется по общему токену. В бастионе видно, работает ли каждый сайт, а также можно обновить, перезапустить, выключить и включить сайт и посмотреть логи.

- Экземпляры появляются сами, как только в их `.env` указаны `BASTION_URL` и `BASTION_TOKEN`.
- Агент присылает состояние контейнеров, версии образов, свободное место на диске и проверки сайта изнутри.
- Раз в минуту бастион сам проверяет API и сайт снаружи и срок SSL-сертификата.
- При смене состояния бастион присылает уведомление в Telegram, если он настроен.

Деплой на сервер: [DEPLOY.md](DEPLOY.md).

## Разработка

```bash
mix setup
mix phx.server
```

Панель: http://localhost:4000, логин `admin`, пароль `admin`. Агент локально подключается с `BASTION_URL=ws://localhost:4000` и `BASTION_TOKEN=dev-agent-token`.

## Протокол агента

- Подключение: `wss://<домен>/agent/websocket?token=<AGENT_TOKEN>&instance_id=<uuid>`.
- Топик: `instance:<uuid>`. При входе агент передаёт `name`, `hosts`, `agent_version` и `actions`.
- От агента приходят `heartbeat` (состояние), `command_started` и `command_result` (`id`, `ok`, `output`).
- Агенту уходит `command` (`id`, `action`, `args`). Действия: `status`, `update`, `start`, `stop`, `restart`, `logs`.
