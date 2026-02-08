-- CarSwap Online Marketplace - Supabase Schema
-- Run this in Supabase SQL Editor

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- LISTINGS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS listings (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  seller_id TEXT NOT NULL,
  seller_name TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  price INTEGER NOT NULL CHECK (price > 0),
  vehicle_model TEXT NOT NULL,
  vehicle_year INTEGER,
  vehicle_config JSONB NOT NULL,
  thumbnail_base64 TEXT,
  mileage BIGINT DEFAULT 0,
  condition INTEGER DEFAULT 100 CHECK (condition >= 0 AND condition <= 100),
  status TEXT DEFAULT 'available' CHECK (status IN ('available', 'pending', 'sold', 'expired', 'cancelled')),
  views INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '7 days')
);

-- Index for faster queries
CREATE INDEX IF NOT EXISTS idx_listings_status ON listings(status);
CREATE INDEX IF NOT EXISTS idx_listings_seller ON listings(seller_id);
CREATE INDEX IF NOT EXISTS idx_listings_model ON listings(vehicle_model);
CREATE INDEX IF NOT EXISTS idx_listings_price ON listings(price);
CREATE INDEX IF NOT EXISTS idx_listings_created ON listings(created_at DESC);

-- ============================================
-- TRANSACTIONS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS transactions (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  listing_id UUID REFERENCES listings(id),
  seller_id TEXT NOT NULL,
  buyer_id TEXT NOT NULL,
  buyer_name TEXT NOT NULL,
  price INTEGER NOT NULL,
  vehicle_model TEXT NOT NULL,
  vehicle_config JSONB NOT NULL,
  completed_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_transactions_seller ON transactions(seller_id);
CREATE INDEX IF NOT EXISTS idx_transactions_buyer ON transactions(buyer_id);

-- ============================================
-- SELLER PROFILES TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS seller_profiles (
  seller_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  total_sales INTEGER DEFAULT 0,
  total_earned BIGINT DEFAULT 0,
  rating_sum INTEGER DEFAULT 0,
  rating_count INTEGER DEFAULT 0,
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  last_active TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- RATINGS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS ratings (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  transaction_id UUID REFERENCES transactions(id),
  seller_id TEXT NOT NULL,
  buyer_id TEXT NOT NULL,
  rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ratings_seller ON ratings(seller_id);

-- ============================================
-- MESSAGES TABLE (Optional - for buyer-seller chat)
-- ============================================
CREATE TABLE IF NOT EXISTS messages (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  listing_id UUID REFERENCES listings(id),
  sender_id TEXT NOT NULL,
  sender_name TEXT NOT NULL,
  recipient_id TEXT NOT NULL,
  content TEXT NOT NULL,
  read BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_recipient ON messages(recipient_id, read);
CREATE INDEX IF NOT EXISTS idx_messages_listing ON messages(listing_id);

-- ============================================
-- WATCHLIST TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS watchlist (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id TEXT NOT NULL,
  listing_id UUID REFERENCES listings(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, listing_id)
);

-- ============================================
-- FUNCTIONS
-- ============================================

-- Function to update the updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for listings
DROP TRIGGER IF EXISTS listings_updated_at ON listings;
CREATE TRIGGER listings_updated_at
  BEFORE UPDATE ON listings
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- Function to increment view count
CREATE OR REPLACE FUNCTION increment_views(listing_uuid UUID)
RETURNS void AS $$
BEGIN
  UPDATE listings SET views = views + 1 WHERE id = listing_uuid;
END;
$$ LANGUAGE plpgsql;

-- Function to complete a sale
CREATE OR REPLACE FUNCTION complete_sale(
  p_listing_id UUID,
  p_buyer_id TEXT,
  p_buyer_name TEXT
)
RETURNS JSONB AS $$
DECLARE
  v_listing listings%ROWTYPE;
  v_transaction_id UUID;
BEGIN
  -- Get and lock the listing
  SELECT * INTO v_listing FROM listings WHERE id = p_listing_id FOR UPDATE;
  
  -- Check if available
  IF v_listing.status != 'available' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Listing not available');
  END IF;
  
  -- Update listing status
  UPDATE listings SET status = 'sold', updated_at = NOW() WHERE id = p_listing_id;
  
  -- Create transaction record
  INSERT INTO transactions (listing_id, seller_id, buyer_id, buyer_name, price, vehicle_model, vehicle_config)
  VALUES (p_listing_id, v_listing.seller_id, p_buyer_id, p_buyer_name, v_listing.price, v_listing.vehicle_model, v_listing.vehicle_config)
  RETURNING id INTO v_transaction_id;
  
  -- Update seller profile
  INSERT INTO seller_profiles (seller_id, display_name, total_sales, total_earned)
  VALUES (v_listing.seller_id, v_listing.seller_name, 1, v_listing.price)
  ON CONFLICT (seller_id) DO UPDATE SET
    total_sales = seller_profiles.total_sales + 1,
    total_earned = seller_profiles.total_earned + v_listing.price,
    last_active = NOW();
  
  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'vehicle_config', v_listing.vehicle_config,
    'price', v_listing.price,
    'seller_id', v_listing.seller_id
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Enable RLS on all tables
ALTER TABLE listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE seller_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE watchlist ENABLE ROW LEVEL SECURITY;

-- Policies for listings (game uses anon key; no auth.uid() - so allow with (true))
CREATE POLICY "Listings are viewable by everyone" ON listings
  FOR SELECT USING (true);

CREATE POLICY "Users can insert their own listings" ON listings
  FOR INSERT WITH CHECK (true);

CREATE POLICY "Users can update their own listings" ON listings
  FOR UPDATE USING (true);

-- Policies for transactions
CREATE POLICY "Users can view their transactions" ON transactions
  FOR SELECT USING (true);

CREATE POLICY "Anyone can create transactions" ON transactions
  FOR INSERT WITH CHECK (true);

-- Policies for seller_profiles (public read)
CREATE POLICY "Profiles are viewable by everyone" ON seller_profiles
  FOR SELECT USING (true);

CREATE POLICY "Anyone can update profiles" ON seller_profiles
  FOR ALL USING (true);

-- Policies for ratings
CREATE POLICY "Ratings are viewable by everyone" ON ratings
  FOR SELECT USING (true);

CREATE POLICY "Anyone can create ratings" ON ratings
  FOR INSERT WITH CHECK (true);

-- Policies for messages
CREATE POLICY "Users can view their messages" ON messages
  FOR SELECT USING (true);

CREATE POLICY "Anyone can send messages" ON messages
  FOR INSERT WITH CHECK (true);

CREATE POLICY "Anyone can update messages" ON messages
  FOR UPDATE USING (true);

-- Policies for watchlist
CREATE POLICY "Users can manage watchlist" ON watchlist
  FOR ALL USING (true);

