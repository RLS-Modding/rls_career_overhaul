# CarSwap Online Marketplace - Setup Guide

## Step 1: Create Supabase Account (Free)

1. Go to https://supabase.com
2. Click "Start your project" → Sign up with GitHub or Email
3. Create a new project:
   - Name: `carswap-marketplace`
   - Database Password: (save this somewhere safe!)
   - Region: Choose closest to your users
4. Wait ~2 minutes for project to provision

## Step 2: Get Your API Keys

1. In Supabase dashboard, go to **Settings** → **API**
2. Copy these two values:
   - `Project URL` (looks like: `https://xxxxx.supabase.co`)
   - `anon public` key (long string starting with `eyJ...`)

3. Create a file in your mod: `lua/ge/extensions/gameplay/carswap/config.lua`
   ```lua
   return {
     SUPABASE_URL = "https://YOUR_PROJECT_ID.supabase.co",
     SUPABASE_ANON_KEY = "YOUR_ANON_KEY_HERE"
   }
   ```

## Step 3: Create Database Tables

1. In Supabase dashboard, go to **SQL Editor**
2. Click "New Query"
3. Paste the contents of `carswap_schema.sql` (included in this mod)
4. Click "Run"

## Step 4: Enable Row Level Security (RLS)

The schema already includes RLS policies, but verify:
1. Go to **Table Editor**
2. Click on `listings` table
3. Ensure RLS is enabled (shield icon should be green)

## Step 5: Test the Connection

1. Start BeamNG with the mod
2. Open phone → CarSwap app
3. Should see "Connected to CarSwap!" or similar

---

## Troubleshooting

### "Failed to connect"
- Check your SUPABASE_URL and SUPABASE_ANON_KEY are correct
- Ensure no extra spaces or newlines in the keys

### "Unauthorized"
- Your anon key may have expired or been regenerated
- Get fresh keys from Supabase dashboard

### "Network error"
- BeamNG may be blocking HTTP requests
- Check firewall/antivirus settings

---

## Database Schema Overview

### `listings` table
- `id` - Unique listing ID
- `seller_id` - Steam ID or unique player ID
- `seller_name` - Display name
- `title` - Listing title
- `description` - Full description
- `price` - Asking price
- `vehicle_model` - BeamNG model name
- `vehicle_config` - Full vehicle configuration (JSON)
- `thumbnail_url` - Image URL (optional)
- `mileage` - Vehicle mileage
- `condition` - 0-100 condition percentage
- `status` - available, sold, expired
- `created_at` - When listed
- `updated_at` - Last update

### `transactions` table
- Records of all completed sales

### `messages` table
- Buyer-seller communication

### `ratings` table
- Seller ratings and reviews

