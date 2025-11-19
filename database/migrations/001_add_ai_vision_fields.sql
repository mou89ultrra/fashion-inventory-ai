-- Add AI Vision fields to all tables
BEGIN;

ALTER TABLE ocr_logs
  ADD COLUMN IF NOT EXISTS brand text,
  ADD COLUMN IF NOT EXISTS primary_color text,
  ADD COLUMN IF NOT EXISTS secondary_colors text[],
  ADD COLUMN IF NOT EXISTS style text,
  ADD COLUMN IF NOT EXISTS pattern text,
  ADD COLUMN IF NOT EXISTS code_exists boolean DEFAULT false;

ALTER TABLE pieces
  ADD COLUMN IF NOT EXISTS brand text,
  ADD COLUMN IF NOT EXISTS primary_color text,
  ADD COLUMN IF NOT EXISTS secondary_colors text[],
  ADD COLUMN IF NOT EXISTS style text,
  ADD COLUMN IF NOT EXISTS pattern text;

ALTER TABLE sales_order_items
  ADD COLUMN IF NOT EXISTS brand text,
  ADD COLUMN IF NOT EXISTS primary_color text,
  ADD COLUMN IF NOT EXISTS secondary_colors text[],
  ADD COLUMN IF NOT EXISTS style text,
  ADD COLUMN IF NOT EXISTS pattern text,
  ADD COLUMN IF NOT EXISTS category_name text,
  ADD COLUMN IF NOT EXISTS grade text,
  ADD COLUMN IF NOT EXISTS gender_segment text;

ALTER TABLE inventory_movements
  ADD COLUMN IF NOT EXISTS brand text,
  ADD COLUMN IF NOT EXISTS primary_color text,
  ADD COLUMN IF NOT EXISTS secondary_colors text[],
  ADD COLUMN IF NOT EXISTS style text,
  ADD COLUMN IF NOT EXISTS pattern text,
  ADD COLUMN IF NOT EXISTS category_name text,
  ADD COLUMN IF NOT EXISTS grade text,
  ADD COLUMN IF NOT EXISTS movement_reason text;

CREATE INDEX IF NOT EXISTS idx_pieces_brand ON pieces(brand);
CREATE INDEX IF NOT EXISTS idx_pieces_primary_color ON pieces(primary_color);
CREATE INDEX IF NOT EXISTS idx_sales_order_items_brand ON sales_order_items(brand);
CREATE INDEX IF NOT EXISTS idx_sales_order_items_primary_color ON sales_order_items(primary_color);

COMMIT;