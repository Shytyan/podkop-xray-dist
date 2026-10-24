# Podkop (Xray edition)

[Podkop](https://github.com/itdoginfo/podkop) для OpenWrt на ядре Xray-core. OpenWrt 24.10+ (opkg) и 25.12+ (apk).

## Установка

На роутере по SSH:

```sh
sh <(wget -O - https://raw.githubusercontent.com/Shytyan/podkop-xray-dist/main/install.sh)
```

Установщик заменит старый podkop (копия настроек — `/etc/config/podkop.bak-<дата>`), поставит пакеты из последнего релиза и проверенную версию Xray-core.

Если провайдер блокирует github.com, установщик сам скачает пакеты и Xray-core через api.github.com (с проверкой sha256).

Параметры:

| | |
|---|---|
| `-y` | без вопросов |
| `--ru` | русский язык интерфейса |
| `--xray-latest` | последняя стабильная версия Xray-core |
| `--xray-version=X` | конкретная версия Xray-core |
| `--no-doh-proxy` | без `https-dns-proxy` |

Дальше: LuCI → Services → Podkop → ссылка на сервер → «Сохранить и применить».
