SET search_path = sergeev_food, exts, pg_catalog;

CREATE PROCEDURE add_product(
    p_restaurant_id uuid, p_product_category_id uuid, p_name varchar,
    p_price numeric, p_rating numeric, p_status product_status,
    p_description text, p_photo_url text DEFAULT NULL)
LANGUAGE plpgsql SET search_path = sergeev_food, exts, pg_catalog AS $$
BEGIN
    IF NOT EXISTS (SELECT FROM restaurant WHERE restaurant_id = p_restaurant_id) THEN
        RAISE EXCEPTION 'Ресторан % не существует', p_restaurant_id USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT FROM product_category WHERE product_category_id = p_product_category_id) THEN
        RAISE EXCEPTION 'Категория % не существует', p_product_category_id USING ERRCODE = '23503';
    END IF;
    IF p_price < 0 OR p_price = 'NaN'::numeric THEN
        RAISE EXCEPTION 'Цена блюда должна быть неотрицательной' USING ERRCODE = '23514';
    END IF;
    IF p_rating NOT BETWEEN 0 AND 5 THEN
        RAISE EXCEPTION 'Рейтинг блюда должен быть от 0 до 5' USING ERRCODE = '23514';
    END IF;
    INSERT INTO product(product_name, product_category_id, price, restaurant_id, photo_url, rating, status, description)
    VALUES (p_name, p_product_category_id, p_price, p_restaurant_id, p_photo_url, p_rating, p_status, p_description);
END $$;

CREATE FUNCTION get_statistic() RETURNS TABLE (
    restaurant_name varchar, best_product_name varchar, total_amount numeric,
    avg_amount numeric, best_user varchar)
LANGUAGE sql VOLATILE SET search_path = sergeev_food, exts, pg_catalog AS $$
    WITH delivered AS MATERIALIZED (
        SELECT order_id, restaurant_id, client_id, total_amount FROM "order" WHERE status = 'доставлен'
    ), amounts AS (
        SELECT restaurant_id, sum(total_amount) AS total, avg(total_amount) AS average
        FROM delivered GROUP BY restaurant_id
    ), products AS (
        SELECT DISTINCT ON (d.restaurant_id) d.restaurant_id, s.product_id
        FROM delivered d JOIN order_structure s USING(order_id)
        GROUP BY d.restaurant_id, s.product_id
        ORDER BY d.restaurant_id, sum(s.quantity) DESC, random()
    ), users AS (
        SELECT DISTINCT ON (restaurant_id) restaurant_id, client_id FROM delivered
        GROUP BY restaurant_id, client_id ORDER BY restaurant_id, count(*) DESC, random()
    )
    SELECT r.restaurant_name, p.product_name, coalesce(a.total, 0), a.average, c.login
    FROM restaurant r LEFT JOIN amounts a USING(restaurant_id)
    LEFT JOIN products b USING(restaurant_id) LEFT JOIN product p USING(product_id)
    LEFT JOIN users u ON u.restaurant_id = r.restaurant_id LEFT JOIN client c ON c.client_id = u.client_id;
$$;

CREATE FUNCTION next_coefficient(deliveries bigint) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN deliveries <= 150 THEN 0.1 WHEN deliveries <= 250 THEN 0.2
                WHEN deliveries <= 500 THEN 0.3 ELSE 0.5 END;
$$;

CREATE PROCEDURE courier_salary() LANGUAGE plpgsql
SET search_path = sergeev_food, exts, pg_catalog AS $$
DECLARE c record; m timestamp := date_trunc('month', localtimestamp);
    y int := extract(year FROM m); mon int := extract(month FROM m);
    used numeric; commissions numeric; deliveries bigint;
BEGIN
    -- Блокировка курьеров также сериализует два одновременных расчёта.
    FOR c IN SELECT * FROM courier ORDER BY courier_id FOR UPDATE LOOP
        SELECT count(*), coalesce(sum(commission), 0) INTO deliveries, commissions
        FROM "order" WHERE courier_id = c.courier_id AND status = 'доставлен'
            AND order_timestamp >= m AND order_timestamp < m + interval '1 month';
        SELECT coefficient_used INTO used FROM courier_pay
        WHERE year = y AND month = mon AND courier_id = c.courier_id;
        used := coalesce(used, c.coefficient);
        INSERT INTO courier_pay(year, month, courier_id, amount, coefficient_used)
        VALUES(y, mon, c.courier_id, round(used * commissions, 2), used)
        ON CONFLICT (year, month, courier_id) DO UPDATE
            SET amount = excluded.amount;
        IF c.status <> 'уволен' THEN
            UPDATE courier SET coefficient = next_coefficient(deliveries) WHERE courier_id = c.courier_id;
        END IF;
    END LOOP;
END $$;

CREATE VIEW how_much_money AS
WITH RECURSIVE monthly AS MATERIALIZED (
    SELECT date_trunc('month', order_timestamp)::date AS m,
        sum(order_amount) AS no_commission, sum(total_amount) AS with_commission
    FROM "order" WHERE status = 'доставлен' GROUP BY 1
), bounds AS (
    SELECT min(m) AS first_month, max(m) AS last_month FROM monthly
), months(m) AS (
    SELECT first_month FROM bounds WHERE first_month IS NOT NULL
    UNION ALL SELECT (m + interval '1 month')::date FROM months, bounds WHERE m < last_month
), salaries AS (
    SELECT make_date(year, month, 1) AS m, sum(amount) AS amount FROM courier_pay GROUP BY 1
), amounts AS (
    SELECT months.m, coalesce(no_commission, 0) AS sum_no_commission,
        coalesce(with_commission, 0) AS sum_with_commission,
        coalesce(with_commission - no_commission, 0) AS commission,
        coalesce(s.amount, 0) AS courier_pay
    FROM months LEFT JOIN monthly USING(m) LEFT JOIN salaries s USING(m)
), previous AS (
    SELECT *, lag(commission) OVER (ORDER BY m) AS prev_commission FROM amounts
)
SELECT to_char(m, 'YYYY-MM')::text AS year_month, sum_no_commission, sum_with_commission,
    commission, prev_commission, commission - prev_commission AS commission_diff,
    courier_pay, commission - courier_pay AS net_profit FROM previous;
