\set ON_ERROR_STOP on
\timing on
SELECT version(), current_user, current_date;
SET search_path = sergeev_food, exts, pg_catalog;
BEGIN;
CREATE FUNCTION pg_temp.assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', label; END IF;
    RAISE NOTICE 'OK: %', label;
END $$;
CREATE FUNCTION pg_temp.reject(statement text, expected_state text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE statement;
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Не отклонено: %', statement USING ERRCODE = 'XX000';
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> expected_state THEN RAISE; END IF;
        RAISE NOTICE 'OK: отклонено (%)', expected_state;
    END;
    SET CONSTRAINTS ALL DEFERRED;
END $$;
SELECT pg_temp.assert(current_user = 'inspector', 'роль inspector');
SELECT pg_temp.assert((SELECT count(*) = 12 FROM information_schema.tables
    WHERE table_schema = 'sergeev_food' AND table_type = 'BASE TABLE'), '12 таблиц');
SELECT pg_temp.assert((SELECT count(*) = 8 FROM pg_type WHERE typnamespace = 'sergeev_food'::regnamespace AND typtype = 'e'), '8 enum');
SELECT pg_temp.assert(NOT EXISTS (SELECT FROM information_schema.columns WHERE table_schema = 'sergeev_food'
    AND column_name LIKE '%\_id' ESCAPE '\' AND data_type <> 'uuid'), 'все ID uuid');
SELECT pg_temp.assert((SELECT count(*) >= 15 FROM pg_constraint WHERE connamespace = 'sergeev_food'::regnamespace AND contype = 'f'), 'FK из ERD');
SELECT pg_temp.assert((SELECT array_agg(column_name::text ORDER BY ordinal_position) = ARRAY[
    'year_month','sum_no_commission','sum_with_commission','commission','prev_commission','commission_diff','courier_pay','net_profit']
    FROM information_schema.columns WHERE table_schema='sergeev_food' AND table_name='how_much_money')
    AND (SELECT bool_and(data_type=CASE WHEN column_name='year_month' THEN 'text' ELSE 'numeric' END)
    FROM information_schema.columns WHERE table_schema='sergeev_food' AND table_name='how_much_money'),
    'имена и типы колонок how_much_money');
SELECT pg_temp.assert((SELECT proargnames=ARRAY['restaurant_name','best_product_name','total_amount','avg_amount','best_user']
    FROM pg_proc WHERE oid='sergeev_food.get_statistic()'::regprocedure), 'имена колонок get_statistic');
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM information_schema.columns WHERE table_schema='sergeev_food'
    AND table_name='review' AND column_name='client_id') AND EXISTS(SELECT FROM information_schema.views
    WHERE table_schema='sergeev_food' AND table_name='review_with_client'), 'автор отзыва выведен через заказ без дублирования');
SELECT pg_temp.assert(has_schema_privilege(current_user, 'sergeev_food', 'USAGE,CREATE')
    AND has_schema_privilege(current_user, 'exts', 'USAGE'), 'права на схемы');
SELECT pg_temp.assert((SELECT count(*) = 12 FROM pg_catalog.pg_tables WHERE schemaname = 'sergeev_food'), 'чтение pg_catalog');
SELECT pg_temp.assert((SELECT extnamespace = 'exts'::regnamespace FROM pg_extension WHERE extname = 'uuid-ossp'), 'uuid-ossp в exts');
CALL erase_test_data();
CALL erase_test_data();
SELECT pg_temp.assert((SELECT count(*)=0 FROM how_much_money)
    AND (SELECT count(*)=0 FROM get_statistic()), 'отчёты на пустой схеме');
CALL insert_test_data(10);
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
DO $$
DECLARE t text; n bigint;
BEGIN
    FOREACH t IN ARRAY ARRAY['client','courier','product_category','restaurant','address','product','order','review','payment','client_address','order_structure','courier_pay'] LOOP
        EXECUTE format('SELECT count(*) FROM %I',t) INTO n;
        PERFORM pg_temp.assert(n = CASE WHEN t IN ('client','courier','product_category','restaurant') THEN 10
            WHEN t='client_address' THEN 40 WHEN t='courier_pay' THEN 60 ELSE 50 END, 'число строк ' || t || ' = ' || n);
    END LOOP;
END $$;
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM client WHERE password !~ '^[0-9a-f]{32}$'), 'пароли MD5');
SELECT pg_temp.assert(EXISTS(SELECT FROM courier WHERE status <> 'уволен'), 'есть активный курьер');
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM "order" o LEFT JOIN client_address ca USING(client_id,address_id)
    WHERE ca.client_id IS NULL), 'адрес принадлежит клиенту');
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM order_structure s JOIN "order" o USING(order_id)
    JOIN product p USING(product_id) WHERE p.restaurant_id <> o.restaurant_id), 'блюда из ресторана заказа');
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM "order" o LEFT JOIN payment p ON p.order_id=o.order_id AND p.status='успех'
    GROUP BY o.order_id HAVING count(p.payment_id) <> 1), 'одна успешная оплата на каждый сгенерированный заказ');
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM payment p JOIN "order" o USING(order_id) WHERE p.amount<>o.total_amount)
    AND NOT EXISTS(SELECT FROM "order" WHERE total_amount<1000 OR commission<>round(order_amount*.1,2)
        OR total_amount<>order_amount+commission), 'суммы и комиссия');
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM "order" WHERE order_timestamp < localtimestamp-interval '6 months'
    OR order_timestamp>localtimestamp OR delivery_timestamp<order_timestamp OR delivery_timestamp>localtimestamp), 'даты за последние 6 месяцев');
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM courier_pay cp LEFT JOIN (
    SELECT courier_id, extract(year FROM order_timestamp) AS y, extract(month FROM order_timestamp) AS m,
        sum(commission) AS s FROM "order" WHERE status='доставлен' GROUP BY 1,2,3
    ) o ON (cp.courier_id,cp.year,cp.month)=(o.courier_id,o.y,o.m)
    WHERE cp.amount<>round(cp.coefficient_used*coalesce(o.s,0),2)), 'история выплат по фактическим комиссиям');
SELECT pg_temp.assert((SELECT count(*)=10 AND bool_and(total_amount>=avg_amount AND best_user IS NOT NULL AND best_product_name IS NOT NULL)
    FROM get_statistic()), 'статистика по всем ресторанам');
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM product p WHERE p.rating IS DISTINCT FROM
    (SELECT round(avg(rating),2) FROM review r WHERE r.entity_type='блюдо' AND r.entity_id=p.product_id))
    AND NOT EXISTS(SELECT FROM restaurant p WHERE p.rating IS DISTINCT FROM
    (SELECT round(avg(rating),2) FROM review r WHERE r.entity_type='ресторан' AND r.entity_id=p.restaurant_id)), 'агрегированные рейтинги');
EXPLAIN (ANALYZE, VERBOSE, BUFFERS) SELECT * FROM get_statistic();
-- Тело SQL-функции отдельно: Function Scan скрывает внутренние узлы плана.
SELECT 'EXPLAIN (ANALYZE, BUFFERS) ' || prosrc
FROM pg_proc WHERE oid='sergeev_food.get_statistic()'::regprocedure
\gexec
EXPLAIN ANALYZE SELECT c.courier_id,
    (SELECT count(*) FROM "order" o WHERE o.courier_id=c.courier_id AND o.status='доставлен'),
    (SELECT coalesce(sum(commission),0) FROM "order" o WHERE o.courier_id=c.courier_id AND o.status='доставлен')
FROM courier c;
EXPLAIN ANALYZE SELECT c.courier_id, count(o.order_id), coalesce(sum(o.commission),0)
FROM courier c LEFT JOIN "order" o ON o.courier_id=c.courier_id AND o.status='доставлен'
GROUP BY c.courier_id;
SELECT pg_temp.reject('CALL insert_test_data(0)', '22023');
SELECT pg_temp.reject('CALL insert_test_data(NULL)', '22023');
SELECT pg_temp.reject($q$INSERT INTO client(login,password,phone_number) VALUES('',md5('x'),'test')$q$, '23514');
SELECT pg_temp.reject($q$UPDATE restaurant SET work_end=work_start$q$, '23514');
SELECT pg_temp.reject($q$UPDATE courier SET coefficient=.6$q$, '23514');
SELECT pg_temp.reject($q$UPDATE "order" SET address_id=exts.uuid_generate_v4()$q$, '23503');
SELECT pg_temp.reject($q$UPDATE "order" SET delivery_timestamp=order_timestamp-interval '1 day'$q$, '23514');
SELECT pg_temp.reject($q$UPDATE payment SET amount=amount+1$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO payment(order_id,type,amount,transaction_ref,status)
    SELECT order_id,type,amount,exts.uuid_generate_v4()::text,'успех' FROM payment LIMIT 1$q$, '23505');
SELECT pg_temp.reject($q$DELETE FROM order_structure$q$, '23514');
SELECT pg_temp.reject($q$UPDATE review_with_client SET client_id=exts.uuid_generate_v4()$q$, '23503');
SELECT pg_temp.reject($q$UPDATE review SET entity_id=exts.uuid_generate_v4()$q$, '23514');
SELECT pg_temp.reject($q$UPDATE product SET restaurant_id=(SELECT restaurant_id FROM restaurant WHERE restaurant_id<>product.restaurant_id LIMIT 1)$q$, '23514');
SELECT pg_temp.reject($q$UPDATE review_with_client SET client_id=(SELECT client_id FROM client WHERE client_id<>review_with_client.client_id LIMIT 1)$q$, '23514');
SELECT pg_temp.reject($q$UPDATE "order" SET address_id=(SELECT ca.address_id FROM client_address ca WHERE ca.client_id<>"order".client_id LIMIT 1)$q$, '23503');
SELECT pg_temp.reject($q$UPDATE review SET rating=0$q$, '23514');
SELECT pg_temp.reject($q$UPDATE order_structure SET quantity=0$q$, '23514');
SELECT pg_temp.reject($q$UPDATE product SET price='NaN'$q$, '23514');
SELECT pg_temp.reject($q$UPDATE "order" SET status='доставлен',delivery_timestamp=NULL$q$, '23514');
SELECT pg_temp.reject($q$INSERT INTO client_address SELECT * FROM client_address LIMIT 1$q$, '23505');
SELECT pg_temp.reject($q$INSERT INTO review_with_client(client_id,entity_id,entity_type,order_id,description,rating)
    SELECT client_id,entity_id,entity_type,order_id,description,rating FROM review_with_client LIMIT 1$q$, '23505');
DO $$
DECLARE i int;
BEGIN
    FOR i IN 1..10 LOOP CALL insert_test_data(10); END LOOP;
    PERFORM pg_temp.assert((SELECT count(*)=110 FROM client) AND (SELECT count(*)=550 FROM "order")
        AND (SELECT count(*)=660 FROM courier_pay), '10 повторных генераций без очистки');
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
CALL erase_test_data();
CALL erase_test_data();
DO $$
DECLARE t text; n bigint;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='sergeev_food' LOOP
        EXECUTE format('SELECT count(*) FROM %I',t) INTO n;
        PERFORM pg_temp.assert(n=0, 'очистка ' || t);
    END LOOP;
END $$;
CALL insert_test_data(1);
DO $$
DECLARE r uuid; cat uuid; n bigint;
BEGIN
    SELECT restaurant_id INTO r FROM restaurant LIMIT 1;
    SELECT product_category_id INTO cat FROM product_category LIMIT 1;
    SELECT count(*) INTO n FROM product;
    CALL add_product(r,cat,'Суп',250,4.5,'доступно','Овощной суп');
    PERFORM pg_temp.assert((SELECT count(*)=n+1 FROM product), 'add_product');
    PERFORM pg_temp.reject(format('CALL add_product(%L,%L,''Суп'',250,4,''доступно'',''Суп'')',exts.uuid_generate_v4(),cat),'23503');
    PERFORM pg_temp.reject(format('CALL add_product(%L,%L,''Суп'',250,4,''доступно'',''Суп'')',r,exts.uuid_generate_v4()),'23503');
    PERFORM pg_temp.reject(format('CALL add_product(%L,%L,''Суп'',-1,4,''доступно'',''Суп'')',r,cat),'23514');
END $$;
DELETE FROM review;
DO $$
DECLARE base "order"; pid uuid; other_pid uuid; oid uuid; i int; rid uuid; ids uuid[] := '{}';
BEGIN
    SELECT * INTO base FROM "order" LIMIT 1;
    SELECT product_id INTO pid FROM product WHERE restaurant_id=base.restaurant_id LIMIT 1;
    SELECT product_id INTO other_pid FROM product WHERE product_id<>pid LIMIT 1;
    FOR i IN 1..3 LOOP
        INSERT INTO "order"(courier_id,client_id,address_id,restaurant_id,order_amount,description)
        VALUES(base.courier_id,base.client_id,base.address_id,base.restaurant_id,1000,'Проверка рейтингов') RETURNING order_id INTO oid;
        INSERT INTO order_structure VALUES(oid,pid,1,1000),(oid,other_pid,1,0);
        INSERT INTO review_with_client(client_id,entity_id,entity_type,order_id,description,rating)
        VALUES(base.client_id,pid,'блюдо',oid,'Оценка',i+2) RETURNING review_id INTO rid;
        ids := array_append(ids,rid);
    END LOOP;
    PERFORM pg_temp.assert((SELECT rating=4 FROM product WHERE product_id=pid), 'рейтинг 3,4,5 -> 4');
    DELETE FROM review WHERE review_id=ids[1];
    PERFORM pg_temp.assert((SELECT rating=4.5 FROM product WHERE product_id=pid), 'удаление 3 -> 4.5');
    UPDATE review SET entity_id=other_pid WHERE review_id=ids[2];
    PERFORM pg_temp.assert((SELECT rating=5 FROM product WHERE product_id=pid)
        AND (SELECT rating=4 FROM product WHERE product_id=other_pid), 'перенос отзыва между блюдами');
    UPDATE review SET entity_type='ресторан',entity_id=base.restaurant_id,rating=3 WHERE review_id=ids[2];
    PERFORM pg_temp.assert((SELECT rating IS NULL FROM product WHERE product_id=other_pid)
        AND (SELECT rating=3 FROM restaurant WHERE restaurant_id=base.restaurant_id), 'смена типа отзыва');
    UPDATE review SET rating=2 WHERE review_id=ids[3];
    PERFORM pg_temp.assert((SELECT rating=2 FROM product WHERE product_id=pid), 'изменение оценки');
    UPDATE review_with_client SET rating=4 WHERE review_id=ids[3];
    PERFORM pg_temp.assert((SELECT rating=4 FROM product WHERE product_id=pid), 'UPDATE через review_with_client');
    DELETE FROM review_with_client WHERE review_id=ids[3];
    PERFORM pg_temp.assert((SELECT rating IS NULL FROM product WHERE product_id=pid), 'DELETE через review_with_client');
    DELETE FROM review;
    PERFORM pg_temp.assert((SELECT rating IS NULL FROM product WHERE product_id=pid)
        AND (SELECT rating IS NULL FROM restaurant WHERE restaurant_id=base.restaurant_id), 'нет отзывов -> NULL');
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
DO $$
DECLARE p payment; oid uuid;
BEGIN
    SELECT * INTO p FROM payment LIMIT 1;
    oid:=p.order_id;
    UPDATE payment SET status='ошибка' WHERE payment_id=p.payment_id;
    PERFORM pg_temp.assert((SELECT pay_status='ошибка' FROM "order" WHERE order_id=oid), 'ошибка оплаты');
    INSERT INTO payment(order_id,type,amount,transaction_ref,status) VALUES(oid,'наличные',p.amount,'processing','в_обработке');
    PERFORM pg_temp.assert((SELECT pay_status='ожидает' FROM "order" WHERE order_id=oid), 'оплата в обработке');
    UPDATE payment SET status='успех' WHERE transaction_ref='processing';
    PERFORM pg_temp.assert((SELECT pay_status='оплачен' FROM "order" WHERE order_id=oid), 'успех после ошибки');
    DELETE FROM payment WHERE order_id=oid;
    PERFORM pg_temp.assert((SELECT pay_status='ожидает' FROM "order" WHERE order_id=oid), 'нет попыток -> ожидает');
END $$;
CALL erase_test_data();
CALL insert_test_data(1);
DELETE FROM review;
DELETE FROM payment;
DELETE FROM order_structure;
DELETE FROM "order";
DELETE FROM courier_pay;
-- Фиксированные суммы позволяют проверить отчёты без зависимости от random().
DO $$
DECLARE base record; pid uuid; second_pid uuid; oid uuid; m timestamp; i int;
BEGIN
    SELECT c.courier_id,ca.client_id,ca.address_id,r.restaurant_id INTO base
    FROM courier c CROSS JOIN client_address ca CROSS JOIN restaurant r LIMIT 1;
    SELECT product_id INTO pid FROM product LIMIT 1;
    SELECT product_id INTO second_pid FROM product WHERE product_id<>pid LIMIT 1;
    FOR i IN 0..2 LOOP
        m:=date_trunc('month',localtimestamp)-(2-i)*interval '1 month';
        INSERT INTO "order"(courier_id,client_id,address_id,restaurant_id,order_timestamp,delivery_timestamp,order_amount,status,description)
        VALUES(base.courier_id,base.client_id,base.address_id,base.restaurant_id,m,m+interval '1 minute',1000,
            CASE WHEN i=1 THEN 'отменён'::order_status ELSE 'доставлен'::order_status END,'Отчёт') RETURNING order_id INTO oid;
        INSERT INTO order_structure VALUES(oid,CASE WHEN i=2 THEN second_pid ELSE pid END,
            CASE WHEN i=2 THEN 10 ELSE 1 END, CASE WHEN i=2 THEN 100 ELSE 1000 END);
    END LOOP;
    INSERT INTO courier_pay VALUES(extract(year FROM m),extract(month FROM m),base.courier_id,10,.1);
    PERFORM pg_temp.assert((SELECT count(*)=3 FROM how_much_money), 'непрерывный ряд месяцев');
    PERFORM pg_temp.assert((SELECT sum_no_commission=0 AND commission=0 AND net_profit=0
        FROM how_much_money WHERE year_month=to_char(m-interval '1 month','YYYY-MM')), 'пропущенный месяц с нулями');
    PERFORM pg_temp.assert((SELECT prev_commission IS NULL AND commission_diff IS NULL
        FROM how_much_money ORDER BY year_month LIMIT 1), 'первый месяц без предыдущего');
    PERFORM pg_temp.assert((SELECT sum_no_commission=1000 AND sum_with_commission=1100 AND commission=100
        AND prev_commission=0 AND commission_diff=100 AND courier_pay=10 AND net_profit=90
        FROM how_much_money WHERE year_month=to_char(m,'YYYY-MM')), 'точные суммы финансового отчёта');
    PERFORM pg_temp.assert((SELECT best_product_name=(SELECT product_name FROM product WHERE product_id=second_pid)
        FROM get_statistic()), 'лучшее блюдо по сумме количества');
    PERFORM pg_temp.assert((SELECT total_amount=2200 AND avg_amount=1100 AND best_product_name IS NOT NULL
        AND best_user IS NOT NULL FROM get_statistic()), 'статистика не умножает суммы при JOIN');
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
CALL erase_test_data();
CALL insert_test_data(1);
DELETE FROM review;
DELETE FROM payment;
DELETE FROM order_structure;
DELETE FROM "order";
DELETE FROM courier_pay;
DO $$
DECLARE base record; pid uuid; cid uuid; oid uuid; n int; j int; used numeric; expected numeric; old_status courier_status;
BEGIN
    SELECT ca.client_id,ca.address_id,r.restaurant_id INTO base
        FROM client_address ca CROSS JOIN restaurant r LIMIT 1;
    SELECT product_id INTO pid FROM product LIMIT 1;
    FOREACH n IN ARRAY ARRAY[0,150,151,250,251,500,501] LOOP
        INSERT INTO courier(fio,phone_number,hire_date,coefficient) VALUES('Проверка границы '||n,'79000000000',current_date,.4)
            RETURNING courier_id INTO cid;
        FOR j IN 1..n LOOP
            INSERT INTO "order"(courier_id,client_id,address_id,restaurant_id,order_amount,status,delivery_timestamp,description)
            VALUES(cid,base.client_id,base.address_id,base.restaurant_id,1000,'доставлен',localtimestamp,'Зарплата') RETURNING order_id INTO oid;
            INSERT INTO order_structure VALUES(oid,pid,1,1000);
        END LOOP;
        FOR j IN 1..2 LOOP
            INSERT INTO "order"(courier_id,client_id,address_id,restaurant_id,order_timestamp,order_amount,status,delivery_timestamp,description)
            VALUES(cid,base.client_id,base.address_id,base.restaurant_id,
                CASE WHEN j=1 THEN localtimestamp ELSE date_trunc('month',localtimestamp)-interval '1 day' END,
                1000,CASE WHEN j=1 THEN 'отменён'::order_status ELSE 'доставлен'::order_status END,
                CASE WHEN j=2 THEN date_trunc('month',localtimestamp)-interval '1 day'+interval '10 minutes' END,
                'Не входит в текущую зарплату') RETURNING order_id INTO oid;
            INSERT INTO order_structure VALUES(oid,pid,1,1000);
        END LOOP;
        CALL courier_salary();
        expected:=CASE WHEN n<=150 THEN .1 WHEN n<=250 THEN .2 WHEN n<=500 THEN .3 ELSE .5 END;
        PERFORM pg_temp.assert((SELECT coefficient=expected FROM courier WHERE courier_id=cid), 'порог зарплаты '||n);
        PERFORM pg_temp.assert((SELECT amount=n*40 AND coefficient_used=.4 FROM courier_pay WHERE courier_id=cid), 'зарплата по старому коэффициенту '||n);
        CALL courier_salary();
        PERFORM pg_temp.assert((SELECT count(*)=1 AND min(amount)=n*40 AND min(coefficient_used)=.4
            FROM courier_pay WHERE courier_id=cid), 'повторная зарплата '||n);
        UPDATE courier SET status='уволен',dismissal_date=current_date,coefficient=.4 WHERE courier_id=cid;
        CALL courier_salary();
        PERFORM pg_temp.assert((SELECT coefficient=.4 FROM courier WHERE courier_id=cid), 'коэффициент уволенного не меняется');
    END LOOP;
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
CALL erase_test_data();
CALL insert_test_data(10);
SET CONSTRAINTS ALL IMMEDIATE;
DO $$
DECLARE p payment;
BEGIN
    SELECT * INTO p FROM payment LIMIT 1;
    UPDATE payment SET status='ошибка' WHERE payment_id=p.payment_id;
    PERFORM pg_temp.assert((SELECT pay_status='ошибка' FROM "order" WHERE order_id=p.order_id),
        'изменение оплаты при IMMEDIATE');
    UPDATE payment SET status='успех' WHERE payment_id=p.payment_id;
    PERFORM pg_temp.assert((SELECT pay_status='оплачен' FROM "order" WHERE order_id=p.order_id),
        'успешная оплата при IMMEDIATE');
END $$;
CALL erase_test_data();
CALL erase_test_data();
SELECT pg_temp.assert((SELECT count(*)=0 FROM "order") AND (SELECT count(*)=0 FROM client),
    'очистка при IMMEDIATE');
SET CONSTRAINTS ALL DEFERRED;
CALL insert_test_data(10);
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert((SELECT count(*)=50 FROM "order"), 'повторная генерация после очистки');
ROLLBACK;
\echo Все проверки завершены; изменения тестов отменены.
