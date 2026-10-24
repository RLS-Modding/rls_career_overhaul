-- Audio duration and embedded cover probes for MP3, WAV, FLAC, Vorbis and Opus files.
-- Read byte ranges, ID3 and cover frames, MP3 frames and duration formats, then the cached duration API.
local M = {}

function M.create(normalizeAudioVfsPath, vfsPathTryList)
  -- Config ----------------------------------------------------------------------------------------

  local band = bit.band
  local rshift = bit.rshift
  local mp3L3BitrateMpeg1 = {
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0
  }
  local mp3L3BitrateMpeg2 = {
    0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0
  }
  local mp3SrMpeg1 = {44100, 48000, 32000}
  local mp3SrMpeg2 = {22050, 24000, 16000}
  local mp3SrMpeg25 = {11025, 12000, 8000}
  local mp3CoverCacheDir = 'settings/RLS/musicPlayerCovers/'
  local maxWholeFileFallbackBytes = 8388608
  local maxId3TagBytes = 32 * 1048576
  local maxTlenBodyBytes = 262144
  local maxCoverBodyBytes = 8 * 1048576
  local coverCacheExts = { 'jpg', 'png', 'webp' }

  -- State -----------------------------------------------------------------------------------------

  local noEmbeddedCover = {}
  local durationProbeCache = {}

  -- Binary reads ----------------------------------------------------------------------------------

  local function readFileBinaryRange(vfsPath, offset0, maxLen)
    local off = tonumber(offset0) or 0
    maxLen = tonumber(maxLen) or 0
    if maxLen < 1 then
      return nil
    end
    local norm = normalizeAudioVfsPath(vfsPath)
    if norm == '' then
      return nil
    end
    local paths = vfsPathTryList(vfsPath)
    local function tryRangeOnPath(path)
      if type(path) ~= 'string' or path == '' then
        return nil
      end
      local f = io.open(path, 'rb')
      if not f then
        return nil
      end
      if off > 0 then
        f:seek('set', off)
      end
      local data = f:read(maxLen)
      f:close()
      return data
    end
    for _, try in ipairs(paths) do
      local rp = FS:getFileRealPath(try)
      local data = tryRangeOnPath(rp)
      if data then
        return data
      end
    end
    local sz = FS:fileSize(norm) or FS:fileSize(paths[#paths])
    if sz and sz >= 1 and off >= 0 and off < sz and sz <= maxWholeFileFallbackBytes then
      for _, try in ipairs(paths) do
        local ok, whole = pcall(readFile, try)
        if ok and type(whole) == 'string' and #whole >= off + 1 then
          return whole:sub(off + 1, math.min(off + maxLen, #whole))
        end
      end
    end
    for _, try in ipairs(paths) do
      local data = tryRangeOnPath(try)
      if data then
        return data
      end
    end
    return nil
  end

  local function decodeSynchsafeU32(a, b, c, d)
    return band(a, 127) * 2097152 + band(b, 127) * 16384 + band(c, 127) * 128 + band(d, 127)
  end

  local function readU32BE(s, idx)
    local a, b, c, d = string.byte(s, idx, idx + 3)
    if not d then
      return nil
    end
    return a * 16777216 + b * 65536 + c * 256 + d
  end

  -- ID3 tags --------------------------------------------------------------------------------------

  local function id3v2LeadingBytes(vfsPath, fileSize)
    local sz = tonumber(fileSize) or 0
    local head = readFileBinaryRange(vfsPath, 0, 10)
    if not head or #head < 10 or head:sub(1, 3) ~= 'ID3' then
      return 0
    end
    local a, b, c, d = string.byte(head, 7, 10)
    local tagLen = 10 + decodeSynchsafeU32(a, b, c, d)
    if tagLen < 10 or tagLen > sz then
      return 0
    end
    if tagLen > maxId3TagBytes then
      return 0
    end
    return tagLen
  end

  local function id3v2TlenDurationSec(vfsPath)
    local sz = FS:fileSize(vfsPath)
    if not sz then
      return 0
    end
    local head = readFileBinaryRange(vfsPath, 0, 10)
    if not head or #head < 10 or head:sub(1, 3) ~= 'ID3' then
      return 0
    end
    local verMaj = string.byte(head, 4)
    if verMaj ~= 3 and verMaj ~= 4 then
      return 0
    end
    local tagLen = id3v2LeadingBytes(vfsPath, sz)
    if tagLen <= 10 then
      return 0
    end
    local bodyBytes = tagLen - 10
    local body = readFileBinaryRange(vfsPath, 10, math.min(bodyBytes, maxTlenBodyBytes))
    if not body or #body < 11 then
      return 0
    end
    local i = 1
    while i <= #body - 10 do
      local id = body:sub(i, i + 3)
      if id == '\0\0\0\0' then
        break
      end
      local a, b, c, d = string.byte(body, i + 4, i + 7)
      if not d then
        break
      end
      local frSz
      if verMaj == 4 then
        frSz = decodeSynchsafeU32(a, b, c, d)
      else
        frSz = a * 16777216 + b * 65536 + c * 256 + d
      end
      if frSz < 1 or frSz > bodyBytes * 2 or i + 10 + frSz - 1 > #body then
        break
      end
      if id == 'TLEN' then
        local raw = body:sub(i + 10, i + 9 + frSz)
        local ms = tonumber(raw:match('%d+'))
        if ms and ms > 0 then
          return ms / 1000
        end
      end
      i = i + 10 + frSz
    end
    return 0
  end

  -- Embedded covers -------------------------------------------------------------------------------

  local function imageExtFromMagic(img)
    if #img >= 3 and img:byte(1) == 255 and img:byte(2) == 216 and img:byte(3) == 255 then
      return 'jpg'
    end
    if #img >= 8 and img:sub(1, 8) == '\137PNG\r\n\26\n' then
      return 'png'
    end
    if #img >= 12 and img:sub(1, 4) == 'RIFF' and img:sub(9, 12) == 'WEBP' then
      return 'webp'
    end
    return 'jpg'
  end

  local function deunsyncBytes(data)
    if type(data) ~= 'string' or data == '' then
      return data
    end
    return (data:gsub('\255\0', '\255'))
  end

  local function skipPictureDescription(payload, enc, pos)
    if enc == 0 or enc == 3 then
      local z = payload:find('\0', pos, true)
      if not z then
        return nil
      end
      pos = z + 1
    elseif enc == 1 or enc == 2 then
      local z = pos
      local okSeek = false
      while z <= #payload - 1 do
        if payload:byte(z) == 0 and payload:byte(z + 1) == 0 then
          pos = z + 2
          okSeek = true
          break
        end
        z = z + 1
      end
      if not okSeek then
        return nil
      end
    else
      return nil
    end
    return pos
  end

  local function parseApicFramePayload(payload)
    if not payload or #payload < 20 then
      return nil, nil, nil
    end
    local enc = string.byte(payload, 1)
    local pos = 2
    local z = payload:find('\0', pos, true)
    if not z then
      return nil, nil, nil
    end
    local mime = payload:sub(pos, z - 1):lower()
    pos = z + 1
    if pos > #payload then
      return nil, nil, nil
    end
    local picType = string.byte(payload, pos)
    pos = pos + 1
    if pos > #payload then
      return nil, nil, nil
    end
    pos = skipPictureDescription(payload, enc, pos)
    if not pos then return nil, nil, nil end
    local img = payload:sub(pos)
    if #img < 32 then
      return nil, nil, nil
    end
    if mime == '-->' then
      return nil, nil, nil
    end
    local ext = 'jpg'
    if mime:find('png', 1, true) then
      ext = 'png'
    elseif mime:find('webp', 1, true) then
      ext = 'webp'
    elseif mime == '' then
      ext = imageExtFromMagic(img)
    end
    return img, ext, picType
  end

  local function parsePicFrameV22Payload(payload)
    if not payload or #payload < 20 then
      return nil, nil, nil
    end
    local enc = string.byte(payload, 1)
    local fmt = payload:sub(2, 4):lower()
    local picType = string.byte(payload, 5)
    local pos = 6
    pos = skipPictureDescription(payload, enc, pos)
    if not pos then return nil, nil, nil end
    local img = payload:sub(pos)
    if #img < 32 then
      return nil, nil, nil
    end
    local ext = 'jpg'
    if fmt == 'png' then
      ext = 'png'
    elseif fmt == 'jpg' then
      ext = 'jpg'
    else
      ext = imageExtFromMagic(img)
    end
    return img, ext, picType
  end

  local function hashPathForCoverCache(vfsPath, fileSize)
    local key = normalizeAudioVfsPath(vfsPath):lower()
    local h1, h2 = 5381, 0
    for i = 1, #key do
      local c = string.byte(key, i)
      h1 = (h1 * 33 + c) % 4294967296
      h2 = (h2 * 65599 + c) % 4294967296
    end
    return string.format('%08x%08x_%d', h1, h2, tonumber(fileSize) or 0)
  end

  local function writeBinaryFile(paths, bytes)
    if type(bytes) ~= 'string' or bytes == '' then
      return false
    end
    local candidates = type(paths) == 'table' and paths or { paths }
    for _, p in ipairs(candidates) do
      if type(p) == 'string' and p ~= '' then
        local f = io.open(p, 'wb')
        if f then
          f:write(bytes)
          f:close()
          return true
        end
      end
    end
    return false
  end

  local function joinPath(a, b)
    a = type(a) == 'string' and a or ''
    b = type(b) == 'string' and b or ''
    if a == '' then
      return b
    end
    if b == '' then
      return a
    end
    a = a:gsub('\\', '/')
    b = b:gsub('\\', '/')
    if a:sub(-1) ~= '/' then
      a = a .. '/'
    end
    return a .. b:gsub('^/+', '')
  end

  local function cacheEmbeddedCoverToSettings(cacheBase, img, ext)
    if not FS:directoryExists(mp3CoverCacheDir) then
      FS:directoryCreate(mp3CoverCacheDir, true)
    end
    local rel = mp3CoverCacheDir .. cacheBase .. '.' .. ext
    if FS:fileExists(rel) then
      return rel
    end
    local userPath = FS:getUserPath() or ''
    local rp = userPath ~= '' and joinPath(userPath, rel) or nil
    if rp and writeBinaryFile(rp, img) then
      return rel
    end
    return nil
  end

  local function readMp3CoverBody(vfsPath, fileSize)
    local head = readFileBinaryRange(vfsPath, 0, 10)
    if not head or #head < 10 or head:sub(1, 3) ~= 'ID3' then
      return nil
    end
    local verMaj = string.byte(head, 4)
    if verMaj ~= 2 and verMaj ~= 3 and verMaj ~= 4 then
      return nil
    end
    local hdrFlags = string.byte(head, 6) or 0
    local tagLen = id3v2LeadingBytes(vfsPath, fileSize)
    if tagLen <= 10 then
      return nil
    end
    local bodyBytes = tagLen - 10
    local maxRead = math.min(bodyBytes, maxCoverBodyBytes)
    local body = readFileBinaryRange(vfsPath, 10, maxRead)
    if not body or #body < 20 then
      return nil
    end
    if band(hdrFlags, 128) ~= 0 then
      body = deunsyncBytes(body)
    end
    return body, verMaj, bodyBytes
  end

  local function readCoverFrameHeader(body, i, verMaj)
    local id
    local frSz
    local headerLen
    if verMaj == 2 then
      id = body:sub(i, i + 2)
      if id == '\0\0\0' then
        return nil
      end
      local a, b, c = string.byte(body, i + 3, i + 5)
      if not c then
        return nil
      end
      frSz = a * 65536 + b * 256 + c
      headerLen = 6
    else
      id = body:sub(i, i + 3)
      if id == '\0\0\0\0' then
        return nil
      end
      local a, b, c, d = string.byte(body, i + 4, i + 7)
      if not d then
        return nil
      end
      if verMaj == 4 then
        frSz = decodeSynchsafeU32(a, b, c, d)
      else
        frSz = a * 16777216 + b * 65536 + c * 256 + d
      end
      headerLen = 10
    end
    return id, frSz, headerLen
  end

  local function selectEmbeddedCover(body, verMaj, bodyBytes)
    local i = 1
    local bestImg, bestExt, bestPri = nil, nil, 999
    while i <= #body - 6 do
      local id, frSz, headerLen = readCoverFrameHeader(body, i, verMaj)
      if not id then break end
      if frSz < 1 or frSz > bodyBytes * 2 then
        break
      end
      if i + headerLen + frSz - 1 > #body then
        break
      end
      if id == 'APIC' or (verMaj == 2 and id == 'PIC') then
        local payload = body:sub(i + headerLen, i + headerLen + frSz - 1)
        local img, ext, picType
        if verMaj == 2 then
          img, ext, picType = parsePicFrameV22Payload(payload)
        else
          img, ext, picType = parseApicFramePayload(payload)
        end
        if img and ext then
          local pri = (picType == 3) and 0 or 1
          if pri < bestPri then
            bestPri = pri
            bestImg = img
            bestExt = ext
          end
        end
      end
      i = i + headerLen + frSz
    end
    return bestImg, bestExt
  end

  local function extractEmbeddedMp3CoverVfsPath(vfsPath)
    local norm = normalizeAudioVfsPath(vfsPath)
    if norm:lower():sub(-4) ~= '.mp3' then
      return nil
    end
    local sz = FS:fileSize(norm)
    if not sz or sz < 32 then
      return nil
    end
    local cacheBase = hashPathForCoverCache(norm, sz)
    for _, ext in ipairs(coverCacheExts) do
      local cached = mp3CoverCacheDir .. cacheBase .. '.' .. ext
      if FS:fileExists(cached) then
        return cached
      end
    end
    if noEmbeddedCover[cacheBase] then
      return nil
    end
    local body, verMaj, bodyBytes = readMp3CoverBody(norm, sz)
    if not body then return nil end
    local bestImg, bestExt = selectEmbeddedCover(body, verMaj, bodyBytes)
    local found = nil
    if bestImg and bestExt then
      found = cacheEmbeddedCoverToSettings(cacheBase, bestImg, bestExt)
    end
    if not found then
      noEmbeddedCover[cacheBase] = true
    end
    return found
  end

  -- MP3 frames ------------------------------------------------------------------------------------

  local function parseMp3L3FrameHeader(data, i)
    local b1, b2, b3, b4 = string.byte(data, i, i + 3)
    if not b4 or b1 ~= 0xFF or band(b2, 0xE0) ~= 0xE0 or band(b2, 0x06) == 0 then
      return nil
    end
    local verId = band(rshift(b2, 3), 3)
    local layerId = band(rshift(b2, 1), 3)
    if layerId ~= 1 then
      return nil
    end
    local sampleRates, bitrates, samplesPerFrame, scale, mpeg = nil, nil, nil, nil, nil
    if verId == 3 then
      mpeg = '1'
      sampleRates = mp3SrMpeg1
      bitrates = mp3L3BitrateMpeg1
      samplesPerFrame = 1152
      scale = 144
    elseif verId == 2 then
      mpeg = '2'
      sampleRates = mp3SrMpeg2
      bitrates = mp3L3BitrateMpeg2
      samplesPerFrame = 576
      scale = 72
    elseif verId == 0 then
      mpeg = '25'
      sampleRates = mp3SrMpeg25
      bitrates = mp3L3BitrateMpeg2
      samplesPerFrame = 576
      scale = 72
    else
      return nil
    end
    local brIdx = band(rshift(b3, 4), 15)
    local srIdx = band(rshift(b3, 2), 3)
    local padding = band(rshift(b3, 1), 1)
    if brIdx == 0 or brIdx == 15 or srIdx == 3 then
      return nil
    end
    local bitrateKbps = bitrates[brIdx + 1]
    if not bitrateKbps or bitrateKbps <= 0 then
      return nil
    end
    local sampleRate = sampleRates[srIdx + 1]
    if not sampleRate or sampleRate <= 0 then
      return nil
    end
    local frameLen = math.floor(scale * bitrateKbps * 1000 / sampleRate + padding)
    if frameLen < 24 then
      return nil
    end
    local mode = band(rshift(b4, 6), 3)
    local sideInfo = (mpeg == '1') and ((mode == 3) and 17 or 32) or ((mode == 3) and 9 or 17)
    return {
      frameLen = frameLen,
      bitrateKbps = bitrateKbps,
      sampleRate = sampleRate,
      samplesPerFrame = samplesPerFrame,
      sideInfo = sideInfo
    }
  end

  local function findMp3Frame(data, requireNextFrame)
    local lim = #data - 4
    for try = 1, lim do
      local b1, b2 = string.byte(data, try, try + 1)
      if b1 == 0xFF and b2 and band(b2, 0xE0) == 0xE0 and band(b2, 0x06) ~= 0 then
        local frame = parseMp3L3FrameHeader(data, try)
        if frame then
          local ni = try + frame.frameLen
          if not requireNextFrame then return frame, try end
          if ni <= lim then
            local nb1, nb2 = string.byte(data, ni, ni + 1)
            if nb1 == 0xFF and nb2 and band(nb2, 0xE0) == 0xE0 then
              return frame, try
            end
          end
        end
      end
    end
    return nil, 1
  end

  local function durationFromVbrHeaders(data, hdr, fi)
    local xi = fi + 4 + hdr.sideInfo
    if xi + 11 <= #data then
      local tag = data:sub(xi, xi + 3)
      if tag == 'Xing' or tag == 'Info' then
        local flags = readU32BE(data, xi + 4) or 0
        if band(flags, 1) ~= 0 and xi + 12 <= #data then
          local fn = readU32BE(data, xi + 8)
          if fn and fn > 0 then
            return fn * hdr.samplesPerFrame / hdr.sampleRate
          end
        end
      end
    end
    local vend = math.min(fi + hdr.frameLen + 32, #data - 17)
    local vscan = fi + 1
    while vscan <= vend do
      local hit = data:find('VBRI', vscan, true)
      if not hit then
        break
      end
      if hit + 17 <= #data then
        local fn = readU32BE(data, hit + 14)
        if fn and fn > 0 then
          return fn * hdr.samplesPerFrame / hdr.sampleRate
        end
      end
      vscan = hit + 4
    end
    return nil
  end

  local function mp3DurationSecFromFile(vfsPath)
    local fileSize = FS:fileSize(vfsPath)
    if not fileSize or fileSize < 1 then
      return 0
    end
    local tlenSec = id3v2TlenDurationSec(vfsPath)
    if tlenSec > 0 then
      return tlenSec
    end
    if fileSize < 64 then
      return 0
    end
    local id3 = id3v2LeadingBytes(vfsPath, fileSize)
    local readLen = math.min(524288, fileSize - id3)
    if readLen < 64 then
      return 0
    end
    local data = readFileBinaryRange(vfsPath, id3, readLen)
    if not data or #data < 64 then
      return 0
    end
    local hdr, fi = findMp3Frame(data, true)
    if not hdr then hdr, fi = findMp3Frame(data, false) end
    if not hdr then return 0 end
    local vbrDurationSec = durationFromVbrHeaders(data, hdr, fi)
    if vbrDurationSec then return vbrDurationSec end
    local id3v1 = 0
    if fileSize >= 128 then
      local tail = readFileBinaryRange(vfsPath, fileSize - 128, 128)
      if tail and #tail >= 3 and tail:sub(1, 3) == 'TAG' then
        id3v1 = 128
      end
    end
    local audioBytes = fileSize - id3 - id3v1
    if audioBytes <= 0 or hdr.bitrateKbps <= 0 then
      return 0
    end
    return audioBytes * 8 / (hdr.bitrateKbps * 1000)
  end
  -- Other audio formats ---------------------------------------------------------------------------

  local function wavDurationSecFromFile(vfsPath)
    local sz = FS:fileSize(vfsPath)
    if not sz or sz < 44 then
      return 0
    end
    local data = readFileBinaryRange(vfsPath, 0, math.min(65536, sz))
    if not data or #data < 44 or data:sub(1, 4) ~= 'RIFF' or data:sub(9, 12) ~= 'WAVE' then
      return 0
    end
    local i = 13
    local byteRate = nil
    while i <= #data - 8 do
      local id = data:sub(i, i + 3)
      local cs = string.byte(data, i + 4) + string.byte(data, i + 5) * 256 + string.byte(data, i + 6) * 65536 + string.byte(data, i + 7) * 16777216
      if id == 'fmt ' and cs >= 16 and i + 8 + cs <= #data then
        local ch = string.byte(data, i + 11) + string.byte(data, i + 10) * 256
        local sr = string.byte(data, i + 15) + string.byte(data, i + 14) * 256 + string.byte(data, i + 13) * 65536 + string.byte(data, i + 12) * 16777216
        local bitsPer = string.byte(data, i + 17) + string.byte(data, i + 16) * 256
        if sr > 0 and ch > 0 and bitsPer > 0 then
          byteRate = sr * ch * (bitsPer / 8)
        end
      elseif id == 'data' and byteRate and byteRate > 0 then
        return cs / byteRate
      end
      i = i + 8 + cs + (cs % 2)
    end
    return 0
  end

  local function readUIntLE(s, idx, n)
    local v = 0
    for k = n - 1, 0, -1 do
      local b = string.byte(s, idx + k)
      if not b then
        return nil
      end
      v = v * 256 + b
    end
    return v
  end

  local function flacDurationSecFromFile(vfsPath)
    local sz = FS:fileSize(vfsPath)
    if not sz or sz < 42 then
      return 0
    end
    local start = id3v2LeadingBytes(vfsPath, sz)
    local data = readFileBinaryRange(vfsPath, start, 42)
    if not data or #data < 42 or data:sub(1, 4) ~= 'fLaC' then
      return 0
    end
    -- First metadata block must be STREAMINFO (type 0).
    if band(string.byte(data, 5), 127) ~= 0 then
      return 0
    end
    local d = 9
    local b10, b11, b12, b13 = string.byte(data, d + 10, d + 13)
    local sampleRate = b10 * 4096 + b11 * 16 + math.floor(b12 / 16)
    local totalSamples = (b13 % 16) * 4294967296 + (readU32BE(data, d + 14) or 0)
    if sampleRate <= 0 or totalSamples <= 0 then
      return 0
    end
    return totalSamples / sampleRate
  end

  local function oggDurationSecFromFile(vfsPath)
    local sz = FS:fileSize(vfsPath)
    if not sz or sz < 64 then
      return 0
    end
    local head = readFileBinaryRange(vfsPath, 0, math.min(4096, sz))
    if not head or head:sub(1, 4) ~= 'OggS' then
      return 0
    end
    local sampleRate, preSkip = nil, 0
    local v = head:find('\1vorbis', 1, true)
    if v then
      sampleRate = readUIntLE(head, v + 12, 4)
    else
      local o = head:find('OpusHead', 1, true)
      if o then
        -- Opus granule positions always count 48 kHz samples.
        sampleRate = 48000
        preSkip = readUIntLE(head, o + 10, 2) or 0
      end
    end
    if not sampleRate or sampleRate <= 0 then
      return 0
    end
    local tailLen = math.min(65536, sz)
    local tail = readFileBinaryRange(vfsPath, sz - tailLen, tailLen)
    if not tail then
      return 0
    end
    local pos = #tail - 13
    while pos >= 1 do
      local hit = nil
      local search = 1
      while true do
        local h = tail:find('OggS', search, true)
        if not h or h > pos then break end
        hit = h
        search = h + 1
      end
      if not hit then
        break
      end
      local granule = readUIntLE(tail, hit + 6, 8)
      -- 0xFFFFFFFFFFFFFFFF means no packet ends on this page.
      if granule and granule > 0 and granule < 2 ^ 53 then
        local samples = granule - preSkip
        if samples > 0 then
          return samples / sampleRate
        end
      end
      pos = hit - 1
    end
    return 0
  end

  -- Duration cache --------------------------------------------------------------------------------

  local function durationSecFromFmodPlayOnce(vfsPath)
    if type(vfsPath) ~= 'string' or vfsPath == '' then
      return 0
    end
    local key = normalizeAudioVfsPath(vfsPath)
    if key == '' then
      return 0
    end
    local cached = durationProbeCache[key]
    if cached then
      return cached
    end
    if key:sub(1, 6) == 'event:' then
      return 0
    end
    local tryPlay = FS:fileExists(key) and key or vfsPath
    if not FS:fileExists(tryPlay) then
      return 0
    end
    local res = Engine.Audio.playOnce('AudioGui', tryPlay, { volume = 0, pitch = 1 })
    if type(res) == 'table' then
      local len = tonumber(res.len) or 0
      if len > 0 then
        durationProbeCache[key] = len
        return len
      end
    end
    return 0
  end

  local function estimateTrackDurationSec(vfsPath)
    if type(vfsPath) ~= 'string' then
      return 0
    end
    local norm = normalizeAudioVfsPath(vfsPath)
    local lower = norm:lower()
    if lower:sub(-4) == '.mp3' then
      local d = mp3DurationSecFromFile(norm)
      if d > 0 then
        return d
      end
      return durationSecFromFmodPlayOnce(norm)
    end
    if lower:sub(-4) == '.wav' then
      return wavDurationSecFromFile(norm)
    end
    if lower:sub(-4) == '.ogg' then
      return oggDurationSecFromFile(norm)
    end
    if lower:sub(-5) == '.flac' then
      return flacDurationSecFromFile(norm)
    end
    return 0
  end

  -- Public API ------------------------------------------------------------------------------------

  return {
    estimateTrackDurationSec = estimateTrackDurationSec,
    extractEmbeddedMp3CoverVfsPath = extractEmbeddedMp3CoverVfsPath,
  }
end

return M
