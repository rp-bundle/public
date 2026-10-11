---Item images on the Gmod client (P3, #243): the engine half of
---`rpf.items.image`, the client platform's `item_image`.
---
---The core hands over the image's URL on the portal, the player's API token
---as a header, and the image's content hash. This fetches it with `HTTP`,
---checks it against the hash with `util.SHA256`, writes it under `data/` as
---`rpf/images/<hash>.png`, and answers with the path `Material()` takes
---(`data/rpf/images/<hash>.png`), once it has made sure the engine reads it
---as a material. A hash on disk is read and checked again before it is
---used, so a file cut short by a crash is fetched again rather than drawn,
---and an unchanged image is never fetched again, even after a restart.
---
---The portal answers with a redirect to the user-content domain. `HTTP`
---follows it, and must not send the `Authorization` header on to another
---host: the signed URL is the credential there. That is what curl does
---for a header set by the caller, and what a real client has to confirm
---(`docs/testing.md`, layer 5).
---
---Everything under `data/` is readable by every server's client Lua, which
---is fine for these: an image is public to whoever holds a signed URL, and
---no secret is ever written there.
---@class rpf.gmod.Images
---@field DIR string Where images are kept, under `data/`.
---@field MAX_KEPT integer The most images kept on disk; past it, the oldest written go.
---@field MAX_BYTES integer The largest image accepted, far above what the portal stores.
local images = {}

images.DIR = "rpf/images"
images.MAX_KEPT = 512
images.MAX_BYTES = 1024 * 1024

---Where one image is kept, under `data/`.
---@param hash string The image's hash, already checked to be one.
---@return string path The path, for `file.*` with `"DATA"`.
local function path_of(hash)
  return images.DIR .. "/" .. hash .. ".png"
end

---What `Material()` is given for a kept image.
---@param hash string The image's hash.
---@return string src The material path.
local function src_of(hash)
  return "data/" .. path_of(hash)
end

---Whether some bytes are the image a hash names.
---@param bytes string? The bytes.
---@param hash string The hash.
---@return boolean ok Whether they are.
local function matches(bytes, hash)
  return type(bytes) == "string" and #bytes > 0 and string.lower(util.SHA256(bytes)) == hash
end

---Whether the engine reads a kept image as a material.
---@param hash string The image's hash.
---@return boolean ok Whether it does.
local function drawable(hash)
  local material = Material(src_of(hash))
  return material ~= nil and not material:IsError()
end

---Drops the oldest images written past `MAX_KEPT`, never `keep`.
---@param keep string The file just written.
local function trim(keep)
  local names = file.Find(images.DIR .. "/*.png", "DATA") or {}
  if #names <= images.MAX_KEPT then
    return
  end
  local list = {}
  for _, name in ipairs(names) do
    local path = images.DIR .. "/" .. name
    if path ~= keep then
      list[#list + 1] = { path = path, time = file.Time(path, "DATA") or 0 }
    end
  end
  table.sort(list, function(a, b)
    return a.time < b.time
  end)
  for i = 1, #names - images.MAX_KEPT do
    if list[i] then
      file.Delete(list[i].path)
    end
  end
end

---Builds the client platform's `item_image` over the adapter's HTTP.
---@param http_request fun(method: string, url: string, headers: table<string, string>, body: string?, callback: fun(status: integer, body: string, headers: table<string, string>)) The shared HTTP member (`shared.http_request`).
---@return fun(url: string, headers: table<string, string>, hash: string, done: fun(src: string?, err: string?)) item_image The member.
function images.item_image(http_request)
  return function(url, headers, hash, done)
    if type(hash) ~= "string" or not hash:find("^[0-9a-f]+$") or #hash ~= 64 then
      timer.Simple(0, function()
        done(nil, "unavailable")
      end)
      return
    end
    local path = path_of(hash)
    if file.Exists(path, "DATA") then
      if matches(file.Read(path, "DATA"), hash) and drawable(hash) then
        timer.Simple(0, function()
          done(src_of(hash), nil)
        end)
        return
      end
      file.Delete(path)
    end
    http_request("GET", url, headers, nil, function(status, body)
      if status == 404 then
        done(nil, "not_found")
        return
      end
      if status ~= 200 or #body > images.MAX_BYTES or not matches(body, hash) then
        done(nil, "unavailable")
        return
      end
      file.CreateDir(images.DIR)
      file.Write(path, body)
      if not matches(file.Read(path, "DATA"), hash) or not drawable(hash) then
        file.Delete(path)
        done(nil, "unavailable")
        return
      end
      trim(path)
      done(src_of(hash), nil)
    end)
  end
end

return images
