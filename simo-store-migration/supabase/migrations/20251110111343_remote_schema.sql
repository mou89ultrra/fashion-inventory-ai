


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."grade_t" AS ENUM (
    'A',
    'B',
    'C',
    'D',
    'E',
    'F'
);


ALTER TYPE "public"."grade_t" OWNER TO "postgres";


CREATE TYPE "public"."movement_type_t" AS ENUM (
    'stock_in',
    'list',
    'reserve',
    'unreserve',
    'sell',
    'deliver',
    'return',
    'write_off',
    'adjustment'
);


ALTER TYPE "public"."movement_type_t" OWNER TO "postgres";


CREATE TYPE "public"."ocr_status_t" AS ENUM (
    'success',
    'retryable_error',
    'hard_error'
);


ALTER TYPE "public"."ocr_status_t" OWNER TO "postgres";


CREATE TYPE "public"."order_status_t" AS ENUM (
    'pending',
    'confirmed',
    'paid',
    'shipped',
    'delivered',
    'canceled',
    'refunded',
    'returned'
);


ALTER TYPE "public"."order_status_t" OWNER TO "postgres";


CREATE TYPE "public"."payment_method_t" AS ENUM (
    'cash',
    'bank_transfer',
    'card',
    'wallet'
);


ALTER TYPE "public"."payment_method_t" OWNER TO "postgres";


CREATE TYPE "public"."piece_status_t" AS ENUM (
    'in_stock',
    'listed_pending_review',
    'listed_approved',
    'posted',
    'reserved',
    'ready_to_deliver',
    'sold',
    'returned',
    'ocr_failed'
);


ALTER TYPE "public"."piece_status_t" OWNER TO "postgres";


CREATE TYPE "public"."return_reason_t" AS ENUM (
    'size_issue',
    'defect',
    'changed_mind',
    'logistics',
    'other'
);


ALTER TYPE "public"."return_reason_t" OWNER TO "postgres";


CREATE TYPE "public"."sales_channel_t" AS ENUM (
    'facebook',
    'messenger',
    'offline',
    'instagram',
    'other'
);


ALTER TYPE "public"."sales_channel_t" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."album_buffer_add"("p_chat_id" "text", "p_media_group_id" "text", "p_photo" "jsonb", "p_expected" integer DEFAULT 10, "p_debounce_seconds" integer DEFAULT 8) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_row record;
  v_now timestamptz := now();
  v_is_ready boolean := false;
  v_photos jsonb;
begin
  -- أضف أو حدث السطر في الجدول
  insert into public.album_buffer(chat_id, media_group_id, photos, count, last_ts)
  values (p_chat_id, p_media_group_id, jsonb_build_array(p_photo), 1, v_now)
  on conflict (chat_id, media_group_id)
  do update set
    photos = album_buffer.photos || jsonb_build_array(p_photo),
    count  = album_buffer.count + 1,
    last_ts = v_now
  returning * into v_row;

  -- 📸 الشرط الجديد: لو عدد الصور <= الحد الأقصى
  if v_row.count <= p_expected then
    v_is_ready := true;
  end if;

  -- ⏳ أو لو انتهت المهلة الزمنية (debounce)
  if extract(epoch from (v_now - v_row.last_ts)) >= p_debounce_seconds then
    v_is_ready := true;
  end if;

  -- ✅ في حالة الجاهزية احذف الصف وارجع الصور
  if v_is_ready then
    v_photos := v_row.photos;
    delete from public.album_buffer
     where chat_id = p_chat_id
       and media_group_id = p_media_group_id;

    return jsonb_build_object(
      'is_ready', true,
      'photos', v_photos,
      'count', jsonb_array_length(v_photos)
    );
  end if;

  -- ⏱️ وإلا ما زال الألبوم قيد التجميع
  return jsonb_build_object(
    'is_ready', false,
    'count', v_row.count
  );
end;
$$;


ALTER FUNCTION "public"."album_buffer_add"("p_chat_id" "text", "p_media_group_id" "text", "p_photo" "jsonb", "p_expected" integer, "p_debounce_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."categories_propagate_name_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.name IS DISTINCT FROM OLD.name THEN
    UPDATE public.pieces
    SET category_name = NEW.name
    WHERE prefix = NEW.prefix;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."categories_propagate_name_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_and_reserve_codes"("p_prefix" "text", "p_grade" "public"."grade_t", "p_count" integer, "p_pad" integer DEFAULT 4, "p_request_id" "text" DEFAULT NULL::"text") RETURNS TABLE("code" "text", "reserved" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_curr_serial   integer;
  v_start_serial  integer;
  v_end_serial    integer;
  s               integer;
  new_code        text;
  inserted        integer;
  ins_rows        integer;
  req_exists      boolean;
BEGIN
  -- safety for SECURITY DEFINER
  PERFORM set_config('search_path', 'public, pg_temp', true);

  IF p_count < 1 OR p_count > 2000 THEN
    RAISE EXCEPTION 'Invalid count (1..2000)';
  END IF;

  -- lock by prefix (avoid race)
  PERFORM pg_advisory_xact_lock(hashtext(p_prefix));

  -- Idempotency: if request already exists, return same stored codes
  IF p_request_id IS NOT NULL THEN
    INSERT INTO public.request_dedup(request_id, prefix, grade, pad)
    VALUES (p_request_id, p_prefix, p_grade, COALESCE(p_pad, 4))
    ON CONFLICT (request_id) DO NOTHING;

    GET DIAGNOSTICS ins_rows = ROW_COUNT;
    req_exists := (ins_rows = 0);

    IF req_exists THEN
      RETURN QUERY
      SELECT cr.piece_code AS code, TRUE AS reserved
      FROM public.codes_registry cr
      WHERE cr.request_id = p_request_id
      ORDER BY cr.minted_at;
      RETURN;
    END IF;
  END IF;

  -- load/create counter
  <<get_or_create_counter>>
  LOOP
    SELECT last_serial
      INTO v_curr_serial
      FROM public.code_counters
     WHERE prefix = p_prefix
     FOR UPDATE;

    IF FOUND THEN
      EXIT get_or_create_counter;
    END IF;

    BEGIN
      INSERT INTO public.code_counters(prefix, last_serial, updated_at)
      VALUES (p_prefix, 0, now());
    EXCEPTION WHEN unique_violation THEN
      -- another session inserted it
    END;
  END LOOP;

  -- allocate range
  v_start_serial := v_curr_serial + 1;
  v_end_serial   := v_curr_serial + p_count;

  UPDATE public.code_counters
     SET last_serial = v_end_serial,
         updated_at  = now()
   WHERE prefix = p_prefix;

  -- persist request range (if any)
  IF p_request_id IS NOT NULL THEN
    UPDATE public.request_dedup AS rd
       SET start_serial = v_start_serial,
           end_serial   = v_end_serial,
           pad          = COALESCE(p_pad, 4)
     WHERE rd.request_id = p_request_id;
  END IF;

  -- insert & return
  FOR s IN v_start_serial..v_end_serial LOOP
    new_code := p_prefix || '-' || lpad(s::text, p_pad, '0');

    INSERT INTO public.codes_registry("piece_code", prefix, grade, minted_at, request_id)
    VALUES (new_code, p_prefix, p_grade, now(), p_request_id)
    ON CONFLICT ("piece_code") DO NOTHING;

    GET DIAGNOSTICS inserted = ROW_COUNT;

    code     := new_code;
    reserved := (inserted = 1);
    RETURN NEXT;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."generate_and_reserve_codes"("p_prefix" "text", "p_grade" "public"."grade_t", "p_count" integer, "p_pad" integer, "p_request_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_batch_codes"("p_prefix" "text", "p_grade" "public"."grade_t", "p_count" integer, "p_pad" integer) RETURNS SETOF "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  i integer;
  new_code text;
BEGIN
  IF p_count < 1 OR p_count > 2000 THEN
    RAISE EXCEPTION 'Invalid count (1..2000)';
  END IF;

  FOR i IN 1..p_count LOOP
    new_code := p_prefix || '-' || lpad(i::text, p_pad, '0') || '-' || p_grade::text;

    INSERT INTO public.codes_registry (piece_code, prefix, grade, minted_at)
    VALUES (new_code, p_prefix, p_grade, now())
    ON CONFLICT (piece_code) DO NOTHING;

    RETURN NEXT new_code;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."generate_batch_codes"("p_prefix" "text", "p_grade" "public"."grade_t", "p_count" integer, "p_pad" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_codes_by_request"("p_request_id" "text") RETURNS TABLE("piece_code" "text")
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  select c.piece_code
  from codes_registry c
  where c.request_id = p_request_id
  order by c.serial;
$$;


ALTER FUNCTION "public"."get_codes_by_request"("p_request_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_categories"() RETURNS TABLE("prefix" "text", "name" "text", "is_active" boolean)
    LANGUAGE "sql" STABLE
    AS $$
  SELECT prefix, name, is_active
  FROM public.categories
  WHERE is_active = true
  ORDER BY name;
$$;


ALTER FUNCTION "public"."list_categories"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mint_codes_batch"("p_prefix" "text", "p_count" integer, "p_request_id" "text", "p_pad" integer DEFAULT 4) RETURNS TABLE("code" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_prefix text := upper(regexp_replace(coalesce(p_prefix,''),'[^A-Z]','','g'));
  v_count  int  := greatest(1, least(coalesce(p_count,1), 2000));
  v_pad    int  := greatest(1, least(coalesce(p_pad,4), 8));
  v_start  bigint;
  v_i      int;
  v_serial bigint;
  v_code   text;
begin
  if v_prefix = '' then
    raise exception 'VALIDATION: prefix required';
  end if;

  if p_request_id is null or p_request_id = '' then
    raise exception 'VALIDATION: p_request_id required';
  end if;

  if exists (select 1 from public.request_dedup where request_id = p_request_id) then
    return query
      select c.piece_code::text
      from public.codes_registry c
      where c.request_id = p_request_id
      order by c.serial;
    return;
  else
    insert into public.request_dedup(request_id) values (p_request_id)
    on conflict do nothing;
  end if;

  insert into public.code_counters(prefix, last_serial)
  values (v_prefix, 0)
  on conflict (prefix) do nothing;

  update public.code_counters
     set last_serial = last_serial + v_count
   where prefix = v_prefix
  returning (last_serial - v_count + 1) into v_start;

  for v_i in 0..(v_count - 1) loop
    v_serial := v_start + v_i;
    v_code := v_prefix || '-' || lpad(v_serial::text, v_pad, '0');

    insert into public.codes_registry(request_id, prefix, grade, serial, piece_code)
      values (p_request_id, v_prefix, null, v_serial, v_code)
    on conflict (piece_code) do nothing;

    code := v_code;
    return next;
  end loop;

  return;
end $$;


ALTER FUNCTION "public"."mint_codes_batch"("p_prefix" "text", "p_count" integer, "p_request_id" "text", "p_pad" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mint_codes_batch_legacy"("p_prefix" "text", "p_count" integer, "p_grade" "text", "p_pad" integer, "p_request_id" "text") RETURNS TABLE("code" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_prefix text := upper(regexp_replace(coalesce(p_prefix,''),'[^A-Z]','','g'));
  v_grade  text := upper(regexp_replace(coalesce(p_grade,'A'),'[^A-Z]','','g'));
  v_pad    int  := greatest(1, least(coalesce(p_pad,5), 8));
  v_count  int  := greatest(1, least(coalesce(p_count,1), 2000));
  v_exists boolean;
  v_start  bigint;
  v_i      int;
  v_serial bigint;
  v_code   text;
begin
  if v_prefix = '' then
    raise exception using message = 'VALIDATION: prefix required';
  end if;
  if v_grade not in ('A','B','C','D','E','F') then
    raise exception using message = 'VALIDATION: invalid grade';
  end if;
  if p_request_id is null or p_request_id = '' then
    raise exception using message = 'VALIDATION: p_request_id required';
  end if;

  -- Idempotency: إن كان الطلب موجود، رجّع نفس الأكواد
  select true into v_exists from request_dedup where request_id = p_request_id;
  if v_exists then
    return query
      select c.piece_code::text
      from codes_registry c
      where c.request_id = p_request_id
      order by c.serial;
  else
    insert into request_dedup(request_id) values (p_request_id)
    on conflict do nothing;
  end if;

  -- تأمين سجل العداد للـ prefix
  insert into code_counters(prefix, last_serial)
  values (v_prefix, 0)
  on conflict (prefix) do nothing;

  -- حجز رينج جديد من السيريال
  update code_counters
     set last_serial = last_serial + v_count
   where prefix = v_prefix
  returning (last_serial - v_count + 1) into v_start;

  -- التوليد + التسجيل
  for v_i in 0..(v_count - 1) loop
    v_serial := v_start + v_i;
    v_code := v_prefix || '-' || v_grade || '-' || lpad(v_serial::text, v_pad, '0');

    insert into codes_registry(request_id, prefix, grade, serial, piece_code)
      values (p_request_id, v_prefix, v_grade, v_serial, v_code)
    on conflict on constraint codes_registry_piece_code_key do nothing;

    code := v_code;  -- OUT param
    return next;
  end loop;
end $$;


ALTER FUNCTION "public"."mint_codes_batch_legacy"("p_prefix" "text", "p_count" integer, "p_grade" "text", "p_pad" integer, "p_request_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mint_piece_code"("p_prefix" "text", "p_grade" "public"."grade_t", "p_pad" integer DEFAULT 4) RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  new_serial int;
  new_code   text;
BEGIN
  UPDATE public.code_counters
     SET last_serial = last_serial + 1, updated_at = now()
   WHERE prefix = p_prefix
   RETURNING last_serial INTO new_serial;

  IF NOT FOUND THEN
    INSERT INTO public.code_counters(prefix,last_serial)
    VALUES (p_prefix,1)
    RETURNING last_serial INTO new_serial;
  END IF;

  new_code := p_prefix || '-' || lpad(new_serial::text,p_pad,'0') || '-' || p_grade::text;

  INSERT INTO public.codes_registry(piece_code,prefix,grade)
  VALUES(new_code,p_prefix,p_grade)
  ON CONFLICT DO NOTHING;

  RETURN new_code;
END
$$;


ALTER FUNCTION "public"."mint_piece_code"("p_prefix" "text", "p_grade" "public"."grade_t", "p_pad" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_code_before_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.code is not null then
    new.code :=
      upper(
        regexp_replace(
          translate(new.code, '‐–—−﹘﹣－', '------'), -- unicode dashes → '-'
          '\s*-\s*', '-', 'g'
        )
      );
    new.code := regexp_replace(new.code, '\s+', '', 'g');
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."normalize_code_before_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ocr_logs_upsert"("p_log" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO public.ocr_logs (
    request_id, file_id, source_url, ocr_image_url, storage_path,
    avg_confidence, engine, feature, language_hints, model_version,
    price_raw, size_raw, code_raw,
    price, size, code, prefix, category_name, grade,
    valid_code, valid_size, status, created_by, debug_info,
    created_at, updated_at
  )
  VALUES (
    p_log->>'request_id',
    p_log->>'file_id',
    p_log->>'source_url',
    p_log->>'ocr_image_url',
    p_log->>'storage_path',
    NULLIF(p_log->>'avg_confidence','')::numeric,
    p_log->>'engine',
    p_log->>'feature',
    COALESCE(p_log->'language_hints', '[]'::jsonb),   -- ensure jsonb
    COALESCE(p_log->>'model_version','v1.0'),
    p_log->>'price_raw',
    p_log->>'size_raw',
    p_log->>'code_raw',
    NULLIF(p_log->>'price','')::numeric,
    NULLIF(p_log->>'size','')::numeric,
    NULLIF(p_log->>'code','')::numeric,
    p_log->>'prefix',
    p_log->>'category_name',
    p_log->>'grade',
    (p_log->>'valid_code')::boolean,
    (p_log->>'valid_size')::boolean,
    COALESCE(p_log->>'status','needs_review'),
    COALESCE(p_log->>'created_by','system'),
    COALESCE(p_log->'debug_info','{}'::jsonb),
    NOW(), NOW()
  )
  ON CONFLICT (request_id, file_id)
  DO UPDATE SET
    source_url     = EXCLUDED.source_url,
    ocr_image_url  = EXCLUDED.ocr_image_url,
    storage_path   = EXCLUDED.storage_path,
    avg_confidence = EXCLUDED.avg_confidence,
    engine         = EXCLUDED.engine,
    feature        = EXCLUDED.feature,
    language_hints = EXCLUDED.language_hints,
    model_version  = EXCLUDED.model_version,
    price_raw      = EXCLUDED.price_raw,
    size_raw       = EXCLUDED.size_raw,
    code_raw       = EXCLUDED.code_raw,
    price          = EXCLUDED.price,
    size           = EXCLUDED.size,
    code           = EXCLUDED.code,
    prefix         = EXCLUDED.prefix,
    category_name  = EXCLUDED.category_name,
    grade          = EXCLUDED.grade,
    valid_code     = EXCLUDED.valid_code,
    valid_size     = EXCLUDED.valid_size,
    status         = EXCLUDED.status,
    created_by     = EXCLUDED.created_by,
    debug_info     = COALESCE(public.ocr_logs.debug_info, '{}'::jsonb)
                     || COALESCE(EXCLUDED.debug_info, '{}'::jsonb),
    updated_at     = NOW()
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id,
    'request_id', p_log->>'request_id',
    'file_id', p_log->>'file_id'
  );
END;
$$;


ALTER FUNCTION "public"."ocr_logs_upsert"("p_log" "jsonb") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."ocr_logs" (
    "id" bigint NOT NULL,
    "request_id" "text",
    "file_id" "text",
    "run_id" "uuid" DEFAULT "gen_random_uuid"(),
    "source_system" "text" DEFAULT 'n8n'::"text",
    "job_name" "text",
    "source_url" "text",
    "ocr_image_url" "text",
    "storage_path" "text",
    "engine" "text" DEFAULT 'google_vision'::"text",
    "feature" "text" DEFAULT 'TEXT_DETECTION'::"text",
    "language_hints" "jsonb" DEFAULT '[]'::"jsonb",
    "model_version" "text",
    "avg_confidence" numeric,
    "price_raw" "text",
    "size_raw" "text",
    "code_raw" "text",
    "price" integer,
    "size" "text",
    "code" "text",
    "prefix" "text",
    "category_name" "text",
    "grade" "text",
    "valid_code" boolean,
    "valid_size" boolean,
    "status" "text" DEFAULT 'success'::"text",
    "error_message" "text",
    "started_at" timestamp with time zone DEFAULT "now"(),
    "finished_at" timestamp with time zone,
    "duration_ms" integer,
    "api_cost_usd" numeric,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "text" DEFAULT 'system'::"text",
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "debug_info" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."ocr_logs" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ocr_upsert_v2"("p_log" "jsonb") RETURNS "public"."ocr_logs"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_row public.ocr_logs%ROWTYPE;
BEGIN
  INSERT INTO public.ocr_logs (
    request_id, file_id, run_id, source_system, job_name, source_url, ocr_image_url, storage_path,
    engine, feature, language_hints, model_version, avg_confidence, price_raw, size_raw, code_raw,
    price, size, code, prefix, category_name, grade, valid_code, valid_size, status, error_message,
    started_at, finished_at, duration_ms, api_cost_usd, created_by, tags, debug_info
  ) VALUES (
    (p_log ->> 'request_id'),
    (p_log ->> 'file_id'),
    (CASE WHEN (p_log ? 'run_id') THEN (p_log ->> 'run_id')::uuid ELSE gen_random_uuid() END),
    COALESCE(p_log ->> 'source_system', 'n8n'),
    p_log ->> 'job_name',
    p_log ->> 'source_url',
    p_log ->> 'ocr_image_url',
    p_log ->> 'storage_path',
    COALESCE(p_log ->> 'engine', 'google_vision'),
    COALESCE(p_log ->> 'feature', 'TEXT_DETECTION'),
    COALESCE(p_log -> 'language_hints', '[]'::jsonb),
    p_log ->> 'model_version',
    (CASE WHEN (p_log ->> 'avg_confidence') IS NOT NULL THEN (p_log ->> 'avg_confidence')::numeric ELSE NULL END),
    p_log ->> 'price_raw',
    p_log ->> 'size_raw',
    p_log ->> 'code_raw',
    (CASE WHEN (p_log ->> 'price') IS NOT NULL THEN (p_log ->> 'price')::int ELSE NULL END),
    p_log ->> 'size',
    p_log ->> 'code',
    p_log ->> 'prefix',
    p_log ->> 'category_name',
    p_log ->> 'grade',
    (CASE WHEN (p_log ->> 'valid_code') IS NOT NULL THEN (p_log ->> 'valid_code')::bool ELSE NULL END),
    (CASE WHEN (p_log ->> 'valid_size') IS NOT NULL THEN (p_log ->> 'valid_size')::bool ELSE NULL END),
    COALESCE(p_log ->> 'status', 'success'),
    p_log ->> 'error_message',
    (CASE WHEN (p_log ->> 'started_at') IS NOT NULL THEN (p_log ->> 'started_at')::timestamptz ELSE now() END),
    (CASE WHEN (p_log ->> 'finished_at') IS NOT NULL THEN (p_log ->> 'finished_at')::timestamptz ELSE NULL END),
    (CASE WHEN (p_log ->> 'duration_ms') IS NOT NULL THEN (p_log ->> 'duration_ms')::int ELSE NULL END),
    (CASE WHEN (p_log ->> 'api_cost_usd') IS NOT NULL THEN (p_log ->> 'api_cost_usd')::numeric ELSE NULL END),
    COALESCE(p_log ->> 'created_by', 'system'),
    -- تحويل آمن JSONB -> text[] كما طلبت
    (CASE 
       WHEN p_log ? 'tags' THEN ARRAY(
         SELECT jsonb_array_elements_text(p_log->'tags')
       )
       ELSE NULL
     END),
    COALESCE(p_log -> 'debug_info', '{}'::jsonb)
  )
  ON CONFLICT (request_id, file_id) DO UPDATE
  SET
    run_id = EXCLUDED.run_id,
    source_system = EXCLUDED.source_system,
    job_name = EXCLUDED.job_name,
    source_url = EXCLUDED.source_url,
    ocr_image_url = EXCLUDED.ocr_image_url,
    storage_path = EXCLUDED.storage_path,
    engine = EXCLUDED.engine,
    feature = EXCLUDED.feature,
    language_hints = EXCLUDED.language_hints,
    model_version = EXCLUDED.model_version,
    avg_confidence = EXCLUDED.avg_confidence,
    price_raw = EXCLUDED.price_raw,
    size_raw = EXCLUDED.size_raw,
    code_raw = EXCLUDED.code_raw,
    price = EXCLUDED.price,
    size = EXCLUDED.size,
    code = EXCLUDED.code,
    prefix = EXCLUDED.prefix,
    category_name = EXCLUDED.category_name,
    grade = EXCLUDED.grade,
    valid_code = EXCLUDED.valid_code,
    valid_size = EXCLUDED.valid_size,
    status = EXCLUDED.status,
    error_message = EXCLUDED.error_message,
    started_at = EXCLUDED.started_at,
    finished_at = EXCLUDED.finished_at,
    duration_ms = EXCLUDED.duration_ms,
    api_cost_usd = EXCLUDED.api_cost_usd,
    updated_at = now(),
    created_by = EXCLUDED.created_by,
    -- استخدم الاستبدال الآمن: إذا كانت قيمة tags في EXCLUDED غير NULL فاستخدمها، وإلا احتفظ بقيمة الجدول الحالية
    tags = CASE 
             WHEN EXCLUDED.tags IS NOT NULL THEN EXCLUDED.tags 
             ELSE public.ocr_logs.tags 
           END,
    debug_info = coalesce(public.ocr_logs.debug_info, '{}'::jsonb)
                 || coalesce(EXCLUDED.debug_info, '{}'::jsonb)
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


ALTER FUNCTION "public"."ocr_upsert_v2"("p_log" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pieces_set_category_from_prefix"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.prefix IS DISTINCT FROM OLD.prefix) THEN
    SELECT c.id INTO NEW.category
    FROM public.categories c
    WHERE c.prefix = NEW.prefix
    LIMIT 1;
    -- if no match, leave NULL
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."pieces_set_category_from_prefix"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pieces_set_category_name_from_prefix"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.prefix IS DISTINCT FROM OLD.prefix) THEN
    SELECT c.name INTO NEW.category_name
    FROM public.categories c
    WHERE c.prefix = NEW.prefix
    LIMIT 1;
    -- if no match, leave NULL
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."pieces_set_category_name_from_prefix"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prefix_map_after_insert_trigger_fn"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Insert a categories row if one with the same prefix doesn't exist
  INSERT INTO public.categories(name, prefix, is_active, created_at, updated_at)
  SELECT NEW.category, NEW.prefix, COALESCE(NEW.is_active, true), NEW.created_at, NEW.updated_at
  WHERE NOT EXISTS (SELECT 1 FROM public.categories WHERE prefix = NEW.prefix);

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prefix_map_after_insert_trigger_fn"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_ocr_analytics"() RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  t0 timestamptz := clock_timestamp();
begin
  refresh materialized view concurrently public.ocr_daily_summary_mv;
  refresh materialized view concurrently public.ocr_prefix_performance_mv;
  return json_build_object(
    'status','ok',
    'refreshed', array['ocr_daily_summary_mv','ocr_prefix_performance_mv'],
    'took_ms', extract(milliseconds from (clock_timestamp() - t0))
  );
end;
$$;


ALTER FUNCTION "public"."refresh_ocr_analytics"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_grade_rules"() RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  _deleted int;
  _inserted int;
begin
  delete from public.grade_rules;
  get diagnostics _deleted = row_count;

  insert into public.grade_rules (grade,min_price,max_price,color,description) values
    ('A',14000,null,'#00FF00','Premium items'),
    ('B',10000,15000,'#87CEEB','Standard items'),
    ('C',8000,11000,'#FFD700','Budget items'),
    ('D',0,8000,'#FF6347','Low price');
  get diagnostics _inserted = row_count;

  return json_build_object(
    'deleted', _deleted,
    'inserted', _inserted,
    'status', 'grade_rules reset successfully',
    'timestamp', now()
  );
end;
$$;


ALTER FUNCTION "public"."reset_grade_rules"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END; $$;


ALTER FUNCTION "public"."touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_grade_rule"("p_grade" "text", "p_min" numeric DEFAULT NULL::numeric, "p_max" numeric DEFAULT NULL::numeric, "p_color" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  _updated int := 0;
  _inserted int := 0;
begin
  if not exists (select 1 from public.grade_rules where grade = p_grade) then
    insert into public.grade_rules (grade, min_price, max_price, color, description)
    values (p_grade, p_min, p_max, p_color, coalesce(p_description,''))
    on conflict (grade) do update
      set min_price = excluded.min_price,
          max_price = excluded.max_price,
          color = excluded.color,
          description = excluded.description,
          updated_at = now();
    get diagnostics _inserted = row_count;
  else
    update public.grade_rules
      set min_price = coalesce(p_min, min_price),
          max_price = coalesce(p_max, max_price),
          color = coalesce(p_color, color),
          description = coalesce(p_description, description),
          updated_at = now()
      where grade = p_grade;
    get diagnostics _updated = row_count;
  end if;

  return json_build_object(
    'grade', p_grade,
    'updated', _updated,
    'inserted', _inserted,
    'status', 'rule updated',
    'timestamp', now()
  );
end;
$$;


ALTER FUNCTION "public"."update_grade_rule"("p_grade" "text", "p_min" numeric, "p_max" numeric, "p_color" "text", "p_description" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_prefix_map_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."update_prefix_map_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end $$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."album_buffer" (
    "id" bigint NOT NULL,
    "chat_id" "text" NOT NULL,
    "media_group_id" "text",
    "photos" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "count" integer DEFAULT 0 NOT NULL,
    "last_ts" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."album_buffer" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."album_buffer_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."album_buffer_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."album_buffer_id_seq" OWNED BY "public"."album_buffer"."id";



CREATE TABLE IF NOT EXISTS "public"."categories" (
    "id" bigint NOT NULL,
    "name" "text" NOT NULL,
    "prefix" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."categories" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."categories_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."categories_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."categories_id_seq" OWNED BY "public"."categories"."id";



CREATE TABLE IF NOT EXISTS "public"."code_counters" (
    "prefix" "text" NOT NULL,
    "last_serial" bigint DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."code_counters" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."codes_registry" (
    "id" bigint NOT NULL,
    "request_id" "text" NOT NULL,
    "prefix" "text" NOT NULL,
    "grade" "text",
    "serial" bigint NOT NULL,
    "piece_code" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."codes_registry" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."codes_registry_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."codes_registry_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."codes_registry_id_seq" OWNED BY "public"."codes_registry"."id";



CREATE TABLE IF NOT EXISTS "public"."customers" (
    "id" bigint NOT NULL,
    "name" "text",
    "phone" "text",
    "messenger_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."customers" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."customers_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."customers_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."customers_id_seq" OWNED BY "public"."customers"."id";



CREATE TABLE IF NOT EXISTS "public"."grade_rules" (
    "id" bigint NOT NULL,
    "grade" "text" NOT NULL,
    "min_price" numeric,
    "max_price" numeric,
    "color" "text",
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_active" boolean DEFAULT true
);


ALTER TABLE "public"."grade_rules" OWNER TO "postgres";


ALTER TABLE "public"."grade_rules" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."grade_rules_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."images" (
    "id" bigint NOT NULL,
    "piece_id" "text",
    "url" "text" NOT NULL,
    "type" "text" DEFAULT 'main'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."images" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."images_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."images_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."images_id_seq" OWNED BY "public"."images"."id";



CREATE TABLE IF NOT EXISTS "public"."inventory_movements" (
    "id" bigint NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "piece_id" "text" NOT NULL,
    "movement_type" "public"."movement_type_t" NOT NULL,
    "qty_delta" integer DEFAULT 0 NOT NULL,
    "cost_delta" numeric,
    "price_at_event" numeric,
    "channel" "public"."sales_channel_t",
    "order_id" bigint,
    "actor" "text",
    "reason" "text",
    "meta" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."inventory_movements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pieces" (
    "id" bigint NOT NULL,
    "code" "text" NOT NULL,
    "prefix" "text" NOT NULL,
    "category" bigint,
    "grade" "public"."grade_t",
    "size" "text",
    "price" numeric,
    "status" "public"."piece_status_t" DEFAULT 'in_stock'::"public"."piece_status_t",
    "ocr_request_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "category_name" "text"
);


ALTER TABLE "public"."pieces" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."inventory_daily_snapshot" AS
 WITH "movements" AS (
         SELECT (("im"."occurred_at" AT TIME ZONE 'Asia/Seoul'::"text"))::"date" AS "day_kst",
            "im"."piece_id" AS "code",
            "im"."movement_type",
            COALESCE("im"."qty_delta", 1) AS "qty",
            "im"."actor",
            "im"."channel"
           FROM "public"."inventory_movements" "im"
        )
 SELECT "m"."day_kst",
    "m"."code",
    "p"."prefix",
    ( SELECT "c"."name"
           FROM "public"."categories" "c"
          WHERE ("c"."id" = "p"."category")) AS "category_name",
    "p"."grade",
    "p"."size",
    "p"."price",
    "count"(*) FILTER (WHERE ("m"."movement_type" = 'stock_in'::"public"."movement_type_t")) AS "cnt_stock_in",
    "count"(*) FILTER (WHERE ("m"."movement_type" = 'sell'::"public"."movement_type_t")) AS "cnt_sold",
    "count"(*) FILTER (WHERE ("m"."movement_type" = 'return'::"public"."movement_type_t")) AS "cnt_returned",
    "count"(*) FILTER (WHERE ("m"."movement_type" = 'list'::"public"."movement_type_t")) AS "cnt_list",
    "sum"(
        CASE
            WHEN ("m"."movement_type" = ANY (ARRAY['stock_in'::"public"."movement_type_t", 'return'::"public"."movement_type_t"])) THEN "m"."qty"
            WHEN ("m"."movement_type" = 'sell'::"public"."movement_type_t") THEN (- "m"."qty")
            ELSE 0
        END) AS "net_qty",
    "sum"(
        CASE
            WHEN ("m"."movement_type" = ANY (ARRAY['stock_in'::"public"."movement_type_t", 'return'::"public"."movement_type_t"])) THEN "m"."qty"
            ELSE 0
        END) AS "qty_in",
    "sum"(
        CASE
            WHEN ("m"."movement_type" = 'sell'::"public"."movement_type_t") THEN "m"."qty"
            ELSE 0
        END) AS "qty_out"
   FROM ("movements" "m"
     JOIN "public"."pieces" "p" ON (("m"."code" = "p"."code")))
  GROUP BY "m"."day_kst", "m"."code", "p"."prefix", ( SELECT "c"."name"
           FROM "public"."categories" "c"
          WHERE ("c"."id" = "p"."category")), "p"."grade", "p"."size", "p"."price"
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."inventory_daily_snapshot" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."inventory_movements_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."inventory_movements_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."inventory_movements_id_seq" OWNED BY "public"."inventory_movements"."id";



CREATE TABLE IF NOT EXISTS "public"."ocr_logs_backup" (
    "id" bigint,
    "request_id" "text",
    "run_id" "uuid",
    "source_system" "text",
    "job_name" "text",
    "source_url" "text",
    "ocr_image_url" "text",
    "storage_path" "text",
    "engine" "text",
    "feature" "text",
    "language_hints" "text"[],
    "model_version" "text",
    "avg_confidence" numeric,
    "price_raw" "text",
    "size_raw" "text",
    "code_raw" "text",
    "price" integer,
    "size" "text",
    "code" "text",
    "prefix" "text",
    "category_name" "text",
    "grade" "text",
    "valid_code" boolean,
    "valid_size" boolean,
    "status" "text",
    "error_message" "text",
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "duration_ms" integer,
    "api_cost_usd" numeric,
    "created_at" timestamp with time zone,
    "created_by" "text",
    "tags" "text"[],
    "debug_info" "jsonb"
);


ALTER TABLE "public"."ocr_logs_backup" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ocr_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ocr_logs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ocr_logs_id_seq" OWNED BY "public"."ocr_logs"."id";



CREATE TABLE IF NOT EXISTS "public"."ocr_review_actions_log" (
    "id" bigint NOT NULL,
    "request_id" "text" NOT NULL,
    "action" "text" NOT NULL,
    "actor" "text" NOT NULL,
    "payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "ocr_review_actions_log_action_check" CHECK (("action" = ANY (ARRAY['queued'::"text", 'sent'::"text", 'reply'::"text", 'pass'::"text", 'retry'::"text", 'error'::"text"])))
);


ALTER TABLE "public"."ocr_review_actions_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ocr_review_actions_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ocr_review_actions_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ocr_review_actions_log_id_seq" OWNED BY "public"."ocr_review_actions_log"."id";



CREATE TABLE IF NOT EXISTS "public"."ocr_review_queue" (
    "id" bigint NOT NULL,
    "request_id" "text" NOT NULL,
    "image_url" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "manual_code" "text",
    "annotated_url" "text",
    "attempt" integer DEFAULT 0,
    "last_candidates" "jsonb" DEFAULT '[]'::"jsonb",
    "notes" "text",
    "reviewed_by" "text",
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "chat_id" bigint,
    "message_id" bigint,
    "file_id" "text",
    "price" bigint,
    "size" "text",
    "code" "text",
    CONSTRAINT "ocr_review_queue_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'passed'::"text", 'fixed'::"text", 'error'::"text"])))
);


ALTER TABLE "public"."ocr_review_queue" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ocr_review_queue_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ocr_review_queue_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ocr_review_queue_id_seq" OWNED BY "public"."ocr_review_queue"."id";



CREATE OR REPLACE VIEW "public"."ocr_unresolved" AS
 SELECT "id",
    "request_id",
    "image_url",
    "status",
    "manual_code",
    "annotated_url",
    "attempt",
    "last_candidates",
    "notes",
    "reviewed_by",
    "reviewed_at",
    "created_at",
    "updated_at"
   FROM "public"."ocr_review_queue"
  WHERE ("status" = ANY (ARRAY['pending'::"text", 'error'::"text"]));


ALTER VIEW "public"."ocr_unresolved" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."pieces_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pieces_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pieces_id_seq" OWNED BY "public"."pieces"."id";



CREATE TABLE IF NOT EXISTS "public"."prefix_map" (
    "id" bigint NOT NULL,
    "prefix" "text" NOT NULL,
    "category" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "prefix_norm" "text" GENERATED ALWAYS AS ("upper"("prefix")) STORED,
    CONSTRAINT "chk_prefix_shape_1_2_letters" CHECK (("prefix" ~ '^[A-Za-z]{1,2}$'::"text"))
);


ALTER TABLE "public"."prefix_map" OWNER TO "postgres";


ALTER TABLE "public"."prefix_map" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."prefix_map_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."print_jobs" (
    "id" bigint NOT NULL,
    "request_id" "text" NOT NULL,
    "status" "text" DEFAULT 'generated'::"text" NOT NULL,
    "pages" integer DEFAULT 1 NOT NULL,
    "pages_printed" integer,
    "sheet_layout" "text" DEFAULT 'CL3048'::"text",
    "checksum" "text",
    "html_blob" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "printed_at" timestamp with time zone,
    CONSTRAINT "print_jobs_status_check" CHECK (("status" = ANY (ARRAY['requested'::"text", 'generated'::"text", 'printed'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."print_jobs" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."print_jobs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."print_jobs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."print_jobs_id_seq" OWNED BY "public"."print_jobs"."id";



CREATE TABLE IF NOT EXISTS "public"."promotions" (
    "id" bigint NOT NULL,
    "code" "text",
    "name" "text",
    "channel" "public"."sales_channel_t",
    "starts_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "meta" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."promotions" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."promotions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."promotions_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."promotions_id_seq" OWNED BY "public"."promotions"."id";



CREATE TABLE IF NOT EXISTS "public"."request_dedup" (
    "request_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."request_dedup" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."returns" (
    "id" bigint NOT NULL,
    "order_id" bigint NOT NULL,
    "piece_id" bigint NOT NULL,
    "reason" "public"."return_reason_t",
    "resolved_action" "text",
    "refund_amount" numeric,
    "occurred_at" timestamp with time zone DEFAULT "now"(),
    "notes" "text"
);


ALTER TABLE "public"."returns" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."returns_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."returns_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."returns_id_seq" OWNED BY "public"."returns"."id";



CREATE TABLE IF NOT EXISTS "public"."sales_order_items" (
    "id" bigint NOT NULL,
    "order_id" bigint NOT NULL,
    "piece_id" bigint NOT NULL,
    "qty" integer DEFAULT 1 NOT NULL,
    "unit_price" numeric,
    "unit_cost" numeric,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."sales_order_items" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."sales_order_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."sales_order_items_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."sales_order_items_id_seq" OWNED BY "public"."sales_order_items"."id";



CREATE TABLE IF NOT EXISTS "public"."sales_orders" (
    "id" bigint NOT NULL,
    "order_code" "text",
    "status" "public"."order_status_t" DEFAULT 'pending'::"public"."order_status_t" NOT NULL,
    "customer_id" bigint,
    "channel" "public"."sales_channel_t" DEFAULT 'messenger'::"public"."sales_channel_t" NOT NULL,
    "subtotal_amount" numeric,
    "discount_amount" numeric DEFAULT 0,
    "shipping_amount" numeric DEFAULT 0,
    "total_amount" numeric,
    "payment_method" "public"."payment_method_t",
    "paid_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "notes" "text"
);


ALTER TABLE "public"."sales_orders" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."sales_orders_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."sales_orders_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."sales_orders_id_seq" OWNED BY "public"."sales_orders"."id";



CREATE TABLE IF NOT EXISTS "public"."workflow_errors" (
    "id" bigint NOT NULL,
    "workflow" "text" NOT NULL,
    "node" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "description" "text"
);


ALTER TABLE "public"."workflow_errors" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."workflow_errors_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."workflow_errors_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."workflow_errors_id_seq" OWNED BY "public"."workflow_errors"."id";



ALTER TABLE ONLY "public"."album_buffer" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."album_buffer_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."categories" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."categories_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."codes_registry" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."codes_registry_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."customers" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."customers_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."images" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."images_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."inventory_movements" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."inventory_movements_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."ocr_logs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."ocr_logs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."ocr_review_actions_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."ocr_review_actions_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."ocr_review_queue" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."ocr_review_queue_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pieces" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pieces_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."print_jobs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."print_jobs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."promotions" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."promotions_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."returns" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."returns_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."sales_order_items" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."sales_order_items_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."sales_orders" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."sales_orders_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."workflow_errors" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."workflow_errors_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."album_buffer"
    ADD CONSTRAINT "album_buffer_chat_id_media_group_id_key" UNIQUE ("chat_id", "media_group_id");



ALTER TABLE ONLY "public"."album_buffer"
    ADD CONSTRAINT "album_buffer_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_prefix_key" UNIQUE ("prefix");



ALTER TABLE ONLY "public"."code_counters"
    ADD CONSTRAINT "code_counters_pkey" PRIMARY KEY ("prefix");



ALTER TABLE ONLY "public"."codes_registry"
    ADD CONSTRAINT "codes_registry_piece_code_key" UNIQUE ("piece_code");



ALTER TABLE ONLY "public"."codes_registry"
    ADD CONSTRAINT "codes_registry_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."codes_registry"
    ADD CONSTRAINT "codes_registry_request_id_serial_key" UNIQUE ("request_id", "serial");



ALTER TABLE ONLY "public"."customers"
    ADD CONSTRAINT "customers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grade_rules"
    ADD CONSTRAINT "grade_rules_grade_key" UNIQUE ("grade");



ALTER TABLE ONLY "public"."grade_rules"
    ADD CONSTRAINT "grade_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."images"
    ADD CONSTRAINT "images_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ocr_logs"
    ADD CONSTRAINT "ocr_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ocr_review_actions_log"
    ADD CONSTRAINT "ocr_review_actions_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ocr_review_queue"
    ADD CONSTRAINT "ocr_review_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pieces"
    ADD CONSTRAINT "pieces_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."pieces"
    ADD CONSTRAINT "pieces_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."prefix_map"
    ADD CONSTRAINT "prefix_map_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."prefix_map"
    ADD CONSTRAINT "prefix_map_prefix_key" UNIQUE ("prefix");



ALTER TABLE ONLY "public"."print_jobs"
    ADD CONSTRAINT "print_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."print_jobs"
    ADD CONSTRAINT "print_jobs_request_id_key" UNIQUE ("request_id");



ALTER TABLE ONLY "public"."promotions"
    ADD CONSTRAINT "promotions_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."promotions"
    ADD CONSTRAINT "promotions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."request_dedup"
    ADD CONSTRAINT "request_dedup_pkey" PRIMARY KEY ("request_id");



ALTER TABLE ONLY "public"."returns"
    ADD CONSTRAINT "returns_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_order_items"
    ADD CONSTRAINT "sales_order_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_orders"
    ADD CONSTRAINT "sales_orders_order_code_key" UNIQUE ("order_code");



ALTER TABLE ONLY "public"."sales_orders"
    ADD CONSTRAINT "sales_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workflow_errors"
    ADD CONSTRAINT "workflow_errors_pkey" PRIMARY KEY ("id");



CREATE INDEX "codes_registry_prefix_serial_idx" ON "public"."codes_registry" USING "btree" ("prefix", "serial");



CREATE INDEX "codes_registry_request_id_idx" ON "public"."codes_registry" USING "btree" ("request_id");



CREATE INDEX "idx_album_buffer_last_ts" ON "public"."album_buffer" USING "btree" ("last_ts" DESC);



CREATE INDEX "idx_images_piece_id" ON "public"."images" USING "btree" ("piece_id");



CREATE INDEX "idx_inv_moves_order" ON "public"."inventory_movements" USING "btree" ("order_id");



CREATE INDEX "idx_inv_moves_piece_time" ON "public"."inventory_movements" USING "btree" ("piece_id", "occurred_at" DESC);



CREATE INDEX "idx_inv_moves_type_time" ON "public"."inventory_movements" USING "btree" ("movement_type", "occurred_at" DESC);



CREATE INDEX "idx_ocr_actions_req" ON "public"."ocr_review_actions_log" USING "btree" ("request_id");



CREATE INDEX "idx_ocr_review_queue_status_created_at" ON "public"."ocr_review_queue" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "idx_ocr_review_status" ON "public"."ocr_review_queue" USING "btree" ("status");



CREATE UNIQUE INDEX "idx_ocr_review_unique" ON "public"."ocr_review_queue" USING "btree" ("request_id", "attempt");



CREATE INDEX "idx_pieces_prefix" ON "public"."pieces" USING "btree" ("prefix");



CREATE INDEX "idx_pieces_status" ON "public"."pieces" USING "btree" ("status");



CREATE INDEX "idx_prefix_map_prefix" ON "public"."prefix_map" USING "btree" ("prefix");



CREATE INDEX "idx_returns_order" ON "public"."returns" USING "btree" ("order_id");



CREATE INDEX "idx_so_items_order" ON "public"."sales_order_items" USING "btree" ("order_id");



CREATE INDEX "idx_so_items_piece" ON "public"."sales_order_items" USING "btree" ("piece_id");



CREATE UNIQUE INDEX "images_piece_unique" ON "public"."images" USING "btree" ("piece_id");



CREATE UNIQUE INDEX "ocr_logs_req_fileid_uniq" ON "public"."ocr_logs" USING "btree" ("request_id", "file_id");



CREATE UNIQUE INDEX "ocr_review_queue_req_file_uniq" ON "public"."ocr_review_queue" USING "btree" ("request_id", "file_id");



CREATE INDEX "ocr_review_queue_status_idx" ON "public"."ocr_review_queue" USING "btree" ("status");



CREATE UNIQUE INDEX "uq_category_ci" ON "public"."prefix_map" USING "btree" ("lower"("category"));



CREATE UNIQUE INDEX "uq_prefix_norm" ON "public"."prefix_map" USING "btree" ("prefix_norm");



CREATE UNIQUE INDEX "ux_inventory_daily_snapshot_pk" ON "public"."inventory_daily_snapshot" USING "btree" ("day_kst", "code");



CREATE UNIQUE INDEX "ux_one_stock_in_per_piece" ON "public"."inventory_movements" USING "btree" ("piece_id") WHERE ("movement_type" = 'stock_in'::"public"."movement_type_t");



CREATE INDEX "workflow_errors_created_at_idx" ON "public"."workflow_errors" USING "btree" ("created_at" DESC);



CREATE OR REPLACE TRIGGER "prefix_map_after_insert_trigger" AFTER INSERT ON "public"."prefix_map" FOR EACH ROW EXECUTE FUNCTION "public"."prefix_map_after_insert_trigger_fn"();



CREATE OR REPLACE TRIGGER "trg_categories_propagate_name_change" AFTER UPDATE OF "name" ON "public"."categories" FOR EACH ROW EXECUTE FUNCTION "public"."categories_propagate_name_change"();



CREATE OR REPLACE TRIGGER "trg_categories_updated" BEFORE UPDATE ON "public"."categories" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_ocr_review_queue_updated_at" BEFORE UPDATE ON "public"."ocr_review_queue" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_ocr_review_updated" BEFORE UPDATE ON "public"."ocr_review_queue" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trg_pieces_set_category_name_on_prefix" BEFORE INSERT OR UPDATE OF "prefix" ON "public"."pieces" FOR EACH ROW EXECUTE FUNCTION "public"."pieces_set_category_name_from_prefix"();



CREATE OR REPLACE TRIGGER "trg_pieces_set_category_on_prefix" BEFORE INSERT OR UPDATE OF "prefix" ON "public"."pieces" FOR EACH ROW EXECUTE FUNCTION "public"."pieces_set_category_from_prefix"();



CREATE OR REPLACE TRIGGER "trg_pieces_updated" BEFORE UPDATE ON "public"."pieces" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_prefix_map_updated" BEFORE UPDATE ON "public"."prefix_map" FOR EACH ROW EXECUTE FUNCTION "public"."update_prefix_map_timestamp"();



CREATE OR REPLACE TRIGGER "trg_sales_orders_updated" BEFORE UPDATE ON "public"."sales_orders" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_set_updated_at" BEFORE UPDATE ON "public"."ocr_logs" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at_review_queue" BEFORE UPDATE ON "public"."ocr_review_queue" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_prefix_fkey" FOREIGN KEY ("prefix") REFERENCES "public"."prefix_map"("prefix");



ALTER TABLE ONLY "public"."images"
    ADD CONSTRAINT "images_piece_code_fkey" FOREIGN KEY ("piece_id") REFERENCES "public"."pieces"("code") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_movements"
    ADD CONSTRAINT "inventory_movements_piece_code_fkey" FOREIGN KEY ("piece_id") REFERENCES "public"."pieces"("code") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pieces"
    ADD CONSTRAINT "pieces_category_fkey" FOREIGN KEY ("category") REFERENCES "public"."categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pieces"
    ADD CONSTRAINT "pieces_code_fkey" FOREIGN KEY ("code") REFERENCES "public"."codes_registry"("piece_code");



ALTER TABLE ONLY "public"."pieces"
    ADD CONSTRAINT "pieces_prefix_fkey" FOREIGN KEY ("prefix") REFERENCES "public"."prefix_map"("prefix");



ALTER TABLE ONLY "public"."returns"
    ADD CONSTRAINT "returns_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."sales_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."returns"
    ADD CONSTRAINT "returns_piece_id_fkey" FOREIGN KEY ("piece_id") REFERENCES "public"."pieces"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."sales_order_items"
    ADD CONSTRAINT "sales_order_items_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."sales_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sales_order_items"
    ADD CONSTRAINT "sales_order_items_piece_id_fkey" FOREIGN KEY ("piece_id") REFERENCES "public"."pieces"("id") ON DELETE RESTRICT;





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."album_buffer_add"("p_chat_id" "text", "p_media_group_id" "text", "p_photo" "jsonb", "p_expected" integer, "p_debounce_seconds" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."album_buffer_add"("p_chat_id" "text", "p_media_group_id" "text", "p_photo" "jsonb", "p_expected" integer, "p_debounce_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."album_buffer_add"("p_chat_id" "text", "p_media_group_id" "text", "p_photo" "jsonb", "p_expected" integer, "p_debounce_seconds" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."categories_propagate_name_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."categories_propagate_name_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."categories_propagate_name_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."categories_propagate_name_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_and_reserve_codes"("p_prefix" "text", "p_grade" "public"."grade_t", "p_count" integer, "p_pad" integer, "p_request_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_and_reserve_codes"("p_prefix" "text", "p_grade" "public"."grade_t", "p_count" integer, "p_pad" integer, "p_request_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_and_reserve_codes"("p_prefix" "text", "p_grade" "public"."grade_t", "p_count" integer, "p_pad" integer, "p_request_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_batch_codes"("p_prefix" "text", "p_grade" "public"."grade_t", "p_count" integer, "p_pad" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."generate_batch_codes"("p_prefix" "text", "p_grade" "public"."grade_t", "p_count" integer, "p_pad" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_batch_codes"("p_prefix" "text", "p_grade" "public"."grade_t", "p_count" integer, "p_pad" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_codes_by_request"("p_request_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_codes_by_request"("p_request_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_codes_by_request"("p_request_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."list_categories"() TO "anon";
GRANT ALL ON FUNCTION "public"."list_categories"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_categories"() TO "service_role";



GRANT ALL ON FUNCTION "public"."mint_codes_batch"("p_prefix" "text", "p_count" integer, "p_request_id" "text", "p_pad" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."mint_codes_batch"("p_prefix" "text", "p_count" integer, "p_request_id" "text", "p_pad" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."mint_codes_batch"("p_prefix" "text", "p_count" integer, "p_request_id" "text", "p_pad" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."mint_codes_batch_legacy"("p_prefix" "text", "p_count" integer, "p_grade" "text", "p_pad" integer, "p_request_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."mint_codes_batch_legacy"("p_prefix" "text", "p_count" integer, "p_grade" "text", "p_pad" integer, "p_request_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mint_codes_batch_legacy"("p_prefix" "text", "p_count" integer, "p_grade" "text", "p_pad" integer, "p_request_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."mint_piece_code"("p_prefix" "text", "p_grade" "public"."grade_t", "p_pad" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."mint_piece_code"("p_prefix" "text", "p_grade" "public"."grade_t", "p_pad" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."mint_piece_code"("p_prefix" "text", "p_grade" "public"."grade_t", "p_pad" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_code_before_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_code_before_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_code_before_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."ocr_logs_upsert"("p_log" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."ocr_logs_upsert"("p_log" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ocr_logs_upsert"("p_log" "jsonb") TO "service_role";



GRANT ALL ON TABLE "public"."ocr_logs" TO "anon";
GRANT ALL ON TABLE "public"."ocr_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."ocr_logs" TO "service_role";



GRANT ALL ON FUNCTION "public"."ocr_upsert_v2"("p_log" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."ocr_upsert_v2"("p_log" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ocr_upsert_v2"("p_log" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."pieces_set_category_from_prefix"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."pieces_set_category_from_prefix"() TO "anon";
GRANT ALL ON FUNCTION "public"."pieces_set_category_from_prefix"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."pieces_set_category_from_prefix"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."pieces_set_category_name_from_prefix"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."pieces_set_category_name_from_prefix"() TO "anon";
GRANT ALL ON FUNCTION "public"."pieces_set_category_name_from_prefix"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."pieces_set_category_name_from_prefix"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prefix_map_after_insert_trigger_fn"() TO "anon";
GRANT ALL ON FUNCTION "public"."prefix_map_after_insert_trigger_fn"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prefix_map_after_insert_trigger_fn"() TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_ocr_analytics"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_ocr_analytics"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_ocr_analytics"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reset_grade_rules"() TO "anon";
GRANT ALL ON FUNCTION "public"."reset_grade_rules"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_grade_rules"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_grade_rule"("p_grade" "text", "p_min" numeric, "p_max" numeric, "p_color" "text", "p_description" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_grade_rule"("p_grade" "text", "p_min" numeric, "p_max" numeric, "p_color" "text", "p_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_grade_rule"("p_grade" "text", "p_min" numeric, "p_max" numeric, "p_color" "text", "p_description" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_prefix_map_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_prefix_map_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_prefix_map_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";


















GRANT ALL ON TABLE "public"."album_buffer" TO "anon";
GRANT ALL ON TABLE "public"."album_buffer" TO "authenticated";
GRANT ALL ON TABLE "public"."album_buffer" TO "service_role";



GRANT ALL ON SEQUENCE "public"."album_buffer_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."album_buffer_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."album_buffer_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."categories" TO "anon";
GRANT ALL ON TABLE "public"."categories" TO "authenticated";
GRANT ALL ON TABLE "public"."categories" TO "service_role";



GRANT ALL ON SEQUENCE "public"."categories_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."categories_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."categories_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."code_counters" TO "anon";
GRANT ALL ON TABLE "public"."code_counters" TO "authenticated";
GRANT ALL ON TABLE "public"."code_counters" TO "service_role";



GRANT ALL ON TABLE "public"."codes_registry" TO "anon";
GRANT ALL ON TABLE "public"."codes_registry" TO "authenticated";
GRANT ALL ON TABLE "public"."codes_registry" TO "service_role";



GRANT ALL ON SEQUENCE "public"."codes_registry_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."codes_registry_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."codes_registry_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."customers" TO "anon";
GRANT ALL ON TABLE "public"."customers" TO "authenticated";
GRANT ALL ON TABLE "public"."customers" TO "service_role";



GRANT ALL ON SEQUENCE "public"."customers_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."customers_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."customers_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."grade_rules" TO "anon";
GRANT ALL ON TABLE "public"."grade_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."grade_rules" TO "service_role";



GRANT ALL ON SEQUENCE "public"."grade_rules_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."grade_rules_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."grade_rules_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."images" TO "anon";
GRANT ALL ON TABLE "public"."images" TO "authenticated";
GRANT ALL ON TABLE "public"."images" TO "service_role";



GRANT ALL ON SEQUENCE "public"."images_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."images_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."images_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_movements" TO "anon";
GRANT ALL ON TABLE "public"."inventory_movements" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_movements" TO "service_role";



GRANT ALL ON TABLE "public"."pieces" TO "anon";
GRANT ALL ON TABLE "public"."pieces" TO "authenticated";
GRANT ALL ON TABLE "public"."pieces" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_daily_snapshot" TO "anon";
GRANT ALL ON TABLE "public"."inventory_daily_snapshot" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_daily_snapshot" TO "service_role";



GRANT ALL ON SEQUENCE "public"."inventory_movements_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."inventory_movements_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."inventory_movements_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ocr_logs_backup" TO "anon";
GRANT ALL ON TABLE "public"."ocr_logs_backup" TO "authenticated";
GRANT ALL ON TABLE "public"."ocr_logs_backup" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ocr_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ocr_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ocr_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ocr_review_actions_log" TO "anon";
GRANT ALL ON TABLE "public"."ocr_review_actions_log" TO "authenticated";
GRANT ALL ON TABLE "public"."ocr_review_actions_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ocr_review_actions_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ocr_review_actions_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ocr_review_actions_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ocr_review_queue" TO "anon";
GRANT ALL ON TABLE "public"."ocr_review_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."ocr_review_queue" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ocr_review_queue_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ocr_review_queue_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ocr_review_queue_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ocr_unresolved" TO "anon";
GRANT ALL ON TABLE "public"."ocr_unresolved" TO "authenticated";
GRANT ALL ON TABLE "public"."ocr_unresolved" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pieces_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pieces_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pieces_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."prefix_map" TO "anon";
GRANT ALL ON TABLE "public"."prefix_map" TO "authenticated";
GRANT ALL ON TABLE "public"."prefix_map" TO "service_role";



GRANT ALL ON SEQUENCE "public"."prefix_map_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."prefix_map_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."prefix_map_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."print_jobs" TO "anon";
GRANT ALL ON TABLE "public"."print_jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."print_jobs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."print_jobs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."print_jobs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."print_jobs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."promotions" TO "anon";
GRANT ALL ON TABLE "public"."promotions" TO "authenticated";
GRANT ALL ON TABLE "public"."promotions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."promotions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."promotions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."promotions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."request_dedup" TO "anon";
GRANT ALL ON TABLE "public"."request_dedup" TO "authenticated";
GRANT ALL ON TABLE "public"."request_dedup" TO "service_role";



GRANT ALL ON TABLE "public"."returns" TO "anon";
GRANT ALL ON TABLE "public"."returns" TO "authenticated";
GRANT ALL ON TABLE "public"."returns" TO "service_role";



GRANT ALL ON SEQUENCE "public"."returns_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."returns_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."returns_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sales_order_items" TO "anon";
GRANT ALL ON TABLE "public"."sales_order_items" TO "authenticated";
GRANT ALL ON TABLE "public"."sales_order_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sales_order_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sales_order_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sales_order_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sales_orders" TO "anon";
GRANT ALL ON TABLE "public"."sales_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."sales_orders" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sales_orders_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sales_orders_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sales_orders_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."workflow_errors" TO "anon";
GRANT ALL ON TABLE "public"."workflow_errors" TO "authenticated";
GRANT ALL ON TABLE "public"."workflow_errors" TO "service_role";



GRANT ALL ON SEQUENCE "public"."workflow_errors_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."workflow_errors_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."workflow_errors_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































drop extension if exists "pg_net";


