----
--- ~~copied~~ Based off Parker's PC:CC UI implimentation and TooMuchScaling ~ Coppertine
----
local global            = _G
---@type Api
---@diagnostic disable-next-line: undefined-field
local api               = global.api
local require           = global.require

---@diagnostic disable-next-line: deprecated
local module            = global.module
local Object            = require("Common.object")
local GamefaceUIWrapper = require("UI.GamefaceUIWrapper")
local table             = require("Common.tableplus")

local logger            = require("forgeutils.logger").Get("ProTrackForceOverlay")
local Diag              = require("protrack.diagnostics")

---Listens to a UI event. The callback is guarded: a Lua error in it is logged
---in the Diagnostics tab instead of crashing the game.
local function Listen(overlay, eventName, _callback, _self)
	---@diagnostic disable-next-line: undefined-field
	overlay:AddEventListener(eventName, 1, function(...)
		Diag.Guard("UI " .. eventName, _callback, ...)
	end, _self)
end

---@class ForceOverlay
local ForceOverlay      = module(..., Object.subclass(GamefaceUIWrapper))
local ObjectNew         = ForceOverlay.new

function ForceOverlay:new(_fnOnReadyCallback)
	logger:Info("New ForceOverlay")
	local oNewForceOverlay = ObjectNew(ForceOverlay)
	local tInitSettings = {
		sViewName = "ProTrackUI",
		sViewAddress = "coui://UIGameface/ProTrack_CamForceOverlay.html",
		bStartEnabled = true,
		fnOnReadyCallback = _fnOnReadyCallback,
		nViewDepth = 0,
		nViewHeight = 1920,
		nViewWidth = 1080,
		bRegisterWrapper = true
	}
	logger:Info("Attempting to Init Overlay UI")
	oNewForceOverlay:Init(tInitSettings)
	return oNewForceOverlay
end

-- Button responders

function ForceOverlay:AddListener_ReanchorRequested(_callback, _self)
	Listen(self, "Protrack_ReanchorRequested", _callback, _self)
end

function ForceOverlay:AddListener_ResimulateRequested(_callback, _self)
	Listen(self, "Protrack_ResimulateRequested", _callback, _self)
end

function ForceOverlay:AddListener_ChangeCamModeRequested(_callback, _self)
	Listen(self, "Protrack_ChangeCamModeRequested", _callback, _self)
end

-- Value change listeners

function ForceOverlay:AddListener_HeartlineValueChanged(_callback, _self)
	Listen(self, "ProtrackHeartlineChanged", _callback, _self)
end

function ForceOverlay:AddListener_VertGValueChanged(_callback, _self)
	Listen(self, "ProtrackVertGChanged", _callback, _self)
end

function ForceOverlay:AddListener_LatGValueChanged(_callback, _self)
	Listen(self, "ProtrackLatGChanged", _callback, _self)
end

function ForceOverlay:AddListener_TrackModeChanged(_callback, _self)
	Listen(self, "ProtrackTrackModeChanged", _callback, _self)
end

function ForceOverlay:AddListener_HeartlineCamChanged(_callback, _self)
	Listen(self, "ProtrackHeartlineCamChanged", _callback, _self)
end

function ForceOverlay:AddListener_TimeChanged(_callback, _self)
	Listen(self, "Protrack_TimeChanged", _callback, _self)
end

function ForceOverlay:AddListener_PlayChanged(_callback, _self)
	Listen(self, "Protrack_PlayChanged", _callback, _self)
end

-- Profile mode

function ForceOverlay:AddListener_ProfileSettingChanged(_settingName, _callback, _self)
	Listen(self, "ProtrackProfileSettingChanged_" .. _settingName, _callback, _self)
end

function ForceOverlay:AddListener_ProfileCancelRequested(_callback, _self)
	Listen(self, "Protrack_ProfileCancelRequested", _callback, _self)
end

-- Diagnostics

function ForceOverlay:AddListener_DiagStepModeChanged(_callback, _self)
	Listen(self, "Protrack_DiagStepModeChanged", _callback, _self)
end

function ForceOverlay:AddListener_DiagFileLogRequested(_callback, _self)
	Listen(self, "Protrack_DiagFileLogRequested", _callback, _self)
end

function ForceOverlay:AddListener_DiagClearRequested(_callback, _self)
	Listen(self, "Protrack_DiagClearRequested", _callback, _self)
end

function ForceOverlay:Show()
	logger:Info("Showing Overlay")
	---@diagnostic disable-next-line: undefined-field
	self:TriggerEventAtNextAdvance("Show")
end

function ForceOverlay:Hide()
	logger:Info("Hiding Overlay")
	---@diagnostic disable-next-line: undefined-field
	self:TriggerEventAtNextAdvance("Hide")
end
