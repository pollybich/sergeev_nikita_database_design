# FoodExpress — Сергеев Никита

PostgreSQL 17, схема `sergeev_food`. Выполнены FOOD-101–FOOD-110.

- [SQL](db/schema/)
- [Обоснование ограничений](db/constraints.md)
- [Логическая модель](db/model.md)
- [Протокол проверок](db/tests.md)
- [Резервная копия](db/foodexpress_sergeev.backup)
- [Исходное задание](https://github.com/NKhashchanov/total_designing_db_2026)

## Установка

В новой БД сначала подготовить расширение; если `exts.uuid_generate_v4()` уже есть, первый шаг пропустить:

```sh
psql -U postgres -d foodexpress -v ON_ERROR_STOP=1 -f db/bootstrap.sql
psql -U postgres -d foodexpress -v ON_ERROR_STOP=1 -f db/install.sql
psql -U inspector -d foodexpress -v ON_ERROR_STOP=1 -f db/tests/checks.sql
```

Пароль `inspector` по условию: `NetoSQL2025`. Скрипты установки запускаются один раз на пустой схеме. `grants.sql` можно запускать повторно.

## Восстановление

```sh
psql -U postgres -d foodexpress -v ON_ERROR_STOP=1 -f db/bootstrap.sql
pg_restore -U postgres -d foodexpress --no-owner --exit-on-error db/foodexpress_sergeev.backup
psql -U postgres -d foodexpress -v ON_ERROR_STOP=1 -f db/schema/grants.sql
psql -U inspector -d foodexpress -v ON_ERROR_STOP=1 -f db/tests/checks.sql
```

Архив содержит только схему `sergeev_food`, без данных, роли и расширения. После восстановления данные создаются `CALL sergeev_food.insert_test_data(10);`. Архив сделан PostgreSQL 17; восстанавливать в PostgreSQL 17 или новее.

## Полная проверка через Docker

```sh
bash db/test.sh
```

Скрипт создаёт временный PostgreSQL без опубликованных портов, устанавливает схему, проверяет её под `inspector`, делает архив, восстанавливает в отдельную БД и повторяет проверки. Архив обновляется после успешной проверки. Тесты выполняются в транзакции с `ROLLBACK`; логи сохраняются в `/tmp/food-check.*`.

При добавлении заказа вручную заказ, позиции и платежи записываются в одной транзакции. У позиции обязательно указывается `unit_price` — цена на момент покупки.
