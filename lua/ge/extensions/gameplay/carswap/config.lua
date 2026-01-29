-- CarSwap Marketplace Configuration
-- Replace these values with your Supabase project details

return {
  -- Get these from: Supabase Dashboard → Settings → API
  SUPABASE_URL = "https://vehfqsnxuzpwcotnmtga.supabase.co",  -- e.g., "https://abcdefgh.supabase.co"
  SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZlaGZxc254dXpwd2NvdG5tdGdhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk2ODA4NjgsImV4cCI6MjA4NTI1Njg2OH0.RxExzubDweXpNjO5DWvf1fX2oY02mY7OOQxY3eOgZ5A",  -- e.g., "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
  
  -- Marketplace settings
  LISTING_DURATION_DAYS = 7,  -- How long listings stay active
  MAX_ACTIVE_LISTINGS = 10,   -- Max listings per user
  MIN_PRICE = 100,            -- Minimum listing price
  MAX_PRICE = 50000000,       -- Maximum listing price (50 million)
  
  -- Thumbnail settings
  ENABLE_THUMBNAILS = true,
  MAX_THUMBNAIL_SIZE = 50000,  -- Max base64 size (bytes)
  
  -- Cache settings
  CACHE_DURATION = 60,  -- Seconds to cache listings
  
  -- API settings
  REQUEST_TIMEOUT = 10,  -- Seconds
  
  -- Feature flags
  ENABLE_MESSAGES = true,
  ENABLE_RATINGS = true,
  ENABLE_WATCHLIST = true
}

