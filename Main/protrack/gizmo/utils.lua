local global     = _G
---@type Api
---@diagnostic disable-next-line: undefined-field
local api        = global.api
local require    = global.require
local TransformQ = require("TransformQ")
local table      = require("Common.tableplus")

---@class protrack.gizmo.Utils
local Utils      = {}

--- Spawns an entity with a token.
--- @param gizmoPrefab string
--- @param token any
--- @return integer
function Utils.SpawnEntity(gizmoPrefab, token)
    ---@diagnostic disable-next-line: return-type-mismatch
    return api.entity.InstantiatePrefab(
        gizmoPrefab,
        nil,
        token,
        TransformQ.Identity
    )
end

---Sets a gizmo's state, including transform and visibility
---@param gizmoId integer
---@param transform any
---@param visible boolean
function Utils.SetGizmoState(gizmoId, transform, visible)
    if visible ~= nil and visible and transform ~= nil then
        -- Pass a copy, as the Dec 2025 build (which worked) did. The Jan 2026 gizmo
        -- refactor passed the transform itself, even the shared TransformQ.Identity:
        -- suspected cause of the crash when the gizmos are first shown on Anchor.
        api.transform.SetTransform(gizmoId, table.copy(transform))
        api.transform.SetScale(gizmoId, 1) -- not the same thing for some god damn reason.
    else
        -- set scale to 0 to hide
        api.transform.SetScale(gizmoId, 0)
    end
end

return Utils
