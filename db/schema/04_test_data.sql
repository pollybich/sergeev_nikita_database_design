SET search_path = sergeev_food, exts, pg_catalog;
CREATE PROCEDURE insert_test_data(value int) LANGUAGE plpgsql
SET search_path = sergeev_food, exts, pg_catalog AS $$
DECLARE
    clients uuid[] := '{}'; couriers uuid[] := '{}'; restaurants uuid[] := '{}';
    categories uuid[] := '{}'; addresses uuid[] := '{}'; products uuid[] := '{}';
    v_id uuid; v_address uuid; v_product uuid; v_order uuid;
    i int; j int; k int; v_phone varchar; v_status order_status;
    start_month date := (date_trunc('month', current_date) - interval '5 months')::date;
    m date; ts timestamp; v_price numeric; v_quantity numeric; used numeric;
    v_count bigint; v_commission numeric; v_entity entity_type;
BEGIN
    IF value IS NULL OR value <= 0 THEN
        RAISE EXCEPTION 'value должен быть положительным целым числом' USING ERRCODE = '22023';
    END IF;
    FOR i IN 1..value LOOP
        v_id := exts.uuid_generate_v4(); clients := array_append(clients, v_id);
        LOOP
            v_phone := '79' || lpad(floor(random()*1000000000)::bigint::text, 9, '0');
            EXIT WHEN NOT EXISTS (SELECT FROM client WHERE phone_number = v_phone);
        END LOOP;
        INSERT INTO client VALUES(v_id, 'client_' || replace(v_id::text, '-', ''), md5(random()::text), v_phone);
        v_id := exts.uuid_generate_v4(); couriers := array_append(couriers, v_id);
        INSERT INTO courier(courier_id, fio, phone_number, status, hire_date, dismissal_date)
        VALUES(v_id, 'Соколов Иван ' || i, v_phone,
            (enum_range(NULL::courier_status))[CASE WHEN i = 1 THEN 1 ELSE 1 + (i-1)%4 END],
            start_month, CASE WHEN i > 1 AND (i-1)%4 = 3 THEN current_date END);
        v_id := exts.uuid_generate_v4(); categories := array_append(categories, v_id);
        INSERT INTO product_category VALUES(v_id, 'Категория ' || i);
        INSERT INTO address(street, house_number) VALUES('Ресторанная ' || clients[i], i::text) RETURNING address_id INTO v_address;
        v_id := exts.uuid_generate_v4(); restaurants := array_append(restaurants, v_id);
        INSERT INTO restaurant(restaurant_id, restaurant_name, address_id, description, work_start, work_end, company_details, status)
        VALUES(v_id, 'Ресторан ' || i, v_address, 'Кухня и доставка', '08:00', '23:00', 'Реквизиты ' || i,
            (enum_range(NULL::restaurant_status))[1 + (i-1)%2]);
        FOR j IN 1..4 LOOP
            INSERT INTO address(street, house_number, apartment_office)
            VALUES('Клиентская ' || clients[i], j::text, CASE WHEN j%2 = 0 THEN j::text END)
            RETURNING address_id INTO v_address;
            addresses := array_append(addresses, v_address);
            INSERT INTO client_address VALUES(clients[i], v_address);
        END LOOP;
        FOR j IN 1..5 LOOP
            v_id := exts.uuid_generate_v4(); products := array_append(products, v_id);
            INSERT INTO product(product_id, product_name, product_category_id, price, restaurant_id, photo_url, status, description)
            VALUES(v_id, 'Блюдо ' || i || '-' || j, categories[i], 500 + floor(random()*1000), restaurants[i],
                CASE WHEN j%2 = 0 THEN 'https://example.org/product/' || v_id || '.jpg' END,
                (enum_range(NULL::product_status))[1+(j-1)%3], 'Порция блюда');
        END LOOP;
    END LOOP;
    FOR i IN 1..value LOOP
        FOR j IN 1..5 LOOP
            k := (i-1)*5 + j;
            v_product := products[k];
            SELECT price INTO v_price FROM product WHERE product_id = v_product;
            v_quantity := 2.5;
            m := (start_month + ((k-1)%6)*interval '1 month')::date;
            ts := m::timestamp + random()*(least(m::timestamp+interval '1 month',localtimestamp)-m::timestamp);
            v_status := (enum_range(NULL::order_status))[CASE WHEN j = 1 THEN 4 ELSE 1+(i+j-2)%5 END];
            INSERT INTO "order"(courier_id, client_id, address_id, restaurant_id, order_timestamp,
                delivery_timestamp, order_amount, status, description)
            VALUES(couriers[i], clients[i], addresses[(i-1)*4+1+(j-1)%4], restaurants[i], ts,
                CASE WHEN v_status = 'доставлен' THEN least(ts+interval '40 minutes', localtimestamp) END,
                round(v_price*v_quantity,2), v_status, 'Доставка заказа') RETURNING order_id INTO v_order;
            INSERT INTO order_structure VALUES(v_order, v_product, v_quantity, v_price);
            INSERT INTO payment(order_id, type, amount, transaction_ref, transaction_timestamp, status)
            VALUES(v_order, (enum_range(NULL::payment_type))[1+(k-1)%3],
                round(v_price*v_quantity,2)+round(v_price*v_quantity*0.1,2),
                'tx_' || exts.uuid_generate_v4(), least(ts+interval '1 minute',localtimestamp),
                (enum_range(NULL::payment_status))[1]);
            v_entity := (enum_range(NULL::entity_type))[1+(k-1)%3];
            INSERT INTO review(client_id, review_timestamp, entity_id, entity_type, order_id, description, photo_url, rating)
            VALUES(clients[i], localtimestamp, CASE v_entity WHEN 'блюдо' THEN v_product
                WHEN 'ресторан' THEN restaurants[i] ELSE v_order END, v_entity, v_order,
                'Отзыв о заказе', CASE WHEN k%2 = 0 THEN 'https://example.org/review/' || v_order || '.jpg' END,
                1+floor(random()*5));
        END LOOP;
    END LOOP;
    FOR i IN 1..value LOOP
        used := 0.1;
        FOR j IN 0..5 LOOP
            m := (start_month + j*interval '1 month')::date;
            SELECT count(*), coalesce(sum(commission),0) INTO v_count,v_commission
            FROM "order" WHERE courier_id = couriers[i] AND status = 'доставлен'
                AND order_timestamp >= m AND order_timestamp < m+interval '1 month';
            INSERT INTO courier_pay VALUES(extract(year FROM m), extract(month FROM m), couriers[i], round(used*v_commission,2), used);
            IF NOT EXISTS (SELECT FROM courier WHERE courier_id = couriers[i] AND status = 'уволен') THEN
                used := CASE WHEN v_count <= 150 THEN 0.1 WHEN v_count <= 250 THEN 0.2
                    WHEN v_count <= 500 THEN 0.3 ELSE 0.5 END;
            END IF;
        END LOOP;
        UPDATE courier SET coefficient = used WHERE courier_id = couriers[i];
    END LOOP;
END $$;

CREATE PROCEDURE erase_test_data() LANGUAGE plpgsql
SET search_path = sergeev_food, exts, pg_catalog AS $$
BEGIN
    DELETE FROM review;
    DELETE FROM payment;
    DELETE FROM order_structure;
    DELETE FROM "order";
    DELETE FROM courier_pay;
    DELETE FROM product;
    DELETE FROM product_category;
    DELETE FROM restaurant;
    DELETE FROM client_address;
    DELETE FROM client;
    DELETE FROM courier;
    DELETE FROM address;
END $$;
