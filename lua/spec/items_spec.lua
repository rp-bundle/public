-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The item catalog and item images on the client (P3, #243), with the test
-- playing the game server, the portal's player API and the adapter's
-- `item_image`. The catalog's shape is `PublicItemCatalog` in
-- `crates/rpf-backend/src/player_api.rs`.

local support = require("spec.support")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local SERVER = "00000001-0000-4000-8000-000000000001"
local PORTAL = "https://portal.example"
local TOKEN = "rpf_at_token.mac"
local APPLE = string.rep("a", 64)
local PEAR = string.rep("b", 64)

---The catalog's path with an image's hash, as the portal writes it.
---@param slug string The item.
---@param hash string The image's hash.
---@return string path The path.
local function image_path(slug, hash)
  return "/api/v1/player/items/" .. slug .. "/image?v=" .. hash
end

---One public item, as the portal sends it.
---@param hash string? Its image's hash.
---@param slug string? Its slug, for the image's path.
---@return table item The item.
local function item(hash, slug)
  local out = { weight = 1, size = { x = 1, y = 2 }, stack_limit = 10 }
  if hash then
    out.image = hash
    out.image_url = image_path(slug or "apple", hash)
  end
  return out
end

---A catalog body.
---@param items table<string, table> The items.
---@return table body The body.
local function catalog(items)
  return { defaults = item(nil), items = items }
end

---Starts the client and logs in, with an API token.
---@return spec.FakeClient c The platform.
local function logged_in()
  support.load_core("client")
  local c = support.fake_client_platform()
  rpf.start_client(c)
  c.from_server("rpf:join_nonce", {
    nonce = "rpf_jn_one",
    expires_in_ms = 120000,
    portal_url = PORTAL,
    server_id = SERVER,
  })
  assert(rpf.auth.login("sam", "correct horse"))
  c.respond(200, {
    player_id = PLAYER,
    username = "sam",
    created = false,
    ticket = "rpf_jt_ticket",
    ticket_expires_at = "2026-01-01T00:01:00Z",
    remember_token = "rpf_rt_remember",
    remember_token_expires_at = "2026-01-31T00:00:00Z",
    session_token = "rpf_st_session",
    session_token_expires_at = "2026-01-01T12:00:00Z",
    api_token = TOKEN,
    api_token_expires_at = "2026-01-01T00:15:00Z",
  })
  c.from_server("rpf:join_result", { ok = true, player_id = PLAYER, username = "sam", created = false })
  return c
end

---The oldest request for the catalog, which must be waiting.
---@param c spec.FakeClient The platform.
---@return table request The request.
local function catalog_request(c)
  local waiting = assert(c.pending(), "a request is waiting")
  local request = c.requests[waiting.index]
  assert.are.equal("GET", request.method)
  assert.are.equal(PORTAL .. "/api/v1/player/items", request.url)
  assert.are.equal("Bearer " .. TOKEN, request.headers.Authorization)
  return request
end

---Asks for an image, recording what the callback got.
---@param slug any The slug.
---@return { image: rpf.ItemImage?, err: string?, calls: integer } got What arrived.
local function ask(slug)
  local got = { calls = 0 }
  assert.is_true(rpf.api.items.image(slug, function(image, err)
    got.calls = got.calls + 1
    got.image, got.err = image, err
  end))
  return got
end

describe("rpf.items", function()
  it("fetches an image by slug through the adapter, with the token in a header and never in the URL", function()
    local c = logged_in()
    local got = ask("apple")
    catalog_request(c)
    c.respond(200, catalog({ apple = item(APPLE) }), { ETag = '"one"' })
    assert.are.equal(1, #c.images)
    local asked = c.images[1]
    assert.are.equal(PORTAL .. image_path("apple", APPLE), asked.url)
    assert.is_nil(asked.url:find(TOKEN, 1, true), "the token is never in a URL")
    assert.are.same({ Authorization = "Bearer " .. TOKEN }, asked.headers)
    assert.are.equal(APPLE, asked.hash)
    assert.are.equal(0, got.calls)
    asked.done("data:image/png;base64,AAAA")
    assert.are.same({ slug = "apple", hash = APPLE, src = "data:image/png;base64,AAAA" }, got.image)
    assert.are.equal(1, got.calls)
  end)

  it("keeps an image by its hash: asked again, it answers at once", function()
    local c = logged_in()
    ask("apple")
    c.respond(200, catalog({ apple = item(APPLE) }))
    c.images[1].done("src-apple")
    local again = ask("apple")
    assert.are.equal("src-apple", again.image.src)
    assert.are.equal(1, #c.images, "not fetched again")
    assert.is_nil(c.pending(), "a fresh catalog is not asked for again")
  end)

  it("fetches one hash once however many ask at a time", function()
    local c = logged_in()
    local first, second = ask("apple"), ask("apple")
    c.respond(200, catalog({ apple = item(APPLE) }))
    assert.is_nil(c.pending(), "one catalog request for both")
    assert.are.equal(1, #c.images)
    c.images[1].done("src")
    assert.are.equal("src", first.image.src)
    assert.are.equal("src", second.image.src)
  end)

  it("revalidates the catalog with its ETag once it is stale, and fetches a changed image under its new hash", function()
    local c = logged_in()
    ask("apple")
    c.respond(200, catalog({ apple = item(APPLE) }), { etag = '"one"' })
    c.images[1].done("old")

    c.time = c.time + rpf.items.CATALOG_FRESH_MS
    ask("apple")
    local request = catalog_request(c)
    assert.are.equal('"one"', request.headers["If-None-Match"])
    c.respond(304, "")
    assert.are.equal(1, #c.images, "an unchanged image is not fetched again")

    c.time = c.time + rpf.items.CATALOG_FRESH_MS
    local got = ask("apple")
    c.respond(200, catalog({ apple = item(PEAR) }), { etag = '"two"' })
    assert.are.equal(2, #c.images)
    assert.are.equal(PEAR, c.images[2].hash)
    c.images[2].done("new")
    assert.are.same({ slug = "apple", hash = PEAR, src = "new" }, got.image)
  end)

  it("revalidates the catalog after a 404 and asks once more for the new image", function()
    local c = logged_in()
    local got = ask("apple")
    c.respond(200, catalog({ apple = item(APPLE) }), { ETag = '"one"' })
    c.images[1].done(nil, "not_found")
    local request = catalog_request(c)
    assert.are.equal('"one"', request.headers["If-None-Match"], "revalidated though still fresh")
    c.respond(200, catalog({ apple = item(PEAR) }), { ETag = '"two"' })
    assert.are.equal(PEAR, c.images[2].hash)
    c.images[2].done("new")
    assert.are.equal("new", got.image.src)
  end)

  it("says not_found when the catalog still names the image the portal refused, and asks no more", function()
    local c = logged_in()
    local got = ask("apple")
    c.respond(200, catalog({ apple = item(APPLE) }))
    c.images[1].done(nil, "not_found")
    c.respond(200, catalog({ apple = item(APPLE) }))
    assert.are.equal(1, #c.images)
    assert.are.equal("not_found", got.err)
    assert.are.equal(1, got.calls)
  end)

  it("says no_image, not_found and invalid without fetching", function()
    local c = logged_in()
    local plain, missing = ask("plain"), ask("ghost")
    c.respond(200, catalog({ plain = item(nil) }))
    assert.are.equal("no_image", plain.err)
    assert.are.equal("not_found", missing.err)
    assert.are.equal(0, #c.images)
    for _, bad in ipairs({ "", 7, false }) do
      local ok, err = rpf.api.items.image(bad, function() end)
      assert.is_nil(ok)
      assert.are.equal("invalid", err, tostring(bad))
    end
    assert.are.same({ nil, "invalid" }, { rpf.api.items.image("apple", "not a function") })
  end)

  it("never fetches an image path the catalog did not write with its own hash", function()
    local c = logged_in()
    local elsewhere, mismatched, bad_hash = ask("elsewhere"), ask("mismatched"), ask("bad_hash")
    c.respond(200, catalog({
      elsewhere = { weight = 1, size = { x = 1, y = 1 }, stack_limit = 1, image = APPLE, image_url = "https://evil.example/x?v=" .. APPLE },
      mismatched = { weight = 1, size = { x = 1, y = 1 }, stack_limit = 1, image = APPLE, image_url = image_path("mismatched", PEAR) },
      bad_hash = { weight = 1, size = { x = 1, y = 1 }, stack_limit = 1, image = "../../x", image_url = image_path("bad_hash", "../../x") },
    }))
    assert.are.equal(0, #c.images)
    assert.are.equal("no_image", elsewhere.err)
    assert.are.equal("no_image", mismatched.err)
    assert.are.equal("no_image", bad_hash.err)
  end)

  it("says not_logged_in before there is a token, and sends nothing", function()
    support.load_core("client")
    local c = support.fake_client_platform()
    rpf.start_client(c)
    local got = ask("apple")
    assert.are.equal("not_logged_in", got.err)
    assert.are.equal(0, #c.requests)
    assert.are.equal(0, #c.images)
  end)

  it("maps the portal's refusals, and keeps using a catalog it could not revalidate", function()
    local c = logged_in()
    local got = ask("apple")
    c.respond(429, { error = "rate_limited", message = "slow down" })
    assert.are.equal("busy", got.err)
    got = ask("apple")
    c.respond(401, { error = "invalid_token", message = "no" })
    assert.are.equal("not_logged_in", got.err)
    got = ask("apple")
    c.respond(200, "not json")
    assert.are.equal("unavailable", got.err)

    got = ask("apple")
    c.respond(200, catalog({ apple = item(APPLE) }))
    c.images[1].done("src")
    c.time = c.time + rpf.items.CATALOG_FRESH_MS
    got = ask("apple")
    c.respond(0, "")
    assert.are.equal("src", got.image.src, "the last catalog stands while the portal is unreachable")
  end)

  it("gives up on a fetch that never answers, and a late answer changes nothing", function()
    local c = logged_in()
    -- Shorter than the catalog's freshness, so asking again reuses it.
    rpf.items.TIMEOUT_MS = 1000
    local got = ask("apple")
    c.respond(200, catalog({ apple = item(APPLE) }))
    c.advance(rpf.items.TIMEOUT_MS)
    assert.are.equal("unavailable", got.err)
    c.images[1].done("late")
    assert.are.equal(1, got.calls)
    local again = ask("apple")
    assert.are.equal(2, #c.images, "a failed fetch is not kept: asked again, it is fetched again")
    c.images[2].done("src")
    assert.are.equal("src", again.image.src)
  end)

  it("gives up on a catalog request that never answers", function()
    local c = logged_in()
    local got = ask("apple")
    c.advance(rpf.items.TIMEOUT_MS)
    assert.are.equal("unavailable", got.err)
  end)

  it("treats an adapter that throws or answers nonsense as unavailable, and logs a callback that throws", function()
    local c = logged_in()
    c.item_image = function()
      error("boom")
    end
    local got = ask("apple")
    c.respond(200, catalog({ apple = item(APPLE) }))
    assert.are.equal("unavailable", got.err)

    c.item_image = function(_, _, _, done)
      done(42, "weird")
    end
    got = ask("apple")
    assert.are.equal("unavailable", got.err)

    c.item_image = function(_, _, _, done)
      done("src")
    end
    assert.is_true(rpf.api.items.image("apple", function()
      error("addon bug")
    end))
    local logged = false
    for _, line in ipairs(c.logs) do
      logged = logged or (line.level == "error" and line.message:find("addon bug", 1, true) ~= nil)
    end
    assert.is_true(logged)
  end)

  it("hands scripts a copy of the catalog, without the image paths", function()
    local c = logged_in()
    local got
    assert.is_true(rpf.api.items.catalog(function(catalog_copy, err)
      got = { catalog = catalog_copy, err = err }
    end))
    c.respond(200, catalog({ apple = item(APPLE), plain = item(nil), broken = { weight = "heavy" } }))
    assert.are.same({
      defaults = { weight = 1, size = { x = 1, y = 2 }, stack_limit = 10 },
      items = {
        apple = { weight = 1, size = { x = 1, y = 2 }, stack_limit = 10, image = APPLE },
        plain = { weight = 1, size = { x = 1, y = 2 }, stack_limit = 10 },
      },
    }, got.catalog)
    got.catalog.items.apple.weight = 99
    local second
    rpf.api.items.catalog(function(catalog_copy)
      second = catalog_copy
    end)
    assert.are.equal(1, second.items.apple.weight, "a copy each time")
  end)

  it("drops a catalog from another portal or server", function()
    local c = logged_in()
    ask("apple")
    c.respond(200, catalog({ apple = item(APPLE) }), { ETag = '"one"' })
    c.images[1].done("src")
    c.from_server("rpf:join_nonce", {
      nonce = "rpf_jn_two",
      expires_in_ms = 120000,
      portal_url = "https://other.example",
      server_id = SERVER,
    })
    ask("pear")
    local waiting = assert(c.pending())
    local request = c.requests[waiting.index]
    assert.are.equal("https://other.example/api/v1/player/items", request.url)
    assert.is_nil(request.headers["If-None-Match"])
  end)
end)
