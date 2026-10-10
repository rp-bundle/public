---Staff edits of held records (F5): the commands the portal sends to change
---a character, an account, a container or a live addon record (J2) this
---server holds.
---
---While this server holds a record it is the record's only writer (C7), so
---the portal cannot change it directly: it sends a command, and this module
---runs it through the same calls a script would use (`rpf.records`,
---`rpf.inventory`, `rpf.characters`), so a staff edit keeps every rule a
---player's action keeps. The change is then reported like any other, and
---the report is queued before the answer, so by the time the portal reads
---`applied` it has the new state.
---
---**Every edit names the revision the staff member saw** (`records.current`).
---A record that has moved on since, or has a change here not yet reported,
---is refused, and nothing is applied to a state nobody looked at. That is
---also what makes a staff member's retry after an unknown outcome safe: if
---the first attempt landed, the record has moved on.
---
---A refusal is `failed` with a reason written for the staff member, and
---nothing changes. Commands run at most once per request id (D1, #71), so a
---resend gets the first answer.
---@class rpf.edits
---@field REASONS table<string, string> Why an edit was refused, by the error the call that made it returned, in words for the staff member.
local edits = {}

local rpf = rpf
local json = rpf.json

edits.REASONS = {
  not_held = "this server does not hold that record",
  changed = "the record has changed since the page was loaded; reload it and try again",
  invalid = "that is not a change this record takes",
  invalid_argument = "that is not a count or a place this container takes",
  no_stack = "there is no stack there any more",
  insufficient = "that stack holds fewer than that",
  no_space = "there is no free space in the grid for it",
  insufficient_funds = "that would take the account below zero",
  out_of_range = "that would take the balance past what an account can hold",
  busy = "its player is in the middle of a request; try again in a moment",
  outbox_full = "this server cannot report to the portal right now; try again shortly",
  too_large = "its records are too large to hand back to the portal",
  backlog = "it has payments still to report; try again shortly",
  inactive = "its addon is not active on this server",
  creating = "it was only just created here; try again in a moment",
}

---A refusal as the portal shows it to staff.
---@param err string? The error a call returned.
---@param refusal table? For `invalid`, the rule broken, as `rpf.inventory` names it.
---@return string reason Words for the staff member.
local function reason(err, refusal)
  local words = edits.REASONS[err or ""] or ("it was refused (" .. tostring(err) .. ")")
  if err == "invalid" and type(refusal) == "table" then
    return words .. ": " .. tostring(json.encode(refusal))
  end
  return words
end

---Checks a record is held at the revision the edit names.
---@param kind string The record's kind.
---@param id string The record's uuid.
---@param revision number The revision the staff member saw.
---@return boolean ok True if the edit may go ahead.
---@return string? reason Why not, for staff.
local function at(kind, id, revision)
  local ok, err = rpf.records.current(kind, id, revision)
  if not ok then
    return false, reason(err)
  end
  return true
end

---Reports a change at once, ahead of the command's answer, so the portal's
---replica has it when staff read `applied`. Refused by the outbox, it stays
---marked and goes with the next flush; the edit has been made either way.
local function report()
  rpf.sync.flush()
end

---`adjust_balance`: one ledger entry between the account and the server's
---funds account, under the portal's `client_id`.
---@param command table The decoded command.
---@return boolean applied False if refused.
---@return string? reason Why, for staff.
function edits.adjust_balance(command)
  local ok, why = at("account", command.account_id, command.base_revision)
  if not ok then
    return false, why
  end
  local made, err = rpf.records.adjust(
    command.account_id,
    command.funds_account,
    command.amount,
    command.client_id,
    command.description
  )
  if not made then
    return false, reason(err)
  end
  report()
  return true
end

---Runs a container edit, after its revision check.
---@param command table The decoded command, with `container_id` and `base_revision`.
---@param edit rpf.inventory.Edit The edit.
---@return boolean applied False if refused.
---@return string? reason Why, for staff.
local function contents(command, edit)
  local ok, why = at("container", command.container_id, command.base_revision)
  if not ok then
    return false, why
  end
  local done, err, refusal = rpf.inventory.apply_edit(command.container_id, edit)
  if not done then
    return false, reason(err, refusal)
  end
  report()
  return true
end

---`give_item`: units of an item with no data, where `add` would put them.
---@param command table The decoded command.
---@return boolean applied False if refused.
---@return string? reason Why, for staff.
function edits.give_item(command)
  return contents(command, {
    op = "give",
    item = command.item,
    count = command.count,
    position = command.position,
    rotated = command.rotated,
  })
end

---`take_item`: units off the stack or placement at an index.
---@param command table The decoded command.
---@return boolean applied False if refused.
---@return string? reason Why, for staff.
function edits.take_item(command)
  return contents(command, { op = "take", index = command.index, count = command.count })
end

---`move_item`: a whole placement of a grid to a new cell.
---@param command table The decoded command.
---@return boolean applied False if refused.
---@return string? reason Why, for staff.
function edits.move_item(command)
  return contents(command, {
    op = "move",
    index = command.index,
    position = command.position,
    rotated = command.rotated,
  })
end

---`edit_character`: new names or gender, each only if given.
---@param command table The decoded command.
---@return boolean applied False if refused.
---@return string? reason Why, for staff.
function edits.edit_character(command)
  local ok, why = at("character", command.character_id, command.base_revision)
  if not ok then
    return false, why
  end
  local done, err = rpf.records.set_character(command.character_id, {
    first_name = command.first_name,
    last_name = command.last_name,
    gender = command.gender,
  })
  if not done then
    return false, reason(err)
  end
  report()
  return true
end

---`delete_character`: let the character and everything it owns go, with
---their final state, for the portal to purge (`characters.remove`).
---@param command table The decoded command.
---@return boolean applied False if refused.
---@return string? reason Why, for staff.
function edits.delete_character(command)
  local ok, why = at("character", command.character_id, command.base_revision)
  if not ok then
    return false, why
  end
  local done, err = rpf.characters.remove(command.character_id)
  if not done then
    return false, reason(err)
  end
  return true
end

---`edit_addon_record`: set fields of a held addon record (J2), checked
---whole against its type's installed definition, as a script's write is.
---@param command table The decoded command.
---@return boolean applied False if refused.
---@return string? reason Why, for staff.
function edits.edit_addon_record(command)
  local ok, why = at("addon_record", command.record_id, command.base_revision)
  if not ok then
    return false, why
  end
  local done, err, refusal = rpf.records.set_addon_fields(command.record_id, command.patch)
  if not done then
    return false, reason(err, refusal)
  end
  report()
  rpf.data.announce("records.changed", {
    type = done.type,
    id = command.record_id,
    record = rpf.data.view(command.record_id),
    by = "staff",
  })
  return true
end

---`delete_addon_record`: let a held addon record go, with its final state,
---for the portal to delete as a record nobody holds (J2). The release is
---queued ahead of the answer, so the portal has the final state first.
---@param command table The decoded command.
---@return boolean applied False if refused.
---@return string? reason Why, for staff.
function edits.delete_addon_record(command)
  local ok, why = at("addon_record", command.record_id, command.base_revision)
  if not ok then
    return false, why
  end
  local type_name = rpf.records.entries[rpf.records.key("addon_record", command.record_id)].data.type
  local done, err = rpf.sync.release({ { kind = "addon_record", id = command.record_id } })
  if not done then
    return false, reason(err)
  end
  rpf.data.announce("records.deleted", { type = type_name, id = command.record_id, by = "staff" })
  return true
end

---Registers the record commands. Called by `rpf.start_server`.
function edits.start()
  for _, name in ipairs({
    "adjust_balance",
    "give_item",
    "take_item",
    "move_item",
    "edit_character",
    "delete_character",
    "edit_addon_record",
    "delete_addon_record",
  }) do
    rpf.commands.register(name, edits[name])
  end
end

rpf.edits = edits
return edits
