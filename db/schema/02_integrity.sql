SET search_path = sergeev_food, exts, pg_catalog;

-- Проверки состава заказа откладываются до конца транзакции: сначала создаётся
-- заказ, затем его позиции и попытки оплаты.
CREATE FUNCTION check_order(p_id uuid) RETURNS void LANGUAGE plpgsql
SET search_path = sergeev_food, exts, pg_catalog AS $$
DECLARE o "order"; expected order_pay_status;
BEGIN
    SELECT * INTO o FROM "order" WHERE order_id = p_id FOR UPDATE;
    IF NOT FOUND THEN RETURN; END IF;
    IF NOT EXISTS (SELECT FROM order_structure WHERE order_id = p_id) THEN
        RAISE EXCEPTION 'Заказ % должен содержать хотя бы одну позицию', p_id USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT FROM order_structure s JOIN product p USING(product_id)
               WHERE s.order_id = p_id AND p.restaurant_id <> o.restaurant_id) THEN
        RAISE EXCEPTION 'Блюда заказа должны принадлежать ресторану заказа' USING ERRCODE = '23514';
    END IF;
    IF o.order_amount <> (SELECT round(sum(quantity * unit_price), 2) FROM order_structure WHERE order_id = p_id) THEN
        RAISE EXCEPTION 'Сумма заказа не совпадает со стоимостью позиций' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT FROM payment WHERE order_id = p_id AND amount <> o.total_amount) THEN
        RAISE EXCEPTION 'Сумма оплаты должна равняться общей сумме заказа' USING ERRCODE = '23514';
    END IF;
    SELECT CASE WHEN count(*) FILTER (WHERE status = 'успех') > 0 THEN 'оплачен'
                WHEN count(*) > 0 AND bool_and(status = 'ошибка') THEN 'ошибка'
                ELSE 'ожидает' END::order_pay_status
    INTO expected FROM payment WHERE order_id = p_id;
    IF o.pay_status <> expected THEN
        RAISE EXCEPTION 'Статус оплаты не соответствует попыткам оплаты' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT FROM review r WHERE r.order_id = p_id AND (
            (r.entity_type = 'заказ' AND r.entity_id <> p_id) OR
            (r.entity_type = 'ресторан' AND r.entity_id <> o.restaurant_id) OR
            (r.entity_type = 'блюдо' AND NOT EXISTS (
                SELECT FROM order_structure s WHERE s.order_id = p_id AND s.product_id = r.entity_id)))) THEN
        RAISE EXCEPTION 'Можно оставить отзыв только на свой заказ и его ресторан или блюда' USING ERRCODE = '23514';
    END IF;
END $$;

CREATE FUNCTION order_integrity() RETURNS trigger LANGUAGE plpgsql
SET search_path = sergeev_food, exts, pg_catalog AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN PERFORM check_order(OLD.order_id); END IF;
    IF TG_OP <> 'DELETE' THEN PERFORM check_order(NEW.order_id); END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER order_integrity AFTER INSERT OR UPDATE ON "order"
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_integrity();
CREATE CONSTRAINT TRIGGER structure_integrity AFTER INSERT OR UPDATE OR DELETE ON order_structure
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_integrity();
CREATE CONSTRAINT TRIGGER z_payment_integrity AFTER INSERT OR UPDATE OR DELETE ON payment
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_integrity();
CREATE CONSTRAINT TRIGGER review_integrity AFTER INSERT OR UPDATE OR DELETE ON review
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION order_integrity();

CREATE FUNCTION product_restaurant_check() RETURNS trigger LANGUAGE plpgsql
SET search_path = sergeev_food, exts, pg_catalog AS $$
BEGIN
    IF EXISTS (SELECT FROM order_structure s JOIN "order" o USING(order_id)
               WHERE s.product_id = NEW.product_id AND o.restaurant_id <> NEW.restaurant_id) THEN
        RAISE EXCEPTION 'Нельзя перенести заказанное блюдо в другой ресторан' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER product_restaurant_check BEFORE UPDATE OF restaurant_id ON product
    FOR EACH ROW EXECUTE FUNCTION product_restaurant_check();

CREATE FUNCTION payment_status_change() RETURNS trigger LANGUAGE plpgsql
SET search_path = sergeev_food, exts, pg_catalog AS $$
DECLARE v_id uuid;
BEGIN
    FOR v_id IN SELECT DISTINCT id FROM unnest(ARRAY[
        CASE WHEN TG_OP <> 'INSERT' THEN OLD.order_id END,
        CASE WHEN TG_OP <> 'DELETE' THEN NEW.order_id END]) AS t(id)
        WHERE id IS NOT NULL ORDER BY id
    LOOP
        PERFORM 1 FROM "order" WHERE order_id = v_id FOR UPDATE;
        UPDATE "order" SET pay_status = (
            SELECT CASE WHEN count(*) FILTER (WHERE status = 'успех') > 0 THEN 'оплачен'
                WHEN count(*) > 0 AND bool_and(status = 'ошибка') THEN 'ошибка'
                ELSE 'ожидает' END::order_pay_status FROM payment WHERE order_id = v_id)
        WHERE order_id = v_id;
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER payment_status_change AFTER INSERT OR UPDATE OR DELETE ON payment
    FOR EACH ROW EXECUTE FUNCTION payment_status_change();

CREATE FUNCTION rating_change() RETURNS trigger LANGUAGE plpgsql
SET search_path = sergeev_food, exts, pg_catalog AS $$
DECLARE obj record;
BEGIN
    FOR obj IN
        SELECT DISTINCT t, id FROM (VALUES
            (CASE WHEN TG_OP <> 'INSERT' THEN OLD.entity_type END, CASE WHEN TG_OP <> 'INSERT' THEN OLD.entity_id END),
            (CASE WHEN TG_OP <> 'DELETE' THEN NEW.entity_type END, CASE WHEN TG_OP <> 'DELETE' THEN NEW.entity_id END)
        ) AS affected(t,id) WHERE t IN ('блюдо', 'ресторан') ORDER BY t, id
    LOOP
        IF obj.t = 'блюдо' THEN
            PERFORM 1 FROM product WHERE product_id = obj.id FOR UPDATE;
            UPDATE product SET rating = (SELECT round(avg(rating), 2) FROM review
                WHERE entity_type = 'блюдо' AND entity_id = obj.id) WHERE product_id = obj.id;
        ELSE
            PERFORM 1 FROM restaurant WHERE restaurant_id = obj.id FOR UPDATE;
            UPDATE restaurant SET rating = (SELECT round(avg(rating), 2) FROM review
                WHERE entity_type = 'ресторан' AND entity_id = obj.id) WHERE restaurant_id = obj.id;
        END IF;
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER rating_change AFTER INSERT OR UPDATE OR DELETE ON review
    FOR EACH ROW EXECUTE FUNCTION rating_change();

-- Изменение дочерних строк сериализуется с изменением самого заказа.
CREATE FUNCTION lock_order_children() RETURNS trigger LANGUAGE plpgsql
SET search_path = sergeev_food, exts, pg_catalog AS $$
DECLARE v_id uuid;
BEGIN
    FOR v_id IN SELECT DISTINCT id FROM unnest(ARRAY[
        CASE WHEN TG_OP <> 'INSERT' THEN OLD.order_id END,
        CASE WHEN TG_OP <> 'DELETE' THEN NEW.order_id END]) AS t(id)
        WHERE id IS NOT NULL ORDER BY id
    LOOP
        PERFORM 1 FROM "order" WHERE order_id=v_id FOR UPDATE;
    END LOOP;
    IF TG_TABLE_NAME='order_structure' AND TG_OP <> 'DELETE' THEN
        PERFORM 1 FROM product WHERE product_id=NEW.product_id FOR SHARE;
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER structure_lock BEFORE INSERT OR UPDATE OR DELETE ON order_structure
    FOR EACH ROW EXECUTE FUNCTION lock_order_children();
CREATE TRIGGER payment_lock BEFORE INSERT OR UPDATE OR DELETE ON payment
    FOR EACH ROW EXECUTE FUNCTION lock_order_children();
CREATE TRIGGER review_lock BEFORE INSERT OR UPDATE OR DELETE ON review
    FOR EACH ROW EXECUTE FUNCTION lock_order_children();

-- Автор отзыва выводится из заказа; в таблице review нет зависимости
-- review_id -> order_id -> client_id. Представление проверяет явного автора.
CREATE FUNCTION write_review_with_client() RETURNS trigger LANGUAGE plpgsql
SET search_path = sergeev_food, exts, pg_catalog AS $$
DECLARE owner_id uuid;
BEGIN
    IF TG_OP='DELETE' THEN
        DELETE FROM review WHERE review_id=OLD.review_id;
        RETURN OLD;
    END IF;
    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION 'Укажите автора отзыва' USING ERRCODE='23502';
    END IF;
    IF NOT EXISTS(SELECT FROM client WHERE client_id=NEW.client_id) THEN
        RAISE EXCEPTION 'Клиент не существует' USING ERRCODE='23503';
    END IF;
    SELECT client_id INTO owner_id FROM "order" WHERE order_id=NEW.order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Заказ не существует' USING ERRCODE='23503';
    END IF;
    IF NEW.client_id<>owner_id THEN
        RAISE EXCEPTION 'Можно оставить отзыв только на свой заказ' USING ERRCODE='23514';
    END IF;
    IF TG_OP='INSERT' THEN
        INSERT INTO review(review_id,review_timestamp,entity_id,entity_type,order_id,description,photo_url,rating)
        VALUES(coalesce(NEW.review_id,exts.uuid_generate_v4()),coalesce(NEW.review_timestamp,localtimestamp),
            NEW.entity_id,NEW.entity_type,NEW.order_id,NEW.description,NEW.photo_url,NEW.rating)
        RETURNING review_id,review_timestamp INTO NEW.review_id,NEW.review_timestamp;
    ELSE
        UPDATE review SET review_id=NEW.review_id,review_timestamp=NEW.review_timestamp,
            entity_id=NEW.entity_id,entity_type=NEW.entity_type,order_id=NEW.order_id,
            description=NEW.description,photo_url=NEW.photo_url,rating=NEW.rating
        WHERE review_id=OLD.review_id;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER write_review_with_client INSTEAD OF INSERT OR UPDATE OR DELETE ON review_with_client
    FOR EACH ROW EXECUTE FUNCTION write_review_with_client();
