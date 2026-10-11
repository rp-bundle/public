---The item catalog and item images on the player's client (P3, #243).
---
---A client has no config snapshot: what it knows of items it reads from the
---portal's player API with its API token (`rpf.auth`), the server's
---effective catalog, public fields only (`GET /api/v1/player/items`). This
---module keeps that catalog, revalidated with its `ETag`, and fetches an
---item's image by slug through the platform's `item_image`, so an addon's
---UI draws an item's icon in one call instead of handling the token, the
---redirect and the cache itself.
---
---**Images are kept by content hash.** The catalog names each image by the
---SHA-256 of its bytes, which changes exactly when the image does, so a
---hash fetched once is never fetched again (the adapter keeps it on disk,
---checked against the hash), and a changed image is a new hash, fetched
---once. The URL fetched is the catalog's `image_url`, which carries the
---hash, so the portal refuses it (`404`) once the image is replaced rather
---than sending the new one under the old hash; the answer to that is to
---revalidate the catalog and ask again, once.
---
---What an image is depends on the engine, and only the adapter knows it:
---`src` is a `data:` URL on FiveM, for an `<img>` in any resource's page or
---ox_lib's `image` and `icon`, and a path for `Material()` on Gmod. The
---core never looks inside it.
---
---Nothing here throws: a call that cannot answer calls back with nil and a
---reason, and a callback that throws is logged.
---@class rpf.items
---@field CATALOG_FRESH_MS integer How long a fetched catalog is used before it is revalidated (a `304` when nothing changed).
---@field TIMEOUT_MS integer How long a catalog request or an image fetch may take before it counts as failed, so a page that reloads mid-fetch or an engine that never answers cannot leave a caller waiting for ever.
---@field MAX_IMAGES integer How many images the core keeps in memory, oldest dropped first. The adapter's own cache on disk is what spares a fetch; this spares the trip to it.
---@field CATALOG_PATH string The catalog's path under the portal's address.
local items = {}

local rpf = rpf
local json = rpf.json

items.CATALOG_FRESH_MS = 60 * 1000
items.TIMEOUT_MS = 60 * 1000
items.MAX_IMAGES = 256
items.CATALOG_PATH = "/api/v1/player/items"

---@type rpf.ClientPlatform?
local platform = nil

---The catalog as last fetched, for the portal and server it came from.
---@class rpf.items.Kept
---@field context string The portal address and server id it was fetched for: another login elsewhere is another catalog.
---@field etag string? Its `ETag`, sent back as `If-None-Match`.
---@field fetched_at number When it was last fetched or revalidated, by the platform's clock.
---@field catalog rpf.items.Catalog What it says.

---@type rpf.items.Kept?
local kept = nil

---Callbacks waiting for the catalog request in flight, if one is.
---@type fun(catalog: rpf.items.Catalog?, err: string?)[]?
local catalog_waiting = nil

---Bumped by `start`, so an answer to a request made before it is ignored.
local generation = 0

---Images fetched this session: `src` by hash.
---@type table<string, string>
local images = {}

---The hashes in `images`, oldest first, for dropping past `MAX_IMAGES`.
---@type string[]
local image_order = {}

---Callbacks waiting for an image fetch in flight, by hash.
---@type table<string, fun(src: string?, err: string?)[]>
local loading = {}

---Logs with the core's prefix.
---@param level "debug"|"info"|"warn"|"error" How much it matters.
---@param message string The line.
local function log(level, message)
  if platform then
    platform.log(level, "rpf: " .. message)
  end
end

---Calls a script's callback, logging a throw.
---@param callback function The callback.
---@param ... any What it is called with.
local function deliver(callback, ...)
  local ran, thrown = pcall(callback, ...)
  if not ran then
    log("error", "an items callback failed: " .. tostring(thrown))
  end
end

---Wraps a callback so it runs at most once, and once anyway after
---`TIMEOUT_MS` with `timeout_err`.
---@param timeout_err string What the callback is given if time runs out.
---@param fn fun(...) The callback.
---@return fun(...) once The wrapped callback.
local function once_or_timeout(timeout_err, fn)
  local done = false
  ---Runs the callback, the first time only.
  ---@param ... any What it is called with.
  local function finish(...)
    if done then
      return
    end
    done = true
    fn(...)
  end
  assert(platform).after(items.TIMEOUT_MS, function()
    if not done then
      log("warn", "a portal request for items took too long; giving up on it")
      finish(nil, timeout_err)
    end
  end)
  return finish
end

---A header from a response, whatever case the engine gave its name in.
---@param headers table<string, string>? The headers.
---@param name string The name, lowercase.
---@return string? value The value.
local function header(headers, name)
  for key, value in pairs(headers or {}) do
    if type(key) == "string" and key:lower() == name and type(value) == "string" then
      return value
    end
  end
  return nil
end

---Whether a value is a content hash as the portal writes one: 64 lowercase
---hex digits.
---@param value any The value.
---@return boolean ok Whether it is.
local function is_hash(value)
  return type(value) == "string" and #value == 64 and value:find("^[0-9a-f]+$") ~= nil
end

---A whole number at least `low`, or nil.
---@param value any The value.
---@param low integer The least it may be.
---@return integer? n The number.
local function whole(value, low)
  if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < low or value >= 2 ^ 53 then
    return nil
  end
  return value
end

---One item's public definition, read from the portal's answer, or nil if
---it is not one. An image whose hash or path is not what the portal writes
---is left out rather than fetched: only the catalog's own path, with its
---hash, is ever asked for.
---@param raw any The entry.
---@return rpf.PlayerItem? item The item.
---@return string? image_url Its image's path under the portal's address.
local function read_item(raw)
  if not json.is_object(raw) or not json.is_object(raw.size) then
    return nil
  end
  local weight, stack_limit = whole(raw.weight, -2 ^ 31), whole(raw.stack_limit, 0)
  local x, y = whole(raw.size.x, 0), whole(raw.size.y, 0)
  if not weight or not stack_limit or not x or not y then
    return nil
  end
  ---@type rpf.PlayerItem
  local item = { weight = weight, size = { x = x, y = y }, stack_limit = stack_limit }
  local url = raw.image_url
  if
    is_hash(raw.image)
    and type(url) == "string"
    and url:sub(1, #items.CATALOG_PATH + 1) == items.CATALOG_PATH .. "/"
    and url:sub(-(#raw.image + 3)) == "?v=" .. raw.image
  then
    item.image = raw.image
    return item, url
  end
  return item, nil
end

---The catalog as the portal sent it, checked, or nil if it is not one.
---@param text string The response body.
---@return rpf.items.Catalog? catalog The catalog, each entry's image path kept beside it.
local function read_catalog(text)
  local body = json.decode(text)
  if not json.is_object(body) or not json.is_object(body.items) then
    return nil
  end
  local defaults = read_item(body.defaults)
  if not defaults then
    return nil
  end
  defaults.image = nil
  ---@type rpf.items.Catalog
  local catalog = { defaults = defaults, items = {}, urls = {} }
  for slug, raw in pairs(body.items) do
    local item, url = read_item(raw)
    if type(slug) == "string" and item then
      catalog.items[slug] = item
      catalog.urls[slug] = url
    end
  end
  return catalog
end

---A copy of one item, as handed to a script.
---@param item rpf.PlayerItem The item.
---@return rpf.PlayerItem copy The copy.
local function copy_item(item)
  return {
    weight = item.weight,
    size = { x = item.size.x, y = item.size.y },
    stack_limit = item.stack_limit,
    image = item.image,
  }
end

---Runs every callback waiting for the catalog.
---@param catalog rpf.items.Catalog? The catalog.
---@param err string? Why there is none.
local function catalog_done(catalog, err)
  local waiting = catalog_waiting or {}
  catalog_waiting = nil
  for _, callback in ipairs(waiting) do
    callback(catalog, err)
  end
end

---Calls back with the catalog: the one kept while it is fresh, else one
---fetched or revalidated now. One request at a time; callers meanwhile wait
---for it.
---@param force boolean Revalidate even a fresh one.
---@param callback fun(catalog: rpf.items.Catalog?, err: string?) Called once.
local function with_catalog(force, callback)
  local p = platform
  if not p then
    callback(nil, "unavailable")
    return
  end
  local portal_url, server_id = rpf.auth.portal()
  local token = rpf.auth.api_token()
  if not portal_url or not server_id or not token then
    callback(nil, "not_logged_in")
    return
  end
  local context = portal_url .. "\n" .. server_id
  if kept and kept.context ~= context then
    kept = nil
  end
  if kept and not force and p.now() - kept.fetched_at < items.CATALOG_FRESH_MS then
    callback(kept.catalog, nil)
    return
  end
  if catalog_waiting then
    catalog_waiting[#catalog_waiting + 1] = callback
    return
  end
  catalog_waiting = { callback }
  local headers = { Authorization = "Bearer " .. token }
  local previous = kept
  if previous and previous.etag then
    headers["If-None-Match"] = previous.etag
  end
  local mine = generation
  local finish = once_or_timeout("unavailable", function(catalog, err)
    if mine == generation then
      catalog_done(catalog, err)
    end
  end)
  p.http_request("GET", portal_url .. items.CATALOG_PATH, headers, nil, function(status, body, response_headers)
    if mine ~= generation then
      return
    end
    if status == 304 and previous and kept == previous then
      previous.fetched_at = p.now()
      finish(previous.catalog, nil)
      return
    end
    if status == 200 then
      local catalog = read_catalog(body)
      if catalog then
        kept = { context = context, etag = header(response_headers, "etag"), fetched_at = p.now(), catalog = catalog }
        finish(catalog, nil)
        return
      end
      log("warn", "the portal's item catalog could not be read")
    elseif status ~= 0 then
      log("warn", "the portal refused the item catalog with status " .. tostring(status))
    end
    -- A catalog that could not be revalidated is still the last word the
    -- portal gave, which beats nothing, unless the caller needs a newer one.
    if previous and kept == previous and not force then
      finish(previous.catalog, nil)
      return
    end
    finish(nil, status == 401 and "not_logged_in" or status == 429 and "busy" or "unavailable")
  end)
end

---Keeps an image this session, dropping the oldest past `MAX_IMAGES`.
---@param hash string Its hash.
---@param src string What the adapter made of it.
local function remember(hash, src)
  if images[hash] == nil then
    image_order[#image_order + 1] = hash
  end
  images[hash] = src
  while #image_order > items.MAX_IMAGES do
    images[table.remove(image_order, 1)] = nil
  end
end

---Fetches one image through the adapter, once per hash however many ask
---at a time.
---@param hash string The image's hash.
---@param url string Its absolute URL on the portal, carrying the hash.
---@param callback fun(src: string?, err: string?) Called once.
local function fetch(hash, url, callback)
  if images[hash] then
    callback(images[hash], nil)
    return
  end
  if loading[hash] then
    local waiting = loading[hash]
    waiting[#waiting + 1] = callback
    return
  end
  local p = assert(platform)
  local token = rpf.auth.api_token()
  if not token then
    callback(nil, "not_logged_in")
    return
  end
  loading[hash] = { callback }
  local mine = generation
  local finish = once_or_timeout("unavailable", function(src, err)
    if mine ~= generation then
      return
    end
    local waiting = loading[hash] or {}
    loading[hash] = nil
    if type(src) == "string" and src ~= "" then
      remember(hash, src)
      err = nil
    else
      src = nil
      err = err == "not_found" and "not_found" or "unavailable"
    end
    for _, waiter in ipairs(waiting) do
      waiter(src, err)
    end
  end)
  local ran, thrown = pcall(p.item_image, url, { Authorization = "Bearer " .. token }, hash, finish)
  if not ran then
    log("error", "the adapter's item_image failed: " .. tostring(thrown))
    finish(nil, "unavailable")
  end
end

---The catalog for scripts: the server's items, public fields only.
---@param callback any Called once with the catalog, or nil and why.
---@return boolean? ok True once asked.
---@return string? err `invalid` for a callback that cannot be called, `unavailable` before the client has started.
function items.catalog(callback)
  if not rpf.callable(callback) then
    return nil, "invalid"
  end
  if not platform then
    return nil, "unavailable"
  end
  with_catalog(false, function(catalog, err)
    if not catalog then
      deliver(callback, nil, err)
      return
    end
    local out = { defaults = copy_item(catalog.defaults), items = {} }
    for slug, item in pairs(catalog.items) do
      out.items[slug] = copy_item(item)
    end
    deliver(callback, out, nil)
  end)
  return true
end

---An item's image, by its slug, for scripts.
---@param slug any The item's slug.
---@param callback any Called once with the image, or nil and why.
---@return boolean? ok True once asked.
---@return string? err `invalid` for a slug that is not a non-empty string or a callback that cannot be called, `unavailable` before the client has started.
function items.image(slug, callback)
  if type(slug) ~= "string" or slug == "" or not rpf.callable(callback) then
    return nil, "invalid"
  end
  if not platform then
    return nil, "unavailable"
  end
  ---Looks the slug up in a catalog and fetches its image; after a `404`,
  ---revalidates the catalog once and tries again if the image changed.
  ---@param force boolean Revalidate the catalog first.
  ---@param tried string? The hash already refused.
  local function attempt(force, tried)
    with_catalog(force, function(catalog, err)
      if not catalog then
        deliver(callback, nil, err)
        return
      end
      local item, path = catalog.items[slug], catalog.urls[slug]
      if not item then
        deliver(callback, nil, "not_found")
        return
      end
      if not item.image or not path then
        deliver(callback, nil, "no_image")
        return
      end
      local hash = item.image --[[@as string]]
      if hash == tried then
        deliver(callback, nil, "not_found")
        return
      end
      local portal_url = rpf.auth.portal()
      if not portal_url then
        deliver(callback, nil, "not_logged_in")
        return
      end
      fetch(hash, portal_url .. path, function(src, fetch_err)
        if src then
          deliver(callback, { slug = slug, hash = hash, src = src }, nil)
        elseif fetch_err == "not_found" and not tried then
          attempt(true, hash)
        else
          deliver(callback, nil, fetch_err)
        end
      end)
    end)
  end
  attempt(false, nil)
  return true
end

---Starts the client half: keeps the platform, and forgets what an earlier
---start kept. Called by `rpf.start_client`.
---@param p rpf.ClientPlatform The platform.
function items.start(p)
  platform = p
  generation = generation + 1
  kept, catalog_waiting = nil, nil
  images, image_order, loading = {}, {}, {}
end

---The catalog as kept: what a script gets (`rpf.PlayerItemCatalog`), with
---each image's path on the portal beside it.
---@class rpf.items.Catalog: rpf.PlayerItemCatalog
---@field urls table<string, string> Each image's path on the portal, by slug, with its hash: never handed to a script.

rpf.items = items
return items
