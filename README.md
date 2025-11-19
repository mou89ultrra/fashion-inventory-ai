# fashion-inventory-ai
# Fashion Inventory AI

AI-powered fashion inventory management system with OCR, brand detection, color analysis, and intelligent recommendations.

## Features
- 🤖 GPT-4o-mini OCR for price tags
- 🎨 AI Vision for brand/color/style detection
- 📊 Analytics & trending insights
- 💬 AI Messenger for recommendations
- 📦 Inventory management

## Database Schema
See `database/migrations/` for schema changes.

## RPC Functions
- `get_popular_brands()` - Popular brands by sales
- `search_items()` - Search by attributes
- `get_similar_items()` - Recommendations
- `refresh_analytics()` - Refresh views

## Tech Stack
- **Database:** Supabase (PostgreSQL)
- **Automation:** n8n
- **AI:** GPT-4o-mini, OpenAI Vision
- **Storage:** Cloudinary, Supabase Storage
- **Messenger:** Telegram

## Author
mou89ultrrado

## Date
2025-11-18 23:48:53 UTC
