# RedStableInfra

Система централизованного управления распределённой атакующей инфраструктурой на базе Raspberry Pi, Tailscale и ESP8266/ESP32.

> Подробная статья с описанием архитектуры и всех компонентов:
> **[ССЫЛКУ НА СТАТЬЮ]**

## Что это

Когда в арсенале red team команды десятки устройств на разных локациях, управлять ими вручную становится невозможно. RedStableInfra решает эту проблему:

- Единый веб-интерфейс для мониторинга всех устройств
- Автоматическая генерация образов для новых хабов за 2–3 минуты
- Mesh VPN через Tailscale + self-hosted Headscale — без проброса портов, работает за NAT
- Мониторинг и алерты через Zabbix
- Сбор данных с периферии (ESP8266/ESP32) через Wi-Fi

## Архитектура

```
Уровень 1: Серверы
├── Headscale (VPN координатор, публичный VPS)
└── Infra Server (Flask, Zabbix, генерация образов)

Уровень 2: Хабы
└── Raspberry Pi 5 (Debian 13 Trixie, offensive-инструменты, Hub UI, ttyd)

Уровень 3: Периферия
└── ESP8266/ESP32 (кейлоггеры, BadUSB, импланты — связь через Wi-Fi)
```

## Структура репозитория

```
├── server/                  # Infra Server (Flask)
│   ├── app.py              # Основное приложение
│   ├── config.py           # Конфигурация (плейсхолдеры)
│   ├── .env.example        # Шаблон переменных окружения
│   ├── images/scripts/     # Скрипт персонализации образов
│   ├── templates/          # HTML-шаблоны
│   ├── static/             # CSS, JS
│   └── docs/               # Документация (доступна через веб-интерфейс)
│
├── hub/                     # Hub-приложение (Flask, работает на каждом хабе)
│   ├── app.py              # Управление периферией
│   ├── create_example_db.py # Создание тестовой БД
│   ├── templates/
│   └── static/
│
├── image-scripts/           # Скрипты сборки образов
│   ├── 00-build-arm64-artifacts-trixie.sh  # Сборка артефактов
│   ├── 01-build-base-pi-image-trixie.sh    # Базовый образ
│   ├── 02-personalize-pi-image-trixie.sh   # Персонализация
│   └── verify-tools.sh                     # Проверка установки
│
├── docs/                    # Документация
│   ├── ARCHITECTURE.md     # Архитектура системы
│   ├── BUILD-GUIDE.md      # Инструкция по сборке образов
│   ├── HEADSCALE-GUIDE.md  # Настройка Headscale/Tailscale
│   ├── IMAGE-CONTENTS.md   # Содержимое образа
│   └── ZABBIX-MONITORING.md # Метрики мониторинга
│
├── install_go_tailscale.sh  # Установка Go + сборка Tailscale из исходников
├── CONFIGURATION.md         # Гайд по замене плейсхолдеров
└── README.md
```
