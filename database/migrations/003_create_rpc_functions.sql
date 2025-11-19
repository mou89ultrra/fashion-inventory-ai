-- Create all RPC functions for AI Messenger

-- 1. get_popular_brands
CREATE OR REPLACE FUNCTION get_popular_brands(
  p_gender text DEFAULT NULL,
  p_limit int DEFAULT 10
)
RETURNS TABLE (
  brand text,
  gender_segment text,
  sales_count bigint,
  avg_price numeric,
  popular_colors text[]
) 
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    pb.brand::text,
    pb.gender_segment::text,
    pb.sales_count,
    pb.avg_price,
    pb.popular_colors
  FROM mv_popular_brands pb
  WHERE (p_gender IS NULL OR pb.gender_segment = p_gender)
  ORDER BY pb.sales_count DESC
  LIMIT p_limit;
END;
$$;

-- 2. get_trending_colors
CREATE OR REPLACE FUNCTION get_trending_colors(
  p_gender text DEFAULT NULL,
  p_limit int DEFAULT 5
)
RETURNS TABLE (
  primary_color text,
  gender_segment text,
  sales_count bigint,
  avg_price numeric,
  brands_in_this_color text[]
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    tc.primary_color::text,
    tc.gender_segment::text,
    tc.sales_count,
    tc.avg_price,
    tc.brands_in_this_color
  FROM mv_trending_colors tc
  WHERE (p_gender IS NULL OR tc.gender_segment = p_gender)
  ORDER BY tc.sales_count DESC
  LIMIT p_limit;
END;
$$;

-- 3. get_best_sellers
CREATE OR REPLACE FUNCTION get_best_sellers(
  p_gender text DEFAULT NULL,
  p_brand text DEFAULT NULL,
  p_limit int DEFAULT 10
)
RETURNS TABLE (
  piece_id text,
  brand text,
  primary_color text,
  style text,
  category_name text,
  times_sold bigint,
  avg_price numeric
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    bs.piece_id::text,
    bs.brand::text,
    bs.primary_color::text,
    bs.style::text,
    bs.category_name::text,
    bs.times_sold,
    bs.avg_price
  FROM mv_best_sellers bs
  WHERE (p_gender IS NULL OR bs.gender_segment = p_gender)
    AND (p_brand IS NULL OR bs.brand ILIKE '%' || p_brand || '%')
  ORDER BY bs.times_sold DESC
  LIMIT p_limit;
END;
$$;

-- 4. search_items
CREATE OR REPLACE FUNCTION search_items(
  p_brand text DEFAULT NULL,
  p_color text DEFAULT NULL,
  p_style text DEFAULT NULL,
  p_gender text DEFAULT NULL,
  p_min_price numeric DEFAULT NULL,
  p_max_price numeric DEFAULT NULL,
  p_limit int DEFAULT 20
)
RETURNS TABLE (
  code text,
  brand text,
  primary_color text,
  style text,
  size text,
  price numeric,
  grade text,
  category_name text,
  status text
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.code::text,
    p.brand::text,
    p.primary_color::text,
    p.style::text,
    p.size::text,
    p.price,
    p.grade::text,
    p.category_name::text,
    p.status::text
  FROM pieces p
  WHERE p.status = 'in_stock'
    AND (p_brand IS NULL OR p.brand ILIKE '%' || p_brand || '%')
    AND (p_color IS NULL OR p.primary_color ILIKE '%' || p_color || '%')
    AND (p_style IS NULL OR p.style ILIKE '%' || p_style || '%')
    AND (p_gender IS NULL OR p.gender_segment = p_gender)
    AND (p_min_price IS NULL OR p.price >= p_min_price)
    AND (p_max_price IS NULL OR p.price <= p_max_price)
  ORDER BY p.created_at DESC
  LIMIT p_limit;
END;
$$;

-- 5. get_similar_items
CREATE OR REPLACE FUNCTION get_similar_items(
  p_piece_id text,
  p_limit int DEFAULT 10
)
RETURNS TABLE (
  code text,
  brand text,
  primary_color text,
  style text,
  size text,
  price numeric,
  similarity_score int
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH target AS (
    SELECT 
      pieces.brand AS tgt_brand,
      pieces.primary_color AS tgt_primary_color,
      pieces.style AS tgt_style,
      pieces.pattern AS tgt_pattern,
      pieces.category_name AS tgt_category_name,
      pieces.price AS tgt_price
    FROM pieces
    WHERE pieces.code = p_piece_id
  )
  SELECT 
    p.code::text,
    p.brand::text,
    p.primary_color::text,
    p.style::text,
    p.size::text,
    p.price,
    (
      CASE WHEN p.brand = t.tgt_brand THEN 4 ELSE 0 END +
      CASE WHEN p.primary_color = t.tgt_primary_color THEN 3 ELSE 0 END +
      CASE WHEN p.style = t.tgt_style THEN 2 ELSE 0 END +
      CASE WHEN p.category_name = t.tgt_category_name THEN 1 ELSE 0 END
    )::int as similarity_score
  FROM pieces p
  CROSS JOIN target t
  WHERE p.status = 'in_stock'
    AND p.code != p_piece_id
    AND (
      p.brand = t.tgt_brand
      OR p.primary_color = t.tgt_primary_color
      OR p.style = t.tgt_style
      OR p.category_name = t.tgt_category_name
    )
  ORDER BY similarity_score DESC, ABS(p.price - t.tgt_price) ASC
  LIMIT p_limit;
END;
$$;

-- 6. refresh_analytics
CREATE OR REPLACE FUNCTION refresh_analytics()
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_popular_brands;
  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_trending_colors;
  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_best_sellers;
  
  RETURN 'Analytics refreshed at ' || NOW()::text;
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION get_popular_brands TO authenticated, anon;
GRANT EXECUTE ON FUNCTION get_trending_colors TO authenticated, anon;
GRANT EXECUTE ON FUNCTION get_best_sellers TO authenticated, anon;
GRANT EXECUTE ON FUNCTION search_items TO authenticated, anon;
GRANT EXECUTE ON FUNCTION get_similar_items TO authenticated, anon;
GRANT EXECUTE ON FUNCTION refresh_analytics TO service_role;

-- Add comments
COMMENT ON FUNCTION get_popular_brands IS 'Get popular brands by sales (last 30 days)';
COMMENT ON FUNCTION get_trending_colors IS 'Get trending colors (last 7 days)';
COMMENT ON FUNCTION get_best_sellers IS 'Get best selling items';
COMMENT ON FUNCTION search_items IS 'Search items by attributes';
COMMENT ON FUNCTION get_similar_items IS 'Get similar items for recommendations';
COMMENT ON FUNCTION refresh_analytics IS 'Refresh materialized views';