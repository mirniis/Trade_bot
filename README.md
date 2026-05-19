# Super Trader Bot MVP

## Что уже реализовано
- Модульный backend на Rust
- UI в темной гамме с layout как в примере
- Автосохранение настроек и API ключей
- Переключение Demo и Real режима
- Production guard: в production разрешен только real mode
- Главная панель: статус, uptime, баланс, daily pnl, задержки, ордера, pnl history, scanner
- Логи: trades, errors, scanning, decision
- Watchdog script для автоперезапуска локально

## Быстрый запуск локально
1. Открыть терминал в папке ui
2. Выполнить npm install
3. Выполнить npm run build
4. Открыть терминал в папке backend
5. Выполнить cargo run
6. Открыть http://127.0.0.1:8080

## Запуск watchdog
1. В корне проекта выполнить powershell -File .\\run-local-watchdog.ps1

## Master запуск (установка зависимостей + автозапуск)
1. В корне проекта выполнить:
	 - powershell -ExecutionPolicy Bypass -File .\\run-master.ps1
2. Альтернатива одним .bat файлом для Windows:
	- .\\run-master.bat
2. Скрипт автоматически:
	 - проверит наличие node/npm/cargo
	 - установит UI зависимости (npm ci)
	 - соберет UI (npm run build)
	 - соберет backend (cargo build)
	 - запустит backend (cargo run)

Опции:
- Запуск через Docker:
	- powershell -ExecutionPolicy Bypass -File .\\run-master.ps1 -UseDocker
- Пропустить сборку UI:
	- powershell -ExecutionPolicy Bypass -File .\\run-master.ps1 -SkipUiBuild
- Чистая установка (очистить logs и сбросить PnL_stat):
	- powershell -ExecutionPolicy Bypass -File .\\run-master.ps1 -CleanInstall
- Задать окружение:
	- powershell -ExecutionPolicy Bypass -File .\\run-master.ps1 -AppEnv production

Опции для .bat:
- Запуск через Docker:
	- .\\run-master.bat --use-docker
- Установить Docker автоматически и запустить в Docker режиме:
	- .\\run-master.bat --use-docker --install-docker
- Пропустить сборку UI:
	- .\\run-master.bat --skip-ui-build
- Чистая установка (очистить logs и сбросить PnL_stat):
	- .\\run-master.bat --clean-install
- Задать окружение:
	- .\\run-master.bat --app-env production

### Linux / VPS master запуск
1. В корне проекта выдать права на запуск:
	 - chmod +x ./run-master.sh
2. Запустить:
	 - ./run-master.sh

Опции:
- Запуск через Docker:
	- ./run-master.sh --use-docker
- Пропустить сборку UI:
	- ./run-master.sh --skip-ui-build
- Чистая установка (очистить logs и сбросить PnL_stat):
	- ./run-master.sh --clean-install
- Задать окружение:
	- ./run-master.sh --app-env production

## Запуск в контейнере
1. docker compose up --build

## Деплой на Beget.com
1. Важно выбрать правильный тип хостинга:
	- Beget Shared Hosting: не подходит для этого проекта (нужен постоянный Rust backend процесс, WebSocket/SSE и полный контроль над окружением).
	- Beget VPS/Cloud: подходит, использовать сценарий ниже.
2. Если у вас сейчас Shared Hosting, оптимальный путь:
	- взять Beget VPS (Ubuntu 22.04/24.04)
	- перенести домен на VPS через A-запись
3. На Beget VPS выполнить деплой через Docker по инструкции ниже (раздел "Деплой на хостинг (VPS, Ubuntu) через Docker").
4. В панели Beget для домена:
	- направить домен на IP VPS
	- выпустить SSL (Let's Encrypt) на стороне Nginx
5. После деплоя проверить:
	- curl http://127.0.0.1:8080/api/health
	- открыть домен и убедиться, что UI грузится и API отвечает.

## Деплой на хостинг (VPS, Ubuntu) через Docker
1. Подготовить сервер:
	- установить Docker и Docker Compose plugin
	- открыть в firewall порты 80 и 443 (или 8080, если без reverse proxy)
2. Клонировать проект на сервер:
	- git clone <repo_url>
	- cd dev_ai
3. Собрать UI (обязательно, иначе backend не сможет отдать рабочий frontend):
	- cd ui
	- npm ci
	- npm run build
	- cd ..
4. Проверить файлы конфигурации:
	- data/settings.json (mode, risk, trading_schedule)
	- data/settings.json -> api_keys (ключи demo/real)
5. Запустить контейнер:
	- docker compose up -d --build
6. Проверить, что backend поднялся:
	- curl http://127.0.0.1:8080/api/health

Важно:
- В production backend теперь слушает 0.0.0.0 (локально по умолчанию 127.0.0.1).
- Можно переопределить адрес/порт переменными HOST и PORT.

## Обновление на хостинге
1. cd dev_ai
2. git pull
3. cd ui && npm ci && npm run build && cd ..
4. docker compose up -d --build
5. docker ps
6. curl http://127.0.0.1:8080/api/health

## Рекомендуемый reverse proxy (Nginx)
1. Проксировать домен на http://127.0.0.1:8080
2. Включить HTTPS через Certbot
3. Для автоматического старта после reboot оставить restart: always в docker-compose.yml

## Перенос проекта на другой компьютер
1. На текущем компьютере остановить бота, чтобы не повредить файлы в момент копирования.
2. Скопировать проект целиком в новую машину (через git clone или архив папки).
3. Обязательно перенести рабочие данные:
	- data/settings.json
	- data/PnL_stat.json
	- data/logs (если нужна история)
4. На новом компьютере установить зависимости:
	- Node.js (для сборки UI)
	- Rust toolchain (rustup + cargo)
	- Docker Desktop (если запуск через контейнер)
5. Первый запуск без Docker:
	- в папке ui: npm ci && npm run build
	- в папке backend: cargo run
	- проверить: http://127.0.0.1:8080/api/health
6. Первый запуск через Docker:
	- в папке ui: npm ci && npm run build
	- в корне: docker compose up -d --build
	- проверить: http://127.0.0.1:8080/api/health
7. После запуска открыть UI и проверить:
	- режим (demo/real)
	- баланс, ордера, историю PnL
	- что ключи API подхватились корректно.

Совет:
- Если переносите между Windows и Linux, проверьте права доступа к папке data и корректность путей в скриптах.

## Пути
- Backend: backend
- UI: ui
- Settings: data/settings.json
- API keys: data/settings.json -> api_keys
- Logs: data/logs

## Основные API
- GET /api/health
- GET /api/dashboard
- GET /api/dashboard/stream
- GET /api/settings
- PUT /api/settings
- GET /api/api-keys
- PUT /api/api-keys
- POST /api/bot/start
- POST /api/bot/stop
