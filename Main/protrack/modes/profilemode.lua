-----------------------------------------------------------------------
--/  @file    protrack.modes.profilemode.lua
--/
--/  @brief  Force Profile mode. Builds a section of 4 m chunks whose
--/          forces go from the current track end to a mid point and an
--/          end point, following transition curves. Reuses ForceLock's
--/          integration (FvdMode.StepPoint) with a changing target.
-----------------------------------------------------------------------
local global = _G
---@type Api
---@diagnostic disable-next-line: undefined-field
local api = global.api
local require = global.require
local ipairs = global.ipairs
local math = global.math
local string = global.string

local Vector3 = require("Vector3")
local Quaternion = require("Quaternion")
local TransformQ = require("TransformQ")
local mathUtils = require("Common.mathUtils")
local Utils = require("protrack.utils")
local FvdMode = require("protrack.modes.fvdmode")
local Datastore = require("protrack.datastore")
local TrackPointGizmo = require("protrack.gizmo.trackpointgizmo")
local logger = require("forgeutils.logger").Get("ProfileMode", "INFO")

--/ Main class definition
---@class ProfileMode
local ProfileMode = {}
ProfileMode.CHUNK_LENGTH = 4.0
ProfileMode.MATCH_DISTANCE = 0.02     -- Same tolerance ForceLock uses to match the track end.
ProfileMode.START_G_SKIP = 2          -- Last TrackViz samples are distorted where the walk hits the track end.
ProfileMode.START_G_SAMPLES = 3
ProfileMode.TIMESTEP = 0.01           -- Same timestep as ForceLock.
ProfileMode.MIN_VELOCITY = 0.5
ProfileMode.MAX_ITERATIONS = 65536
ProfileMode.LINE_POINT_SPACING = 0.25
ProfileMode.VERTICAL_LIMIT = 0.985    -- Above this |forward.y| (about 80 deg of pitch), bank is undefined.
ProfileMode.LEVEL_MAX_BANK = math.rad(75)
ProfileMode.RAIL_HALF_WIDTH = 0.5     -- Preview rails, in M either side of the track.
ProfileMode.TIE_SPACING = 1.0         -- Preview ties, in M.

-- Settings, also used as datastore keys.
ProfileMode.profileLength = 20.0      -- Metres, multiple of CHUNK_LENGTH.
ProfileMode.profileMidPercent = 40.0  -- Mid point, in % of the section length.
ProfileMode.profileMidVertG = 1.0
ProfileMode.profileEndVertG = 1.0
ProfileMode.profileMidLatG = 0.0
ProfileMode.profileEndLatG = 0.0
ProfileMode.profileMidBank = 0.0      -- Degrees. Absolute: bank. Relative: roll from the previous point.
ProfileMode.profileEndBank = 0.0      -- Degrees. Absolute: bank. Relative: roll from the previous point.
ProfileMode.profileCurveIn = 1        -- Index into CURVES, start -> mid.
ProfileMode.profileCurveOut = 1       -- Index into CURVES, mid -> end.
ProfileMode.profileBankRelative = false
ProfileMode.profileLevelTurns = false -- Vertical G is given as on a flat track, banking is compensated.

ProfileMode.SETTINGS = {
    "profileLength",
    "profileMidPercent",
    "profileMidVertG",
    "profileEndVertG",
    "profileMidLatG",
    "profileEndLatG",
    "profileMidBank",
    "profileEndBank",
    "profileCurveIn",
    "profileCurveOut",
    "profileBankRelative",
    "profileLevelTurns",
}

-- Runtime state
ProfileMode.context = nil
ProfileMode.line = nil
---@type protrack.gizmo.TrackPointGizmo?
ProfileMode.midGizmo = nil
---@type protrack.gizmo.TrackPointGizmo?
ProfileMode.endGizmo = nil
---@type ProfilePlan?
ProfileMode.plan = nil
ProfileMode.planDirty = true
ProfileMode.locked = false
ProfileMode.stalled = false
ProfileMode.endIndex = 1              -- Boundary the real track end is on, from placed pieces and TrackViz.
ProfileMode.offSection = false        -- The track end moved off the section while building.
ProfileMode.syncedWalk = nil          -- TrackViz data endIndex was last read from.
ProfileMode.hookLogged = {}           -- Boundaries build calls started on since the last placement, for the log.
ProfileMode.cancelRequested = false
ProfileMode.refreshRequested = false
ProfileMode.seedPos = nil             -- Track end the Mid and End values were last pre-filled for.
ProfileMode.reseedBank = false
ProfileMode.reseedVertG = false
ProfileMode.datastoreCache = {}

---@class ProfileBoundary
---@field pos any Coaster-space heartline position.
---@field rot any Coaster-space orientation.

---@class ProfileSample
---@field pos any Coaster-space heartline position.
---@field rot any Coaster-space orientation.
---@field distance number Heartline distance from the section start, in M.

---@class ProfileStart
---@field vertG number Measured vertical G.
---@field latG number Measured lateral G.
---@field bank number In rads, from GetBankOf.
---@field levelFactor number Level-turn factor at the start.

---@class ProfilePlan
---@field boundaries ProfileBoundary[] Chunk boundaries. [1] is the section start, [#] the section end.
---@field samples ProfileSample[] Path samples for the preview.
---@field tPoints any[] World-space heartline points for the preview line.
---@field midPoint ProfileBoundary The mid point.
---@field datapoints table The TrackViz data the plan was built from.
---@field heartline number The heartline offset used, in M.
---@field start ProfileStart
---@field midVertG number Vertical G at the mid point, with level-turn compensation.
---@field endVertG number Vertical G at the end, with level-turn compensation.
---@field levelLimited boolean Whether the level-turn compensation hit its limit.

--- Transition curves, indexed like the UI list. Each maps 0..1 to 0..1.
local CURVES = {
    [0] = function(t) return t end,                                   -- Linear
    [1] = function(t) return t * t * (3 - 2 * t) end,                 -- Smooth
    [2] = function(t) return t * t * t * (t * (t * 6 - 15) + 10) end, -- Smoother
    [3] = function(t) return t * t end,                               -- Ease in
    [4] = function(t) return 1 - (1 - t) * (1 - t) end,               -- Ease out
}

---Sets a datastore value, only when it changed.
---@param name string
---@param value any
local function SetDatastore(name, value)
    if ProfileMode.datastoreCache[name] == value then
        return
    end
    ProfileMode.datastoreCache[name] = value
    api.ui2.SetDataStoreElement(ProfileMode.context, name, value)
end

---Sets a setting and shows it in the UI.
---@param name string
---@param value any
local function SetValue(name, value)
    ProfileMode[name] = value
    SetDatastore(name, value)
end

---Returns the number of chunks in the section.
---@return integer
function ProfileMode.GetChunkCount()
    return math.max(1, math.floor(ProfileMode.profileLength / ProfileMode.CHUNK_LENGTH + 0.5))
end

---Returns the bank of an orientation against the horizon, in rads.
---0 is flat, positive raises the right side, +-pi is upside down.
---@param rotation any
---@return number
local function GetBankOf(rotation)
    return math.atan(rotation:GetR():GetY(), rotation:GetU():GetY())
end

---Returns whether the track points almost straight up or down, where bank is undefined.
---@param rotation any
---@return boolean
local function IsNearVertical(rotation)
    return math.abs(rotation:GetF():GetY()) > ProfileMode.VERTICAL_LIMIT
end

---Wraps an angle into [-pi, pi].
---@param angle number In rads.
---@return number
local function WrapAngle(angle)
    while angle > math.pi do
        angle = angle - 2 * math.pi
    end
    while angle < -math.pi do
        angle = angle + 2 * math.pi
    end
    return angle
end

---Returns the shortest way to roll by a bank change, keeping an exact +-180 as entered.
---@param delta number In degrees.
---@return number
local function ShortestRoll(delta)
    while delta > 180 do
        delta = delta - 360
    end
    while delta < -180 do
        delta = delta + 360
    end
    return delta
end

---Returns the factor that keeps a banked track level: the vertical G it needs, over the
---vertical G it would need flat.
---@param rotation any
---@return number factor
---@return boolean limited Whether the bank was past the helper's limit.
local function GetLevelFactor(rotation)
    if IsNearVertical(rotation) then
        return 1, false
    end

    local bank = math.abs(GetBankOf(rotation))
    if bank > math.pi / 2 then
        return 1, true
    end
    if bank > ProfileMode.LEVEL_MAX_BANK then
        return 1 / math.cos(ProfileMode.LEVEL_MAX_BANK), true
    end
    return 1 / math.cos(bank), false
end

---Returns the value of a channel at a distance along the section.
---@param startValue number
---@param midValue number
---@param endValue number
---@param distance number Distance from the section start, in M.
---@param midDistance number
---@param length number
---@param curveIn function
---@param curveOut function
---@return number
local function EvaluateChannel(startValue, midValue, endValue, distance, midDistance, length, curveIn, curveOut)
    if distance < midDistance then
        local t = mathUtils.Clamp(distance / midDistance, 0, 1)
        return startValue + (midValue - startValue) * curveIn(t)
    end

    local segmentLength = length - midDistance
    if segmentLength <= 0 then
        return midValue
    end

    local t = mathUtils.Clamp((distance - midDistance) / segmentLength, 0, 1)
    return midValue + (endValue - midValue) * curveOut(t)
end

---Returns the vertical and lateral G at the end of the TrackViz data.
---Averages a few samples, skipping the last ones.
---@return number vertG
---@return number latG
local function GetStartForces()
    local datapoints = Datastore.datapoints
    local last = math.max(1, #datapoints - ProfileMode.START_G_SKIP)
    local first = math.max(1, last - ProfileMode.START_G_SAMPLES + 1)

    local vertG = 0
    local latG = 0
    for i = first, last do
        local g = datapoints[i].measurements[1].g
        vertG = vertG + g:GetY()
        latG = latG + g:GetX()
    end

    local count = last - first + 1
    return vertG / count, latG / count
end

---Returns the forces and bank at the end of the TrackViz data.
---@return ProfileStart
local function GetStart()
    local vertG, latG = GetStartForces()
    local rotation = Datastore.datapoints[#Datastore.datapoints].measurements[1].transform:GetOr()
    local levelFactor = GetLevelFactor(rotation)
    return {
        vertG = vertG,
        latG = latG,
        bank = GetBankOf(rotation),
        levelFactor = levelFactor
    }
end

---Returns the start vertical G in slider units: as on a flat track with level turns.
---@param start ProfileStart
---@return number
local function GetStartVertSetting(start)
    if ProfileMode.profileLevelTurns then
        return start.vertG / start.levelFactor
    end
    return start.vertG
end

---Pre-fills the Mid and End banks: the start bank (absolute) or no roll (relative).
---@param start ProfileStart
local function SeedBank(start)
    local bank = 0
    if not ProfileMode.profileBankRelative then
        bank = math.deg(start.bank)
    end
    SetValue("profileMidBank", bank)
    SetValue("profileEndBank", bank)
end

---Pre-fills the Mid and End vertical G with the start value.
---@param start ProfileStart
local function SeedVertG(start)
    local vertG = GetStartVertSetting(start)
    SetValue("profileMidVertG", vertG)
    SetValue("profileEndVertG", vertG)
end

---Pre-fills the Mid and End values with the start values, once per track end,
---so a new section starts as a straight continuation.
---@param start ProfileStart
---@param walkEnd any Coaster-space track end.
---@param startT any The start transform given to StaticBuildEndPoint.
local function SeedFromStart(start, walkEnd, startT)
    if ProfileMode.seedPos == nil
        or Vector3.Length(walkEnd - ProfileMode.seedPos) > ProfileMode.MATCH_DISTANCE then
        ProfileMode.seedPos = walkEnd
        SeedVertG(start)
        SetValue("profileMidLatG", start.latG)
        SetValue("profileEndLatG", start.latG)
        SeedBank(start)
        logger:Info(string.format("Start bank %.1f deg (game reports %.1f deg)",
            math.deg(start.bank), math.deg(startT:GetBank())))
    else
        if ProfileMode.reseedBank then
            SeedBank(start)
        end
        if ProfileMode.reseedVertG then
            SeedVertG(start)
        end
    end
    ProfileMode.reseedBank = false
    ProfileMode.reseedVertG = false
end

---Rolls an orientation around its forward axis, the same way StepPoint applies roll.
---@param rotation any
---@param angle number In rads.
---@return any
local function RollAroundForward(rotation, angle)
    local forward = rotation:GetF()
    local rolledRight = (Utils.MultQuaternionVector(
        Quaternion.FromAxisAngle(forward, angle),
        rotation:GetR()
    )):Normalised()
    return Quaternion.FromFR(forward, rolledRight)
end

---Returns the point at a distance between two integration points.
---@param fromPoint FvdPoint
---@param toPoint FvdPoint
---@param distance number
---@return ProfileBoundary
local function InterpolatePoint(fromPoint, toPoint, distance)
    local span = toPoint.heartDistance - fromPoint.heartDistance
    local fraction = 1
    if span > 0 then
        fraction = mathUtils.Clamp((distance - fromPoint.heartDistance) / span, 0, 1)
    end

    return {
        pos = mathUtils.Lerp(fromPoint.pos, toPoint.pos, fraction),
        rot = Quaternion.SLerp(fromPoint.rot, toPoint.rot, fraction)
    }
end

---Returns the bank channel, in rads at a distance.
---Absolute: the bank against the horizon, rolling the short way to each target.
---Relative: the roll added since the section start.
---@param start ProfileStart
---@param midDistance number
---@param length number
---@param curveIn function
---@param curveOut function
---@return function
local function GetBankChannel(start, midDistance, length, curveIn, curveOut)
    local startValue = 0
    local midValue = ProfileMode.profileMidBank
    local endValue = midValue + ProfileMode.profileEndBank
    if not ProfileMode.profileBankRelative then
        startValue = math.deg(start.bank)
        midValue = startValue + ShortestRoll(ProfileMode.profileMidBank - startValue)
        endValue = midValue + ShortestRoll(ProfileMode.profileEndBank - midValue)
    end

    return function(distance)
        return math.rad(EvaluateChannel(startValue, midValue, endValue,
            distance, midDistance, length, curveIn, curveOut))
    end
end

---Integrates the whole section from the end of the TrackViz data.
---Same integration as ForceLock, but the target forces and bank follow the profile.
---@param start ProfileStart
---@return ProfilePlan?
function ProfileMode.ComputePlan(start)
    ProfileMode.stalled = false

    local chunkCount = ProfileMode.GetChunkCount()
    local length = chunkCount * ProfileMode.CHUNK_LENGTH
    local midDistance = length * mathUtils.Clamp(ProfileMode.profileMidPercent, 0, 100) / 100
    local curveIn = CURVES[ProfileMode.profileCurveIn] or CURVES[0]
    local curveOut = CURVES[ProfileMode.profileCurveOut] or CURVES[0]
    local levelTurns = ProfileMode.profileLevelTurns
    local bankRelative = ProfileMode.profileBankRelative

    local startVert = GetStartVertSetting(start)
    local function vertGAt(distance)
        return EvaluateChannel(startVert, ProfileMode.profileMidVertG, ProfileMode.profileEndVertG,
            distance, midDistance, length, curveIn, curveOut)
    end
    local function latGAt(distance)
        return EvaluateChannel(start.latG, ProfileMode.profileMidLatG, ProfileMode.profileEndLatG,
            distance, midDistance, length, curveIn, curveOut)
    end
    local bankAt = GetBankChannel(start, midDistance, length, curveIn, curveOut)

    local levelLimited = false
    local function effectiveVertGAt(distance, rotation)
        local vertG = vertGAt(distance)
        if levelTurns then
            local factor, limited = GetLevelFactor(rotation)
            levelLimited = levelLimited or limited
            vertG = vertG * factor
        end
        return vertG
    end

    -- Same starting point as ForceLock
    local lastDatapoint = Datastore.datapoints[#Datastore.datapoints]
    local heartline = Datastore.heartlineOffset:GetY()
    local point = FvdMode.GetPoint(
        (
            lastDatapoint.measurements[1].transform:GetPos() +
            lastDatapoint.measurements[1].transform:GetOr():GetU() * heartline
        ),
        lastDatapoint.measurements[1].transform:GetOr(),
        lastDatapoint.originVelocity,
        lastDatapoint.originVelocity,
        0
    )

    local boundaries = { { pos = point.pos, rot = point.rot } }
    local midPoint = nil
    if midDistance <= 0 then
        midPoint = boundaries[1]
    end
    local samples = { { pos = point.pos, rot = point.rot, distance = 0 } }
    local tPoints = { Datastore.trackEntityTransform:ToWorldPos(point.pos) }
    local lastLinePos = point.pos
    local nextBoundary = ProfileMode.CHUNK_LENGTH
    local iter = 0

    while #boundaries <= chunkCount do
        if point.velo < ProfileMode.MIN_VELOCITY or iter >= ProfileMode.MAX_ITERATIONS then
            logger:Info("Plan stalled at " .. global.tostring(point.heartDistance) .. "m")
            ProfileMode.stalled = true
            return nil
        end

        local lastPoint = point
        local userAccel = Vector3:new(
            latGAt(lastPoint.heartDistance),
            effectiveVertGAt(lastPoint.heartDistance, lastPoint.rot),
            0
        )
        point = FvdMode.StepPoint(lastPoint, userAccel, 0, heartline, ProfileMode.TIMESTEP)

        -- Relative: add the roll of the step. Absolute: correct to the target bank, so the
        -- bank is exact whatever the forces did to it, except where it is undefined.
        local roll = bankAt(point.heartDistance) - bankAt(lastPoint.heartDistance)
        if not bankRelative and not IsNearVertical(point.rot) then
            roll = WrapAngle(bankAt(point.heartDistance) - GetBankOf(point.rot))
        end
        point.rot = RollAroundForward(point.rot, roll)

        if midPoint == nil and point.heartDistance >= midDistance then
            midPoint = InterpolatePoint(lastPoint, point, midDistance)
        end

        while #boundaries <= chunkCount and point.heartDistance >= nextBoundary do
            boundaries[#boundaries + 1] = InterpolatePoint(lastPoint, point, nextBoundary)
            nextBoundary = nextBoundary + ProfileMode.CHUNK_LENGTH
        end

        if Vector3.Length(point.pos - lastLinePos) >= ProfileMode.LINE_POINT_SPACING then
            tPoints[#tPoints + 1] = Datastore.trackEntityTransform:ToWorldPos(point.pos)
            samples[#samples + 1] = { pos = point.pos, rot = point.rot, distance = point.heartDistance }
            lastLinePos = point.pos
        end

        iter = iter + 1
    end

    local endPoint = boundaries[#boundaries]
    midPoint = midPoint or endPoint
    tPoints[#tPoints + 1] = Datastore.trackEntityTransform:ToWorldPos(endPoint.pos)
    samples[#samples + 1] = { pos = endPoint.pos, rot = endPoint.rot, distance = length }

    ---@type ProfilePlan
    return {
        boundaries = boundaries,
        samples = samples,
        tPoints = tPoints,
        midPoint = midPoint,
        datapoints = Datastore.datapoints,
        heartline = heartline,
        start = start,
        midVertG = effectiveVertGAt(midDistance, midPoint.rot),
        endVertG = effectiveVertGAt(length, endPoint.rot),
        levelLimited = levelLimited
    }
end

---Returns the index of the boundary a piece starts from, preferring the latest one.
---@param startPos any Coaster-space track position.
---@return integer?
function ProfileMode.FindBoundaryIndex(startPos)
    local plan = ProfileMode.plan
    if plan == nil then
        return nil
    end

    for i = #plan.boundaries, 1, -1 do
        local boundary = plan.boundaries[i]
        local trackPos = boundary.pos - boundary.rot:GetU() * plan.heartline
        if Vector3.Length(startPos - trackPos) <= ProfileMode.MATCH_DISTANCE then
            return i
        end
    end
    return nil
end

---Recomputes the plan when the settings or the TrackViz data changed.
---Like ForceLock, the TrackViz data must end at the start of the new piece.
---@param startT any The start transform given to StaticBuildEndPoint.
function ProfileMode.UpdatePlan(startT)
    if not Datastore.HasData() then
        ProfileMode.ClearPlan()
        return
    end

    local walkEnd = Datastore.datapoints[#Datastore.datapoints].measurements[1].transform:GetPos()
    if Vector3.Length(startT:GetPos() - walkEnd) > ProfileMode.MATCH_DISTANCE then
        -- While a piece is placed, the game also asks from further along the section: keep the plan.
        if ProfileMode.FindBoundaryIndex(startT:GetPos()) == nil then
            ProfileMode.ClearPlan()
        end
        return
    end

    local plan = ProfileMode.plan
    if plan ~= nil and not ProfileMode.planDirty and plan.datapoints == Datastore.datapoints then
        return
    end

    local start = GetStart()
    SeedFromStart(start, walkEnd, startT)

    ProfileMode.planDirty = false
    ProfileMode.plan = ProfileMode.ComputePlan(start)
    ProfileMode.endIndex = 1
    ProfileMode.offSection = false
    ProfileMode.syncedWalk = Datastore.datapoints
    ProfileMode.hookLogged = {}
    ProfileMode.ShowPlan()
end

---Reads where the real track end is on the section, from the TrackViz walk, and
---locks or finishes the section. Build calls can't tell: the game also asks for
---pieces further along than the track end.
---@param fromCommit boolean Whether a piece was just placed.
local function SyncProgress(fromCommit)
    ProfileMode.syncedWalk = Datastore.datapoints
    local plan = ProfileMode.plan
    if plan == nil then
        return
    end

    -- The walk shows the track end only when the train got there (it stops at 0 speed otherwise).
    local lastDatapoint = Datastore.HasData() and Datastore.datapoints[#Datastore.datapoints] or nil
    if lastDatapoint ~= nil and lastDatapoint.originVelocity >= ProfileMode.MIN_VELOCITY then
        local index = ProfileMode.FindBoundaryIndex(lastDatapoint.measurements[1].transform:GetPos())
        if index == nil then
            ProfileMode.offSection = ProfileMode.locked
            return
        end
        ProfileMode.endIndex = index
        ProfileMode.offSection = false
    elseif fromCommit then
        -- No usable walk: count the piece as the next chunk.
        ProfileMode.endIndex = ProfileMode.endIndex + 1
    else
        return
    end

    if ProfileMode.endIndex > 1 then
        ProfileMode.locked = true
    end
    if ProfileMode.endIndex >= #plan.boundaries then
        logger:Info("Section finished")
        ProfileMode.ResetSection()
        ProfileMode.refreshRequested = true
    end
end

---Hook for TrackEditValues.StaticBuildEndPoint while in Profile mode.
---Returns the end of the chunk that starts where the new piece starts.
---@param originalMethod function
---@param startT any
---@param tData any
---@return any
---Only maps the start to its chunk: the section is locked and finished from placed
---pieces (OnCommit), since the game also calls this for starts further along.
function ProfileMode.StaticBuildEndPoint_Hook(originalMethod, startT, tData)
    local startPos = startT:GetPos()
    if not ProfileMode.locked then
        ProfileMode.UpdatePlan(startT)
    end

    local index = ProfileMode.FindBoundaryIndex(startPos)
    if index ~= nil and not ProfileMode.hookLogged[index] then
        ProfileMode.hookLogged[index] = true
        logger:Info("Build hook: start on boundary " .. index .. "/" .. #ProfileMode.plan.boundaries)
    end

    if index == nil or index >= #ProfileMode.plan.boundaries then
        return originalMethod(startT, tData)
    end

    local boundary = ProfileMode.plan.boundaries[index + 1]
    return api.track.CreateJoinPoint(
        boundary.pos - boundary.rot:GetU() * ProfileMode.plan.heartline,
        boundary.rot:ToYawPitchRoll(),
        0
    )
end

---Sets a marker gizmo on a plan point.
---@param gizmo protrack.gizmo.TrackPointGizmo?
---@param point ProfileBoundary
---@param latG number
---@param vertG number
local function SetMarker(gizmo, point, latG, vertG)
    if gizmo == nil then
        return
    end
    gizmo:SetTransform(Datastore.trackEntityTransform:ToWorld(TransformQ.FromOrPos(point.rot, point.pos)))
    gizmo:SetGForce(Vector3:new(latG, vertG, 0))
    gizmo:SetVisible(true)
end

---Returns the preview lines that show the bank: two rails at track level, a tie
---across them every TIE_SPACING, and a post up to the heartline at every chunk boundary.
---@param plan ProfilePlan
---@return table[] segments World-space {from, to} pairs.
function ProfileMode.GetRibbonSegments(plan)
    local entity = Datastore.trackEntityTransform
    local segments = {}
    local lastLeft = nil
    local lastRight = nil
    local nextTie = 0

    for _, sample in ipairs(plan.samples) do
        local trackPos = sample.pos - sample.rot:GetU() * plan.heartline
        local side = sample.rot:GetR() * ProfileMode.RAIL_HALF_WIDTH
        local left = entity:ToWorldPos(trackPos - side)
        local right = entity:ToWorldPos(trackPos + side)

        if lastLeft ~= nil then
            segments[#segments + 1] = { lastLeft, left }
            segments[#segments + 1] = { lastRight, right }
        end
        if sample.distance >= nextTie then
            segments[#segments + 1] = { left, right }
            nextTie = (math.floor(sample.distance / ProfileMode.TIE_SPACING) + 1) * ProfileMode.TIE_SPACING
        end
        lastLeft = left
        lastRight = right
    end

    for _, boundary in ipairs(plan.boundaries) do
        segments[#segments + 1] = {
            entity:ToWorldPos(boundary.pos - boundary.rot:GetU() * plan.heartline),
            entity:ToWorldPos(boundary.pos)
        }
    end

    return segments
end

---Draws the plan line and the mid and end markers.
function ProfileMode.ShowPlan()
    local plan = ProfileMode.plan
    if plan == nil then
        ProfileMode.HidePlan()
        return
    end

    ProfileMode.line:SetPoints(plan.tPoints)
    ProfileMode.line:SetSegments(ProfileMode.GetRibbonSegments(plan))
    ProfileMode.line:DrawPoints()
    SetMarker(ProfileMode.midGizmo, plan.midPoint, ProfileMode.profileMidLatG, plan.midVertG)
    SetMarker(ProfileMode.endGizmo, plan.boundaries[#plan.boundaries], ProfileMode.profileEndLatG, plan.endVertG)
end

---Hides the plan line and markers.
function ProfileMode.HidePlan()
    if ProfileMode.line ~= nil then
        ProfileMode.line:ClearPoints()
    end
    for _, gizmo in ipairs({ ProfileMode.midGizmo, ProfileMode.endGizmo }) do
        gizmo:SetVisible(false)
    end
end

---Removes the current plan.
function ProfileMode.ClearPlan()
    if ProfileMode.plan ~= nil then
        ProfileMode.plan = nil
        ProfileMode.HidePlan()
    end
    ProfileMode.hookLogged = {}
end

---Ends the current section. Built chunks stay as normal track.
function ProfileMode.ResetSection()
    ProfileMode.ClearPlan()
    ProfileMode.locked = false
    ProfileMode.stalled = false
    ProfileMode.offSection = false
    ProfileMode.endIndex = 1
    ProfileMode.planDirty = true
end

---Sets a setting from the UI.
---@param name string One of ProfileMode.SETTINGS.
---@param value any
function ProfileMode.SetSetting(name, value)
    SetValue(name, value)

    -- The values mean something else now, start them again from the track end.
    if name == "profileBankRelative" then
        ProfileMode.reseedBank = true
    elseif name == "profileLevelTurns" then
        ProfileMode.reseedVertG = true
    end

    ProfileMode.planDirty = true
end

---Sets up the mode. Called once the UI datastore context exists.
---@param context any The ProTrack datastore context.
function ProfileMode.Init(context)
    ProfileMode.context = context
    ProfileMode.line = require("protrack.gizmo.displayline"):new()
    for _, name in ipairs(ProfileMode.SETTINGS) do
        SetDatastore(name, ProfileMode[name])
    end
end

---Spawns the mid and end markers.
---Note: this method should be called within a coroutine that can yield.
function ProfileMode.SpawnMarkers()
    ProfileMode.midGizmo = TrackPointGizmo.new()
    ProfileMode.endGizmo = TrackPointGizmo.new()
    ProfileMode.midGizmo:SetVisible(false)
    ProfileMode.endGizmo:SetVisible(false)
end

---Shuts down the mid and end markers.
function ProfileMode.ShutdownMarkers()
    for _, gizmo in ipairs({ ProfileMode.midGizmo, ProfileMode.endGizmo }) do
        gizmo:Shutdown()
    end
    ProfileMode.midGizmo = nil
    ProfileMode.endGizmo = nil
end

function ProfileMode.StartEdit()
    ProfileMode.ShowPlan()
end

function ProfileMode.EndEdit()
    ProfileMode.HidePlan()
end

---Called after a piece was committed.
function ProfileMode.OnCommit()
    ProfileMode.hookLogged = {}
    -- TrackViz was just re-walked to the new track end.
    SyncProgress(true)
    -- Rebuild the preview next frame with the new data.
    ProfileMode.refreshRequested = true
end

---Ticks the mode and updates the UI.
---@return boolean refresh Whether the track builder should be refreshed.
function ProfileMode.Advance()
    -- TrackViz re-walked without a placement (undo, delete): follow the track end.
    if Datastore.datapoints ~= ProfileMode.syncedWalk then
        SyncProgress(false)
    end

    local refresh = ProfileMode.refreshRequested
    ProfileMode.refreshRequested = false

    if ProfileMode.cancelRequested then
        ProfileMode.cancelRequested = false
        logger:Info("Section cancelled")
        ProfileMode.ResetSection()
        refresh = true
    end

    local plan = ProfileMode.plan
    local chunkCount = ProfileMode.GetChunkCount()
    if plan ~= nil then
        chunkCount = #plan.boundaries - 1
        SetDatastore("profileStartVertG", plan.start.vertG)
        SetDatastore("profileStartLatG", plan.start.latG)
        SetDatastore("profileStartBank", math.deg(plan.start.bank))
        SetDatastore("profileMidBankResult", math.deg(GetBankOf(plan.midPoint.rot)))
        SetDatastore("profileEndBankResult", math.deg(GetBankOf(plan.boundaries[#plan.boundaries].rot)))
    end

    SetDatastore("profileHasPlan", plan ~= nil)
    SetDatastore("profileLocked", ProfileMode.locked)
    SetDatastore("profileStalled", ProfileMode.stalled)
    SetDatastore("profileLevelLimited", plan ~= nil and plan.levelLimited)
    SetDatastore("profileEndIndex", ProfileMode.endIndex)
    SetDatastore("profileOffSection", ProfileMode.offSection)
    SetDatastore("profileChunkCount", chunkCount)

    return refresh
end

return ProfileMode
