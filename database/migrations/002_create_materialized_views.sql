-- Create materialized views for analytics
DROP MATERIALIZED VIEW IF EXISTS mv_popular_brands;
DROP MATERIALIZED VIEW IF EXISTS mv_trending_colors;
DROP MATERIALIZED VIEW IF EXISTS mv_best_sellers;

CREATE MATERIALIZED VIEW mv_popular_brands AS
SELECT 
  soi.brand,
  soi.gender_segment,
  COUNT(*) as sales_count,
  SUM(soi.qty) as total_qty_sold,
  AVG(soi.unit_price) as avg_price,
  ARRAY_AGG(DISTINCT soi.primary_color) as popular_colors,
  MAX(so.created_at) as last_sale_date
FROM sales_order_items soi
JOIN sales_orders so ON soi.order_id = so.id
WHERE so.created_at > NOW() - INTERVAL '30 days'
  AND so.status IN ('approved', 'delivered')
  AND soi.brand IS NOT NULL
GROUP BY soi.brand, soi.gender_segment
ORDER BY sales_count DESC;

CREATE UNIQUE INDEX ON mv_popular_brands(brand, gender_segment);

CREATE MATERIALIZED VIEW mv_trending_colors AS
SELECT 
  soi.primary_color,
  soi.gender_segment,
  COUNT(*) as sales_count,
  SUM(soi.qty) as total_qty_sold,
  AVG(soi.unit_price) as avg_price,
  ARRAY_AGG(DISTINCT soi.brand) as brands_in_this_color
FROM sales_order_items soi
JOIN sales_orders so ON soi.order_id = so.id
WHERE so.created_at > NOW() - INTERVAL '7 days'
  AND so.status IN ('approved', 'delivered')
  AND soi.primary_color IS NOT NULL
GROUP BY soi.primary_color, soi.gender_segment
ORDER BY sales_count DESC;

CREATE UNIQUE INDEX ON mv_trending_colors(primary_color, gender_segment);

CREATE MATERIALIZED VIEW mv_best_sellers AS
SELECT 
  soi.piece_id,
  soi.brand,
  soi.primary_color,
  soi.style,
  soi.category_name,
  soi.gender_segment,
  COUNT(*) as times_sold,
  SUM(soi.qty) as total_qty_sold,
  AVG(soi.unit_price) as avg_price,
  MAX(so.created_at) as last_sold_at
FROM sales_order_items soi
JOIN sales_orders so ON soi.order_id = so.id
WHERE so.created_at > NOW() - INTERVAL '30 days'
  AND so.status IN ('approved', 'delivered')
GROUP BY soi.piece_id, soi.brand, soi.primary_color, soi.style, soi.category_name, soi.gender_segment
ORDER BY times_sold DESC
LIMIT 100;

CREATE UNIQUE INDEX ON mv_best_sellers(piece_id);