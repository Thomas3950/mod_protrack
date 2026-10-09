-----------------------------------------------------------------------
--/  @file    Managers.SceneryLineManager.lua
--/  @author  Inaki
--/  @version 1.0
--/
--/  @brief  Boilerplate template for a park manager script
--/  @see    https://github.com/OpenNaja/ACSE
-----------------------------------------------------------------------
local global = _G
---@type Api
---@diagnostic disable-next-line: undefined-field
local api = global.api
local pairs = global.pairs
local coroutine = global.coroutine
local require = global.require
local mathUtils = require("Common.mathUtils")

---@diagnostic disable-next-line: deprecated
local module = global.module

local Mutators = require("Environment.ModuleMutators")
local Vector3 = require("Vector3")
local HookManager = require("forgeutils.hookmanager")
local Utils = require("protrack.utils")
local FvdMode = require("protrack.modes.fvdmode")
local AdvMoveMode = require("protrack.modes.advancedmovemode")

local TrackPointGizmo = require("protrack.gizmo.trackpointgizmo")
local TrackReferenceGizmo = require("protrack.gizmo.trackreferencegizmo")

local Cam = require("protrack.cam")
local Datastore = require("protrack.datastore")
local FrictionHelper = require("database.frictionhelper")
local InputEventHandler = require("Components.Input.InputEventHandler")
local ForceOverlay = require("protrack.ui.forceoverlay")
local UnitConversion = require("Helpers.UnitConversion")

local logger = require("forgeutils.logger").Get("ProTrackManager", "INFO")
local Diag = require("protrack.diagnostics")

-- Profile mode is optional: if it fails, ProTrack keeps working and the error is shown in the panel.
---@type ProfileMode?
local ProfileMode = nil
local profileError = nil
do
    local ok, result = global.pcall(require, "protrack.modes.profilemode")
    if ok then
        ProfileMode = result
    else
        profileError = global.tostring(result)
        Diag.Log("ERROR", "Profile mode failed to load: " .. profileError)
    end
end

--/ Main class definition
---@class protrackManager
local protrackManager = module(..., Mutators.Manager())
protrackManager.simulationTime = 0
---@type TrackEditMode?
protrackManager.trackEditMode = nil
protrackManager.editingTrackEnd = false
protrackManager.inCamera = false
protrackManager.cameraIsHeartlineMode = false
protrackManager.inputEventHandler = nil
protrackManager.line = nil

---@type WorldAPIs_InputManager
protrackManager.inputManagerAPI = nil
protrackManager.tWorldAPIs = nil

protrackManager.gizmoInitCoroutine = nil
protrackManager.overlayUI = nil

---@type FrictionValues
protrackManager.frictionValues = nil

protrackManager.context = nil
protrackManager.trackMode = 0
protrackManager.newTrackModeRequest = 0
protrackManager.playingInDir = 0

-- Gizmo

---@type DraggableWidgets
protrackManager.draggableWidget = nil

---@type protrack.gizmo.TrackReferenceGizmo
protrackManager.referencePointGizmo = nil

---@type protrack.gizmo.TrackPointGizmo[]
protrackManager.followerGizmos = nil
protrackManager.distances = {}

protrackManager.staticSelf = nil

local NORMAL_TRACKMODE = 0
local FVD_TRACKMODE = 1
local ADVMOVE_TRACKMODE = 2
local PROFILE_TRACKMODE = 3

---Sets a value on an object, while also setting to the datastore
---@param name any
---@param value any
local function SetVariableOnObjectWithDatastore(object, name, value)
    object[name] = value
    api.ui2.SetDataStoreElement(protrackManager.context, name, value)
end

---Sets a value, while also setting to the datastore
---@param name any
---@param value any
local function SetVariableWithDatastore(name, value)
    SetVariableOnObjectWithDatastore(protrackManager, name, value)
end

---Calls a Profile mode function. On error, Profile mode is turned off,
---the error is shown in the panel, and the rest of ProTrack carries on.
---@param functionName string
---@return any
local function CallProfile(functionName, ...)
    if ProfileMode == nil then
        return nil
    end

    local ok, result = global.pcall(ProfileMode[functionName], ...)
    if ok then
        return result
    end

    ProfileMode = nil
    profileError = functionName .. ": " .. global.tostring(result)
    Diag.Log("ERROR", "Profile mode stopped: " .. profileError)
    if protrackManager.context ~= nil then
        api.ui2.SetDataStoreElement(protrackManager.context, "profileError", profileError)
    end
    return nil
end

---Removes the editor widgets that the current track mode replaces.
---@param _tItems table
local function HideEditorWidgets(_tItems)
    local self = protrackManager.staticSelf
    if self.trackEditMode == nil or not self.editingTrackEnd then
        return
    end

    if (self.trackMode == FVD_TRACKMODE) and Datastore.HasData() then -- forcelock, remove 1 and 3
        _tItems[1] = {}
        _tItems[3] = {}
    elseif (self.trackMode == ADVMOVE_TRACKMODE) then -- Advanced widget, remove all
        _tItems[1] = {}
        _tItems[2] = {}
        _tItems[3] = {}
        _tItems[4] = {}
    elseif (self.trackMode == PROFILE_TRACKMODE) and ProfileMode ~= nil
        and (Datastore.HasData() or ProfileMode.locked) then -- profile drives the piece, remove all
        _tItems[1] = {}
        _tItems[2] = {}
        _tItems[3] = {}
        _tItems[4] = {}
    end
end

---Returns the end point the current track mode wants, or nil for the game's own.
---@return any
local function BuildEndPoint(originalMethod, startT, tData)
    local self = protrackManager.staticSelf
    if (self.trackMode == FVD_TRACKMODE) then
        return FvdMode.StaticBuildEndPoint_Hook(originalMethod, startT, tData)
    elseif (self.trackMode == ADVMOVE_TRACKMODE) then
        return AdvMoveMode.StaticBuildEndPoint_Hook(originalMethod, startT, tData)
    elseif (self.trackMode == PROFILE_TRACKMODE) and self:IsAddingAfterSelection() then
        return CallProfile("StaticBuildEndPoint_Hook", originalMethod, startT, tData)
    end
    return nil
end

-- Every hook is guarded: a Lua error inside ProTrack is logged in the panel
-- (Diagnostics tab) and the game's own code still runs, instead of crashing the game.
function protrackManager.SetupHooks()
    Diag.Install()
    logger:Info("Setup FU hooks")
    HookManager:AddHook(
        "UI.CoasterWidgetsUI",
        "SetWidgets",
        function(originalMethod, slf, _tItems)
            Diag.Guard("Hide editor widgets", HideEditorWidgets, _tItems)
            originalMethod(slf, _tItems)
        end
    )

    -- Setup hook for the build end point
    HookManager:AddHook(
        "Editors.Track.TrackEditValues",
        "StaticBuildEndPoint",
        function(originalMethod, startT, tData)
            local ok, joinPoint = Diag.Guard("Build end point", BuildEndPoint, originalMethod, startT, tData)
            if ok and joinPoint ~= nil then
                return joinPoint
            end
            return originalMethod(startT, tData)
        end
    )

    HookManager:AddHook(
        "Editors.Track.TrackEditMode",
        "TransitionIn",
        function(originalMethod, slf, _startTrack, _startSelection, _bDontRequestTrainRespawn)
            originalMethod(slf, _startTrack, _startSelection, _bDontRequestTrainRespawn)
            Diag.Guard("Start edit mode", protrackManager.staticSelf.StartEditMode, protrackManager.staticSelf, slf)
        end
    )

    HookManager:AddHook(
        "Editors.Track.TrackEditMode",
        "Shutdown",
        function(originalMethod, slf)
            originalMethod(slf)
            Diag.Guard("End edit mode", protrackManager.staticSelf.EndEditMode, protrackManager.staticSelf)
        end
    )

    HookManager:AddHook(
        "Editors.Track.TrackEditSelection",
        "CommitPreview",
        function(originalMethod, slf)
            local ret = originalMethod(slf)
            Diag.Guard("After placing a piece", function()
                protrackManager.staticSelf:NewWalk()
                if protrackManager.staticSelf.trackMode == PROFILE_TRACKMODE then
                    CallProfile("OnCommit")
                end
            end)
            return ret
        end
    )

    logger:Info("Done")
end

--
-- @Brief Init function for this manager
-- @param _tProperties  a table with initialization data for all the managers.
-- @param _tEnvironment a reference to the current Environment
--
-- The Init function is the first function of the manager being called by the game.
-- This function is used to initialize all the custom data required, however at this
-- stage the rest of the managers might not be available.
--
function protrackManager.Init(self, _tProperties, _tEnvironment)
    logger:Info("Init")
    protrackManager.staticSelf = self
end

--
-- @Brief Activate function for this manager
--
-- Activate is called after all the Managers of this environment have been initialised,
-- and it is safe to assume that access to the rest of the game managers is guaranteed to
-- work.
--
function protrackManager.Activate(self)
    -- Activate datastore context, this is essential for UI integration
    protrackManager.context = api.ui2.GetDataStoreContext("ProTrack")
    Diag.SetContext(protrackManager.context)
    Diag.Guard("Activate", protrackManager.ActivateProTrack, self)
end

function protrackManager.ActivateProTrack(self)
    -- Our entry point simply calls inject on the submode override file:
    logger:Info("Completing spawns...")
    Cam.GetPreviewCameraEntity()
    logger:Info("Finished Camera")

    local line = require("protrack.gizmo.displayline")
    self.line = line:new()
    FvdMode.line = line:new()
    CallProfile("Init", protrackManager.context)
    if profileError ~= nil then
        api.ui2.SetDataStoreElement(protrackManager.context, "profileError", profileError)
    end

    logger:Info("Initialising UI")
    SetVariableWithDatastore(false, "cameraIsHeartlineMode")

    Datastore.heartlineOffset = Vector3.Zero
    ---@type ForceOverlay
    protrackManager.overlayUI = ForceOverlay:new(
        function()
            logger:Info("UI is setup and ready")

            -- Button listeners

            protrackManager.overlayUI:AddListener_ReanchorRequested(
                function()
                    self:Anchor()
                end,
                nil
            )

            protrackManager.overlayUI:AddListener_ResimulateRequested(
                function()
                    self:Resimulate()
                end,
                nil
            )

            protrackManager.overlayUI:AddListener_ChangeCamModeRequested(
                function()
                    if not self.inCamera then
                        self:StartTrackCamera()
                    else
                        self:StopTrackCamera()
                    end
                end,
                nil
            )

            protrackManager.overlayUI:AddListener_PlayChanged(
                function(newDir)
                    SetVariableWithDatastore("playingInDir", newDir)
                end,
                nil
            )

            -- Value listeners

            protrackManager.overlayUI:AddListener_HeartlineValueChanged(
                function(newVal)
                    Datastore.heartlineOffset = Vector3:new(0, newVal, 0)
                    self:NewWalk()
                    self:SetTrackBuilderDirty()
                end,
                nil
            );

            protrackManager.overlayUI:AddListener_VertGValueChanged(
                function(newVal)
                    SetVariableOnObjectWithDatastore(FvdMode, "forceLockVertG", newVal)
                    self:SetTrackBuilderDirty()
                end,
                nil
            );

            protrackManager.overlayUI:AddListener_LatGValueChanged(
                function(newVal)
                    SetVariableOnObjectWithDatastore(FvdMode, "forceLockLatG", newVal)
                    self:SetTrackBuilderDirty()
                end,
                nil
            );

            protrackManager.overlayUI:AddListener_TrackModeChanged(
                function(newTrackMode)
                    -- Call is delayed like this to exit
                    -- the UI thread.
                    self.newTrackModeRequest = newTrackMode
                    -- self:SwitchTrackMode(newTrackMode)
                end,
                nil
            );

            protrackManager.overlayUI:AddListener_HeartlineCamChanged(
                function(heartlineCamMode)
                    SetVariableWithDatastore("cameraIsHeartlineMode", heartlineCamMode)
                end,
                nil
            );

            protrackManager.overlayUI:AddListener_TimeChanged(
                function(newTime)
                    self.simulationTime = newTime * Datastore.GetTimeLength()
                end,
                nil
            );

            -- Profile mode listeners

            if ProfileMode ~= nil then
                for _, settingName in global.ipairs(ProfileMode.SETTINGS) do
                    protrackManager.overlayUI:AddListener_ProfileSettingChanged(
                        settingName,
                        function(newVal)
                            CallProfile("SetSetting", settingName, newVal)
                            self:SetTrackBuilderDirty()
                        end,
                        nil
                    );
                end
            end

            protrackManager.overlayUI:AddListener_ProfileCancelRequested(
                function()
                    -- Handled in Advance to exit the UI thread.
                    if ProfileMode ~= nil then
                        ProfileMode.cancelRequested = true
                    end
                end,
                nil
            );

            -- Diagnostics listeners

            protrackManager.overlayUI:AddListener_DiagStepModeChanged(
                function(stepMode)
                    Diag.SetStepMode(stepMode)
                end,
                nil
            );

            protrackManager.overlayUI:AddListener_DiagFileLogRequested(
                function()
                    -- Handled in Advance to exit the UI thread.
                    Diag.RequestFileLog()
                end,
                nil
            );

            protrackManager.overlayUI:AddListener_DiagClearRequested(
                function()
                    Diag.Clear()
                end,
                nil
            );
        end
    )
end

function protrackManager.ZeroData(self)
    self:ClearWalkerOrigin()
    self.newTrackModeRequest = 0
    self.trackEditMode = nil
    self.editingTrackEnd = false
    self.simulationTime = 0
    self.tWorldAPIs = nil
    self.inputManagerAPI = nil
    Datastore.datapoints = nil
    CallProfile("ResetSection")

    -- Datastore updates
    SetVariableWithDatastore("playingInDir", 0)
    SetVariableWithDatastore("trackMode", 0)
    SetVariableOnObjectWithDatastore(FvdMode, "forceLockVertG", 1)
    SetVariableOnObjectWithDatastore(FvdMode, "forceLockLatG", 0)
end

function protrackManager.StartEditMode(self, trackEditMode)
    logger:Info("Starting edit mode!")

    -- Reset data
    logger:Info("Resetting data")
    self:ZeroData()

    ---@type TrackEditMode
    self.trackEditMode = trackEditMode
    self.tWorldAPIs = api.world.GetWorldAPIs()
    self.inputManagerAPI = self.tWorldAPIs.InputManager

    local trackEntity = self.trackEditMode.tActiveData:GetTrackEntity()
    Datastore.trackEntityTransform = api.transform.GetTransform(trackEntity)

    ---@diagnostic disable-next-line: assign-type-mismatch
    self.frictionValues = FrictionHelper.GetFrictionValues(api.track.GetTrackHolder(trackEntity))

    -- Our api doesn't contain this (defined by object base) so we need a pragma
    ---@diagnostic disable-next-line: undefined-field
    self.inputEventHandler = InputEventHandler:new()
    self.inputEventHandler:Init()

    self.inputEventHandler:AddKeyPressedEvent(
        "RotateObject",
        function()
            self:Anchor()
            return true
        end
    )

    self.inputEventHandler:AddKeyPressedEvent(
        "AdvancedMove",
        function()
            if self.trackMode == ADVMOVE_TRACKMODE and self.editingTrackEnd then
                AdvMoveMode.SwitchTransformMode()
            else
                self:Resimulate()
            end

            return true
        end
    )

    self.inputEventHandler:AddKeyPressedEvent(
        "ScaleObject",
        function()
            logger:Info("Toggle ride camera!")
            if not self.inCamera then
                self:StartTrackCamera()
            else
                self:StopTrackCamera()
            end
            return true
        end
    )

    self.inputEventHandler:AddKeyPressedEvent(
        "ToggleAlignToSurface",
        function()
            logger:Info("Toggle camera mode!")
            SetVariableWithDatastore("cameraIsHeartlineMode", not self.cameraIsHeartlineMode)
            return true
        end
    )

    logger:Info("Spawning draggable widget")
    local DraggableWidgets = require("Editors.Scenery.Utils.DraggableWidgets")
    self.draggableWidget = DraggableWidgets:new()
    logger:Info("Finished Draggable Widget")

    logger:Info("Spawning world-space gizmos")

    self.followerGizmos = {
        [1] = TrackPointGizmo.new(),
        [2] = TrackPointGizmo.new(),
        [3] = TrackPointGizmo.new(),
    }
    for _, gizmo in global.ipairs(self.followerGizmos) do
        gizmo:SetVisible(false)
    end
    CallProfile("SpawnMarkers")

    self.referencePointGizmo = TrackReferenceGizmo.new()
    self.referencePointGizmo:SetVisible(false)
    logger:Info("Finished world-space gizmos")

    self.draggableWidget:BindButtonHandlers(
        function()
            -- Confirm (unused)
        end,
        function()
            -- Cancel (unused)
        end,
        function()
            -- Move button (unused)
        end,
        function()
            -- Toggle mode
            AdvMoveMode.SwitchTransformMode()
            protrackManager.staticSelf:SetTrackBuilderDirty()
        end,
        function()
            -- Toggle transform space
            AdvMoveMode.SwitchTransformSpace()
            protrackManager.staticSelf:SetTrackBuilderDirty()
        end
    )

    protrackManager.overlayUI:Show()
end

local function shutdownGizmo(gizmo)
    if gizmo ~= nil then
        gizmo:Shutdown()
    end
end

function protrackManager.EndEditMode(self)
    self:ZeroData()
    protrackManager.overlayUI:Hide()

    shutdownGizmo(self.draggableWidget)
    shutdownGizmo(self.referencePointGizmo)

    self.draggableWidget = nil

    -- Shut down all gizmos
    for _, gizmo in global.ipairs(self.followerGizmos) do
        shutdownGizmo(gizmo)
    end
    self.followerGizmos = nil
    CallProfile("ShutdownMarkers")
end

function protrackManager.SwitchTrackMode(self, newTrackMode)
    self:EndTrackEdit()
    if self.trackMode == PROFILE_TRACKMODE then
        CallProfile("ResetSection")
    end
    SetVariableWithDatastore("trackMode", newTrackMode)
    self:StartTrackEdit()
    self:SetTrackBuilderDirty()
end

function protrackManager.StartTrackEdit(self)
    if self.trackMode == ADVMOVE_TRACKMODE then
        AdvMoveMode.StartEdit(self.draggableWidget, Datastore.trackEntityTransform)
    elseif self.trackMode == PROFILE_TRACKMODE then
        CallProfile("StartEdit")
    end
end

function protrackManager.EndTrackEdit(self)
    if self.trackMode == FVD_TRACKMODE then
        FvdMode.EndEdit()
    elseif self.trackMode == ADVMOVE_TRACKMODE then
        AdvMoveMode.EndEdit()
    elseif self.trackMode == PROFILE_TRACKMODE then
        CallProfile("EndEdit")
    end
end

--- Returns whether the editor is adding a piece after the selection.
---@return boolean
function protrackManager.IsAddingAfterSelection(self)
    return self.trackEditMode ~= nil
        and self.trackEditMode.tActiveData ~= nil
        and self.trackEditMode.tActiveData:IsAddingAfterSelection()
end

function protrackManager.SetTrackBuilderDirty(self)
    if (self.trackEditMode ~= nil and self.trackEditMode.tActiveData ~= nil) then
        self.trackEditMode.tActiveData.bEditValuesDirty = true
        self.trackEditMode.trackHandles:SetTrackWidgetsFromEditValues() -- refresh ui widgets
    end
end

--- Anchors on the train (button or keybind), step by step in step-by-step mode.
function protrackManager.Anchor(self)
    Diag.Run("Anchor", function()
        self:NewTrainPosition()
    end)
end

--- Re-runs the simulation from the current anchor.
function protrackManager.Resimulate(self)
    Diag.Run("Resimulate", function()
        self:NewWalk()
    end)
end

function protrackManager.NewTrainPosition(self)
    local trackEntity = self.trackEditMode.tActiveData:GetTrackEntity()

    -- Early exit
    Diag.Step("Anchor: find the train")
    Datastore.trackWalkerOrigin = Utils.GetFirstCarData(trackEntity)
    if Datastore.trackWalkerOrigin == nil then
        Diag.Log("INFO", "Anchor: no train found on the track")
        return
    end

    if mathUtils.ApproxEquals(Datastore.trackWalkerOrigin.speed, 0) then
        Diag.Log("INFO", "Anchor: the train is not moving")
        return
    end

    -- set dt to 0 since we are moving refpoint
    self.simulationTime = 0
    self:NewWalk()
    Diag.Step("Anchor: refresh the track editor")
    self:SetTrackBuilderDirty()
    Diag.Step("Anchor: live display (gizmos, camera, readouts) starts next frame")
end

function protrackManager.ClearWalkerOrigin(self)
    Datastore.trackWalkerOrigin = nil
    self.distances = nil
    self.line:ClearPoints()
    if self.referencePointGizmo ~= nil then
        self.referencePointGizmo:SetVisible(false)
    end
    if self.followerGizmos ~= nil then
        for _, gizmo in global.ipairs(self.followerGizmos) do
            gizmo:SetVisible(false)
        end
    end
    self:StopTrackCamera()

    -- Datastore
    api.ui2.SetDataStoreElement(protrackManager.context, "hasData", false)
end

function protrackManager.NewWalk(self)
    Datastore.datapoints = nil
    if not Utils.IsTrackOriginValid(Datastore.trackWalkerOrigin) then
        logger:Info("Invalid!")
        self:ClearWalkerOrigin()
        return
    end

    local halfLength = Datastore.trackWalkerOrigin.trainLength / 2.0
    self.distances = {
        [1] = halfLength,
        [2] = -halfLength
    }

    Diag.Step("Walk: simulate the ride (train length " .. global.tostring(Datastore.trackWalkerOrigin.trainLength) .. " m)")
    Datastore.datapoints = Utils.WalkTrack(
        Datastore.trackWalkerOrigin,
        self.distances,
        self.frictionValues,
        Datastore.heartlineOffset,
        Datastore.tSimulationDelta
    )

    -- if nil, our point is BS.
    -- Need to clear everything

    if not Datastore.HasData() then
        Diag.Log("INFO", "Walk: not enough data from the simulation")
        self:ClearWalkerOrigin()
        return
    end

    Diag.Step("Walk: draw the line (" .. #Datastore.datapoints .. " samples)")
    -- Set points
    local tPoints = {}
    for i, datapoint in global.ipairs(Datastore.datapoints) do
        tPoints[i] = Datastore.trackEntityTransform:ToWorldPos(
            datapoint.measurements[1].transform:GetPos() +
            datapoint.measurements[1].transform:ToWorldDir(Datastore.heartlineOffset)
        )
    end
    self.line:SetPoints(tPoints)

    if self.inCamera then
        self.line:ClearPoints()
    else
        self.line:DrawPoints()
    end

    -- Turn it on
    Diag.Step("Walk: show the train gizmos")
    for _, gizmo in global.ipairs(self.followerGizmos) do
        gizmo:SetVisible(true)
    end
    Diag.Step("Walk: show the reference gizmos")
    self.referencePointGizmo:SetVisible(not self.inCamera)

    self.referencePointGizmo:SetRefPointTransform(
        Datastore.trackEntityTransform:ToWorld(Utils.TrackTransformToTransformQ(Datastore.trackWalkerOrigin.transform))
    )
    self.referencePointGizmo:SetEndPointTransform(
        Datastore.trackEntityTransform:ToWorld(Datastore.datapoints[#Datastore.datapoints].measurements[1].transform)
    )
end

function protrackManager.StartTrackCamera(self)
    if Datastore.datapoints == nil then
        return
    end

    if not self.inCamera then
        self.line:ClearPoints()
        for _, gizmo in global.ipairs(self.followerGizmos) do
            gizmo:SetVisible(false)
        end
        Cam.StartRideCamera()
        self.inCamera = true
    end

    api.ui2.SetDataStoreElement(protrackManager.context, "inCamera", self.inCamera)
end

function protrackManager.StopTrackCamera(self)
    if self.inCamera then
        self.line:DrawPoints()
        for _, gizmo in global.ipairs(self.followerGizmos) do
            gizmo:SetVisible(true)
        end
        self.referencePointGizmo:SetVisible(true)
        Cam.StopRideCamera()
        self.inCamera = false
    end

    api.ui2.SetDataStoreElement(protrackManager.context, "inCamera", self.inCamera)
end

function protrackManager.Advance(self, deltaTime)
    Diag.Guard("Advance", protrackManager.AdvanceProTrack, self, deltaTime)
    Diag.Advance()
end

function protrackManager.AdvanceProTrack(self, deltaTime)
    if self.inputEventHandler == nil or self.inputManagerAPI == nil then
        return
    end

    self.inputEventHandler:CheckEvents()

    -- Check if UI thread has demanded that we switch track modes
    if (self.newTrackModeRequest ~= self.trackMode) then
        self:SwitchTrackMode(self.newTrackModeRequest)
        self.newTrackModeRequest = self.trackMode
    end

    -- Check selection
    local newEndEdit = self.trackEditMode.tActiveData:IsAddingAfterSelection()
    if (newEndEdit ~= self.editingTrackEnd) then
        self.editingTrackEnd = newEndEdit
        if self.editingTrackEnd then
            self:StartTrackEdit()
        else
            self:EndTrackEdit()
        end
    end

    -- If we are in advanced move mode, tick it.
    if (self.trackMode == ADVMOVE_TRACKMODE) then
        local tMouseInput = (self.trackEditMode.inputManager):GetMouseInput()
        local tGamepadAxisInput = (self.trackEditMode.inputManager):GetGamepadAxisData()
        if AdvMoveMode.Advance(deltaTime, tMouseInput, tGamepadAxisInput) then
            self:SetTrackBuilderDirty()
        end
    end

    -- If we are in profile mode, tick it.
    if (self.trackMode == PROFILE_TRACKMODE) then
        if CallProfile("Advance") then
            self:SetTrackBuilderDirty()
        end
    end

    -- If a change has happened, we want to know!
    if (self.trackEditMode:HasRequestedChange()) then
        self:NewWalk()
    end

    -- Work out direction
    local direction = 0
    if (self.inputManagerAPI:GetKeyDown("DecreaseBrushIntensity")) then
        direction = direction - 1
    end
    if (self.inputManagerAPI:GetKeyDown("IncreaseBrushIntensity")) then
        direction = direction + 1
    end

    -- If keybinds are not held, respect the playingDir
    if (direction == 0) then
        direction = self.playingInDir
    end

    -- Set gizmo visiblity
    --Gizmo.Visible(not self.inCamera)

    local hasData = Datastore.HasData()
    api.ui2.SetDataStoreElement(protrackManager.context, "hasData", hasData)

    -- While a step-by-step action runs, the live display waits for it to finish.
    if hasData and not Diag.IsRunning() then
        if Datastore.trackWalkerOrigin == nil or Datastore.trackEntityTransform == nil then
            self:ClearWalkerOrigin()
            return
        end

        local timestep = api.time.GetDeltaTimeUnscaled()
        self.simulationTime = self.simulationTime + timestep * direction

        -- clamp dt to make it stay in bounds
        self.simulationTime = mathUtils.Clamp(self.simulationTime, 0, Datastore.GetTimeLength())

        -- Set datastore
        api.ui2.SetDataStoreElement(protrackManager.context, "time", self.simulationTime / Datastore.GetTimeLength())

        --- Helper func
        ---@param index integer The gizmo index
        ---@param gizmo protrack.gizmo.TrackPointGizmo The gizmo
        local function setGizmoToPoint(index, gizmo)
            local pt = Datastore.SampleDatapointAtTime(self.simulationTime, index)
            if pt == nil then
                return
            end

            local wsTrans = Datastore.trackEntityTransform:ToWorld(pt.transform)
            local wsCamOffset = wsTrans:ToWorldDir(Datastore.trackWalkerOrigin.camOffset)
            local wsHeartlineOffset = wsTrans:ToWorldDir(Datastore.heartlineOffset)

            gizmo:SetTransform(
                wsTrans:WithPos(wsTrans:GetPos() + wsHeartlineOffset)
            )
            gizmo:SetGForce(
                pt.g
            )

            if index ~= 1 then
                return
            end

            -- Pick between both heartline and standard viewing
            local wsCamOffsetUsed = wsCamOffset
            if self.cameraIsHeartlineMode then
                wsCamOffsetUsed = wsHeartlineOffset
            end

            ---@diagnostic disable-next-line: param-type-mismatch
            api.transform.SetPosition(Cam.PreviewCameraEntity, wsTrans:GetPos() + wsCamOffsetUsed)
            api.transform.SetOrientation(Cam.PreviewCameraEntity, wsTrans:GetOr())

            local indexDatapoint = Datastore.GetFloorIndexForTime(self.simulationTime)
            local numDatapoints = Datastore.GetNumDatapoints()

            api.ui2.SetDataStoreElement(protrackManager.context, "currKeyframe", indexDatapoint)
            api.ui2.SetDataStoreElement(protrackManager.context, "keyframeCount", numDatapoints)
            api.ui2.SetDataStoreElement(protrackManager.context, "vertGForce", pt.g:GetY())
            api.ui2.SetDataStoreElement(protrackManager.context, "latGForce", pt.g:GetX())
            api.ui2.SetDataStoreElement(protrackManager.context, "speed",
                UnitConversion.Speed_ToUserPref(pt.speed, UnitConversion.Speed_MS))
        end

        for i, gizmo in global.ipairs(self.followerGizmos) do
            setGizmoToPoint(i, gizmo)
        end
    end
end

--/ Validate class methods and interfaces, the game needs
--/ to validate the Manager conform to the module requirements.
Mutators.VerifyManagerModule(protrackManager)
