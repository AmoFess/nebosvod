# Небосвод: устранение ошибки «Ошибка обновления для 40 городов (показаны старые данные)»

**Дата:** 16.09.2026
**Экземпляр:** CTID 200 (`nebosvod`) на Proxmox `192.168.1.61` (контейнер `192.168.1.71:8080`)
**Публичный адрес:** https://nebosvod.amofess.ru/
**Статус:** исправлено и проверено (40/40 городов обновляются)

---

## 1. Симптом

На веб-морде внизу появлялось: **«Ошибка обновления для 40 городов (показаны старые данные)»**.
Плитки показывали данные из браузерного кэша (localStorage), веб-морда выглядела
«живой», но сервис не мог получить свежую погоду ни для одного города.

## 2. Как устроена ошибка в коде (цепочка)

1. Фронтенд (`static/app.js`, `loadWeather`) делает один batch-запрос
   `GET /api/weather?city_ids=<40 id>`.
2. Сервер (`server.py`, `get_weather_batch` → `_fetch_many`) при пустом кэше
   синхронно тянет все города из Open-Meteo одним запросом
   (`BATCH_CHUNK = 60`, т.е. 40 городов = 1 HTTP-запрос).
3. Запрос падал (`OpenMeteoError` после 3 попыток), города попадали в
   `missing` → фронтенд считал их как «не обновилось» и выводил сообщение
   (`static/app.js:543`).
4. **Почему не помог stale-while-error:** он отдаёт последние успешные данные из
   файла `/opt/nebosvod/cache.json`, но файла на момент аварии не было
   (сервис перезапускался, а с момента блокировки ни одного успешного
   обновления не было — записывать в кэш было нечего). Поэтому «старые данные»
   показывал только браузер, а сервер — пустоту.

## 3. Корневая причина

**Провайдерская блокировка TLS к `api.open-meteo.com` по SNI (ТСПУ/ДПИ).**

Зафиксированная картина (все проверки выполнены на контейнере и хосте):

| Проверка | Результат |
|---|---|
| DNS `api.open-meteo.com` | резолвится в `94.130.142.35` (Hetzner, корректный адрес Open-Meteo) |
| TCP :443 до `94.130.142.35` | **открывается** (`nc -z` — OK) |
| TLS-рукопожатие, SNI = `api.open-meteo.com` | **зависает до таймаута** (TimeoutError) |
| TLS-рукопожатие, SNI = `example.com` на том же IP:порту | **проходит** (TLSv1.3) |
| TLS-рукопожатие, SNI = `geocoding-api.open-meteo.com` | **проходит**, https-геокодинг работает |
| TLS без SNI | сервер обрывает соединение (0 байт) |
| Обычный HTTP (`http://api.open-meteo.com/v1/forecast`) на :80 | **работает**, отдаёт валидный JSON |
| https извне сети (рабочая машина) | соединение **сбрасывается** (RST) — типичное поведение ТСПУ |

Вывод: блокировка селективная по имени хоста в ClientHello (SNI). Канал
`http://` на 80-м порту не затрагивается. Именно поэтому сервис, жёстко
зашитый на `https://api.open-meteo.com`, перестал обновляться **для всех
городов сразу** — отсюда и «40 городов» в одном сообщении.

Дополнительный нюанс: **http-фронтенд Open-Meteo не тянет большие batch-ответы**
(замеры с контейнера):

| Запрос по :80 | Время | Результат |
|---|---|---|
| 1 город с full-набором (current+daily+hourly) | 0,3 с | 200 OK |
| 5–40 городов с hourly | >120 с | зависание / 503 |

Поэтому одного перевода на http мало — нужны одиночные запросы на город.
Прокси-обход через `mihomo` роутера (`192.168.1.1:7890`, поддержка которого в
коде Небосвода есть через переменные `HTTP_PROXY/HTTPS_PROXY`) в момент
диагностики **не работал** для Open-Meteo — правило в конфигурации mihomo надо
чинить отдельно (см. раздел 8 «Альтернатива»).

## 4. Решение (что изменено)

### 4.1 Патч `server.py` (3 места, идемпотентно, дефолтное поведение не меняется)

Новая функция после констант URLs (строки 42–57):

```python
def apply_open_meteo_scheme(config):
    """ТСПУ блокирует TLS-хендшейк к api.open-meteo.com по SNI ...
    Для таких сетей в config.json можно включить
    `"open_meteo_http": true` — запросы к Open-Meteo будут уходить по http://
    в обход блокировки. ..."""
    if not config.get("open_meteo_http"):
        return
    global FORECAST_URL, GEOCODE_SEARCH_URL, GEOCODE_GET_URL
    FORECAST_URL = FORECAST_URL.replace("https://", "http://", 1)
    GEOCODE_SEARCH_URL = GEOCODE_SEARCH_URL.replace("https://", "http://", 1)
    GEOCODE_GET_URL = GEOCODE_GET_URL.replace("https://", "http://", 1)
    print("upstream: Open-Meteo через http:// (open_meteo_http=true)", flush=True)
```

В `WeatherService.__init__` после загрузки конфига:

```python
        self.config = self._load_config()
        apply_open_meteo_scheme(self.config)
        if self.config.get("open_meteo_http"):
            # http-фронтенд Open-Meteo не тянет большие батчевые ответы
            # (запросы с hourly-данными на несколько городов виснут или
            # отдают 503), поэтому города тянутся по одному. ...
            try:
                self.BATCH_CHUNK = max(1, int(self.config.get("open_meteo_http_batch_chunk", 1)))
            except (TypeError, ValueError):
                self.BATCH_CHUNK = 1
```

Также обновлены `config.json.example` и README (таблица параметров).

### 4.2 Конфиг `/opt/nebosvod/config.json`

Добавлен один ключ (остальные параметры не менялись):

```json
"open_meteo_http": true
```

### 4.3 Что было на контейнере фактически

```
# бэкапы перед изменениями:
/opt/nebosvod/backup/server.py.pre-open-meteo-http-fix
/opt/nebosvod/backup/config.json.pre-open-meteo-http-fix

# применение:
pct push 200 /tmp/server.py /opt/nebosvod/server.py      # патч
python3: config['open_meteo_http'] = True                # конфиг
rc-service nebosvod restart
```

## 5. Проверка работоспособности (после исправления)

Всё выполнено 16.09.2026:

1. `rc-status` — `nebosvod [started]`.
2. Прогрев (`warmup_on_start`) создал `/opt/nebosvod/cache.json`
   (69 КБ, 40 записей, возраст 0–13 с).
3. Принудительное обновление всех 40 городов через API сервиса:
   `GET /api/weather?city_ids=<все>&refresh=1`
   → `ok: 40, missing: 0, stale: 0`, время 13,7 с (40 одиночных http-запросов).
4. Публичный API: `https://nebosvod.amofess.ru/api/weather?city_id=1486209`
   → `stale` отсутствует, `updated_at` = текущее время, температура живая.
5. Публичная batch-вызов как у фронтенда:
   → `results=40, missing=0`.
6. Веб-интерфейс: `https://nebosvod.amofess.ru/` — `200 OK`.
7. Фоновое обновление каждые 15 минут (`background_refresh_minutes: 15`)
   работает на тех же одиночных запросах.

Нагрузка на лимиты Open-Meteo: 40 городов × ~4 обновления/час ≈ 3840
запросов/сутки при бесплатном лимите 10 000/сутки — с запасом.

## 6. Как откатить / как включить обратно https

Если блокировку снимут (или сервис переедет в сеть без блокировки):

```
pct exec 200 -- sh -c 'sed -i "s/\"open_meteo_http\": true/\"open_meteo_http\": false/" /opt/nebosvod/config.json'
pct exec 200 -- rc-service nebosvod restart
```

Сам патч при этом можно не трогать: без ключа поведение кода идентично апстриму.

## 7. Что делать при обновлении контейнера

Скрипт `install/nebosvod-update.sh` делает `git stash push` перед pull и
`git stash pop` после. Локальные изменения (`server.py`, `config.json` в git
не входит, `README.md`, `config.json.example`) переживут штатное обновление;
если `git stash pop` сообщит о конфликте — патч останется в stash
(`git stash list`) и его надо будет применить вручную по образцу раздела 4.1.
Файлы бэкапов — в `/opt/nebosvod/backup/`.

## 8. Альтернатива (если хочется вернуть https)

В коде уже поддерживается прокси из переменных окружения (`HTTP_PROXY` /
`HTTPS_PROXY`, mihomo на роутере). Чтобы ходить наружу через шифрованный
туннель, а не по http:

1. На роутере в правилах mihomo явно направить `api.open-meteo.com` (и
   `geocoding-api.open-meteo.com`) через рабочий узел/прокси — сейчас правило
   не срабатывает (через `192.168.1.1:7890` до Open-Meteo тоже таймаут).
2. В контейнере создать `/etc/conf.d/nebosvod`:
   `export HTTPS_PROXY=http://192.168.1.1:7890 HTTP_PROXY=http://192.168.1.1:7890`
   и `rc-service nebosvod restart`.
3. Вернуть `"open_meteo_http": false` в конфиге.

Оба варианта можно комбинировать; выбран http-вариант как не требующий
доступа к настройкам роутера и узла.

## 9. Замеченные побочные наблюдения

- `cache.json` отсутствовал до фикса — из-за этого «старые данные» брались
  только из localStorage браузера. После первого успешного обновления файл
  создан, и при будущих авариях источника UI будет показывать серверный stale.
- В `nebosvod.db` и городах изменений нет.
- Ошибок/предупреждений в логах init-скрипта не появлялось (stdout сервиса не
  перенаправляется в файл — полезный вывод `print` теряется; при желании можно
  добавить `command_stdout` в `/etc/init.d/nebosvod`).
