# FoodExpress — Сергеев Никита

PostgreSQL 17, схема `sergeev_food`.

[SQL](db/schema/) · [Ограничения](db/constraints.md) · [Модель](db/model.md) · [Проверки](db/tests.md) · [Архив](db/foodexpress_sergeev.backup)

## Установка

В пустой БД выполнить:

```sh
psql -U postgres -d foodexpress -v ON_ERROR_STOP=1 -f db/bootstrap.sql
psql -U postgres -d foodexpress -v ON_ERROR_STOP=1 -f db/install.sql
```

Если `exts.uuid_generate_v4()` уже существует, `bootstrap.sql` пропустить.
Пароль `inspector`: `NetoSQL2025`.

## Восстановление

```sh
psql -U postgres -d foodexpress -v ON_ERROR_STOP=1 -f db/bootstrap.sql
pg_restore -U postgres -d foodexpress --no-owner --exit-on-error db/foodexpress_sergeev.backup
psql -U postgres -d foodexpress -v ON_ERROR_STOP=1 -f db/schema/grants.sql
```

Архив содержит только `sergeev_food`, без данных. Требуется PostgreSQL 17+.
Данные: `CALL sergeev_food.insert_test_data(10);`.

## Проверки

```sh
psql -U inspector -d foodexpress -v ON_ERROR_STOP=1 -f db/tests/checks.sql
# Или установка, тесты и восстановление во временном Docker-контейнере:
bash db/test.sh
```

Тесты откатываются через `ROLLBACK`; логи — `/tmp/food-check.*`.

Заказ и позиции записываются в одной транзакции. `order_structure.unit_price` — цена на момент покупки.
Отзывы с `client_id` записываются через `review_with_client`: в таблице `review` автор определяется через заказ.
