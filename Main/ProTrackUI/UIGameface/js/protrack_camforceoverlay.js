import * as DataStore from "/js/common/core/DataStore.js";
import * as Engine from "/js/common/core/Engine.js";
import * as Input from "/js/common/core/Input.js";
import * as Localisation from "/js/common/core/Localisation.js";
import * as Player from "/js/common/core/Player.js";
import * as System from "/js/common/core/System.js";
import * as preact from "/js/common/lib/preact.js";
import * as Format from "/js/common/util/LocalisationUtil.js";

import { loadDebugDefaultTools } from "/js/common/debug/DebugToolImports.js";
import { loadCSS } from "/js/common/util/CSSUtil.js";

import { Slider } from '/js/project/components/Slider.js';
import { Button } from '/js/project/components/Button.js';
import { ListStepperRow } from '/js/project/components/ListStepperRow.js';
import { CheckBox } from '/js/project/components/CheckBox.js';

import { Panel, PanelType } from '/js/project/components/panel/Panel.js';
import { Tab } from '/js/common/components/Tab.js';
import { MetricDisplay, DirectionalGForceMetric, KeyframeMetric } from '/js/protrack_metriccomponents.js';
import { Messagetype, WarningMessage } from '/js/project/components/WarningMessage.js';

import { DataStoreHelper } from '/js/common/util/DataStoreHelper.js';
import * as AccentColorUtil from '/js/project/utils/AccentColorUtil.js';
import * as FontConfig from "/js/config/FontConfig.js";
import * as UIScaleUtil from "/js/project/utils/UIScaleUtil.js";
FontConfig;
AccentColorUtil;
UIScaleUtil;

Engine.initialiseSystems([
    {
        system: Engine.Systems.System,
        initialiser: System.attachToEngineReadyForSystem,
    },
    {
        system: Engine.Systems.DataStore,
        initialiser: DataStore.attachToEngineReadyForSystem,
    },
    {
        system: Engine.Systems.Input,
        initialiser: Input.attachToEngineReadyForSystem,
    },
    {
        system: Engine.Systems.Localisation,
        initialiser: Localisation.attachToEngineReadyForSystem,
    },
    {
        system: Engine.Systems.Player,
        initialiser: Player.attachToEngineReadyForSystem,
    },
]);


let datapoint = {
    currentKeyframe: 959,
    keyframeCount: 1000,
    g: {}
}

// Profile mode values mirrored from the ProTrack datastore
const PROFILE_DATASTORE_KEYS = [
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
    "profileHasPlan",
    "profileLocked",
    "profileStalled",
    "profileEndIndex",
    "profileOffSection",
    "profileChunkCount",
    "profileStartVertG",
    "profileStartLatG",
    "profileStartBank",
    "profileMidBankResult",
    "profileEndBankResult",
    "profileLevelLimited",
    "profileError",
];

// Diagnostics values mirrored from the ProTrack datastore
const DIAG_DATASTORE_KEYS = [
    "diagLog",
    "diagLastError",
    "diagStepMode",
    "diagFileLog",
];

const PROFILE_CURVE_ITEMS = [
    "[Loc_ProTrack_Curve_Linear]",
    "[Loc_ProTrack_Curve_Smooth]",
    "[Loc_ProTrack_Curve_Smoother]",
    "[Loc_ProTrack_Curve_EaseIn]",
    "[Loc_ProTrack_Curve_EaseOut]",
];

// Panel positions, in the order the Move button goes through them (clockwise)
const DOCK_POSITIONS = ["topCentre", "bottomRight", "bottomLeft", "topLeft"];
const LAYOUT_STORAGE_KEY = "ProTrackUI_layout";

// Panel position and visibility, kept between sessions when the UI has local storage
function loadLayout() {
    try {
        const saved = JSON.parse(window.localStorage.getItem(LAYOUT_STORAGE_KEY));
        if (saved && Number.isInteger(saved.dockIndex) && saved.dockIndex >= 0 && saved.dockIndex < DOCK_POSITIONS.length) {
            return { dockIndex: saved.dockIndex, panelHidden: saved.panelHidden === true };
        }
    } catch (e) { }
    return { dockIndex: 0, panelHidden: false };
}

function saveLayout(dockIndex, panelHidden) {
    try {
        window.localStorage.setItem(LAYOUT_STORAGE_KEY, JSON.stringify({ dockIndex: dockIndex, panelHidden: panelHidden }));
    } catch (e) { }
}

const INITIAL_LAYOUT = loadLayout();

// Wraps a control placed side by side in a row: every cell gets the same width,
// whatever width the control itself asks for.
function cell(child) {
    return child && preact.h("div", { className: "ProTrackUI_cell" }, child);
}

// Profile mode pages, picked next to the track mode
const PROFILE_PAGE_ITEMS = [
    "[Loc_ProTrack_ProfilePage_Section]",
    "[Loc_ProTrack_ProfilePage_Mid]",
    "[Loc_ProTrack_ProfilePage_End]",
];

Engine.whenReady.then(async () => {
    await loadCSS('project/Shared');
    await loadDebugDefaultTools();
    preact.render(preact.h(CamForceOverlay, null), document.body);

    Engine.sendEvent("OnReady");
}).catch(Engine.defaultCatch);

class CamForceOverlay extends preact.Component {
    static defaultProps = {
        moduleName: "ProTrackUI"
    };
    state = {
        // Ui data
        visible: false,
        visibleTabIndex: 0,
        dockIndex: INITIAL_LAYOUT.dockIndex,
        panelHidden: INITIAL_LAYOUT.panelHidden,

        // Editor data
        hasData: false,
        inCamera: false,
        cameraIsHeartlineMode: false,
        trackMode: 0,
        heartline: 0.0,
        forceLockVertG: 0.0,
        forcelockLatG: 0.0,

        // Playhead data
        time: 0.0,
        playingInDir: 0,
        time: 0.0,

        // Profile data
        profileLength: 20.0,
        profileMidPercent: 40.0,
        profileMidVertG: 1.0,
        profileEndVertG: 1.0,
        profileMidLatG: 0.0,
        profileEndLatG: 0.0,
        profileMidBank: 0.0,
        profileEndBank: 0.0,
        profileCurveIn: 1,
        profileCurveOut: 1,
        profileBankRelative: false,
        profileLevelTurns: false,
        profileHasPlan: false,
        profileLocked: false,
        profileStalled: false,
        profileEndIndex: 1,
        profileOffSection: false,
        profilePage: 1,
        profileChunkCount: 5,
        profileStartVertG: 0.0,
        profileStartLatG: 0.0,
        profileStartBank: 0.0,
        profileMidBankResult: 0.0,
        profileEndBankResult: 0.0,
        profileLevelLimited: false,
        profileError: "",

        // Diagnostics data
        diagLog: "",
        diagLastError: "",
        diagStepMode: false,
        diagFileLog: "off"
    };
    _helper = undefined;
    componentWillMount() {
        Engine.addListener("Show", this.onShow);
        Engine.addListener("Hide", this.onHide);

        // Bind to datastore
        this._helper = new DataStoreHelper();

        this._helper.addPropertyListener(["ProTrack"], "inCamera", (value) => {
            this.setState({ inCamera: value });
        });

        this._helper.addPropertyListener(["ProTrack"], "cameraIsHeartlineMode", (value) => {
            this.setState({ cameraIsHeartlineMode: value });
        });

        this._helper.addPropertyListener(["ProTrack"], "playingInDir", (value) => {
            this.setState({ playingInDir: value });
        });

        this._helper.addPropertyListener(["ProTrack"], "time", (value) => {
            this.setState({ time: value });
        });

        this._helper.addPropertyListener(["ProTrack"], "hasData", (value) => {
            this.setState({ hasData: value });
        });

        this._helper.addPropertyListener(["ProTrack"], "trackMode", (value) => {
            this.setState({ trackMode: value });
        });

        this._helper.addPropertyListener(["ProTrack"], "forceLockVertG", (value) => {
            this.setState({ forceLockVertG: value });
        });

        this._helper.addPropertyListener(["ProTrack"], "forceLockLatG", (value) => {
            this.setState({ forceLockLatG: value });
        });

        for (const key of DIAG_DATASTORE_KEYS) {
            this._helper.addPropertyListener(["ProTrack"], key, (value) => {
                this.setState({ [key]: value });
            });
        }

        for (const key of PROFILE_DATASTORE_KEYS) {
            this._helper.addPropertyListener(["ProTrack"], key, (value) => {
                this.setState({ [key]: value });
            });
        }

        this._helper.getAllPropertiesNow();
    }
    componentWillUnmount() {
        Engine.removeListener("Show", this.onShow);
        Engine.removeListener("Hide", this.onHide);
        this._helper.clear();
        this._helper = undefined;
    }

    render(props, state) {
        if (!this.state.visible) {
            return preact.h("div", { className: "ProTrackUI_root" });
        }

        const items = [
            "[Loc_ProTrack_TM_Normal]",
            "[Loc_ProTrack_TM_ForceLock]",
            "[Loc_ProTrack_TM_Gizmo]",
            "[Loc_ProTrack_TM_Profile]",
        ];

        var tabs = [
            // Tab one, force viz
            preact.h("div", { key: "tab1", className: "ProTrackUI_panelInner" },

                // Row 1
                preact.h("div", { className: "ProTrackUI_distributeRow" },
                    preact.h("div", { className: "ProTrackUI_flexRow" },
                        preact.h(Slider, {
                            // label: '[Loc_ProTrack_Scrub]',
                            min: 0,
                            max: 1,
                            step: 0.0001,
                            formatter: Format.float_3DP,
                            value: state.time,
                            onChange: this.onTimeChanged,
                            focusable: true,
                            disabled: !state.hasData
                        })
                    ),
                ),

                // Row 2 (control buttons)
                preact.h("div", { className: "ProTrackUI_distributeRow" },

                    // lefthand side
                    preact.h("div", { className: "ProTrackUI_minRow ProTrackUI_innerGap" },
                        preact.h(Button, {
                            icon: 'img/icons/locate.svg',
                            label: Format.stringLiteral('Anchor'),
                            onSelect: this.onReanchor,
                        }),
                        preact.h(Button, {
                            icon: 'img/icons/redo.svg',
                            label: Format.stringLiteral('Resimulate'),
                            onSelect: this.onResimulate,
                            disabled: !state.hasData
                        }),
                        preact.h(Button, {
                            icon: 'img/icons/camera.svg',
                            label: Format.stringLiteral(state.inCamera ? 'Exit Track Cam' : "Enter Track Cam"),
                            onSelect: this.onChangeCam,
                            disabled: !state.hasData
                        }),
                    ),

                    // Middle spacer
                    preact.h("div", { className: "ProTrackUI_flexRow" }),

                    preact.h("div", { className: "ProTrackUI_minRow ProTrackUI_innerGap" },
                        state.playingInDir != -1 && preact.h(Button, {
                            icon: 'img/icons/arrow_left.svg',
                            onSelect: this.onScrubBackwards,
                            disabled: !state.hasData
                        }),

                        state.playingInDir != 0 && preact.h(Button, {
                            icon: 'img/icons/pause.svg',
                            onSelect: this.onScrubPause,
                            modifiers: 'negative',
                            disabled: !state.hasData
                        }),

                        state.playingInDir != 1 && preact.h(Button, {
                            icon: 'img/icons/arrow_right.svg',
                            onSelect: this.onScrubForwards,
                            disabled: !state.hasData
                        }),
                    ),
                ),

                // Row 3
                state.hasData && preact.h("div", { className: "ProTrackUI_flexRow ProTrackUI_innerGap" },
                    preact.h(KeyframeMetric, {
                        icon: "img/icons/clock.svg",
                        formatter: (v) => v
                    }),
                    preact.h(DirectionalGForceMetric, {
                        dataKey: "vertGForce",
                        iconPrefix: "img/icons/protrack_vertg_",
                        threshold: 0.1,
                        directions: { positive: "d", negative: "u" },
                        formatter: Format.gForce_2DP
                    }),
                    preact.h(DirectionalGForceMetric, {
                        dataKey: "latGForce",
                        iconPrefix: "img/icons/protrack_latg_",
                        threshold: 0.25,
                        directions: { positive: "l", negative: "r" },
                        formatter: Format.gForce_2DP
                    }),
                    preact.h(MetricDisplay, {
                        dataKey: "speed",
                        icon: "img/icons/maxSpeed.svg",
                        formatter: Format.speedUnit_1DP
                    })
                )
            ),

            // Tab 2, track tools
            preact.h("div", { key: "tab2", className: "ProTrackUI_panelInner" },
                preact.h("div", { className: "ProTrackUI_flexRow" },
                    cell(preact.h(ListStepperRow, { showInputIcon: true, modal: true, items: items, listIndex: state.trackMode, onChange: this.onTrackModeChange, label: "[Loc_ProTrack_TM_Label]" })),
                    state.trackMode == 3 && cell(preact.h(ListStepperRow, { showInputIcon: true, modal: true, items: PROFILE_PAGE_ITEMS, listIndex: state.profilePage, onChange: this.onProfilePageChange, label: "[Loc_ProTrack_ProfilePage]" })),
                ),
                // Profile mode error, if it stopped
                state.profileError && preact.h("div", { className: "ProTrackUI_flexRow" },
                    preact.h(WarningMessage, { label: Format.stringLiteral('Profile mode stopped: ' + state.profileError), type: Messagetype.Neutral, show: true })
                ),
                // Warning message
                state.trackMode == 1 && !state.hasData && preact.h("div", { className: "ProTrackUI_flexRow" },
                    preact.h(WarningMessage, { label: Format.stringLiteral('TrackViz data needed at track end for ForceLock.'), type: Messagetype.Neutral, show: true })
                ),
                state.trackMode == 1 && state.hasData && preact.h("div", { className: "ProTrackUI_flexRow" },
                    cell(preact.h(Slider, {
                        label: '[Loc_ProTrack_VertG]',
                        // rootClassName: "ProTrackUI_flex",
                        // modifiers: 'inner',
                        min: -6.0,
                        max: 6.0,
                        step: 0.05,
                        formatter: Format.gForce_2DP,
                        value: state.forceLockVertG,
                        onChange: this.onVertGChanged,
                        focusable: true,
                        disabled: !state.hasData,
                    })),
                    cell(preact.h(Slider, {
                        label: '[Loc_ProTrack_LatG]',
                        // rootClassName: "ProTrackUI_flex",
                        // modifiers: 'inner',
                        min: -2.0,
                        max: 2.0,
                        step: 0.05,
                        formatter: Format.gForce_2DP,
                        value: state.forceLockLatG,
                        onChange: this.onLatGChanged,
                        focusable: true,
                        disabled: !state.hasData,
                    })),
                ),
                state.trackMode == 3 && this.renderProfileTools(state),
            ),

            // Tab 3, settings
            preact.h("div", { key: "tab3", className: "ProTrackUI_panelInner" },
                preact.h("div", { className: "ProTrackUI_flexRow" },
                    preact.h(Slider, {
                        label: '[Loc_ProTrack_Heartline]',
                        // rootClassName: "ProTrackUI_flex",
                        // modifiers: 'inner',
                        min: -2.0,
                        max: 2.0,
                        step: 0.05,
                        formatter: Format.distanceUnit_2DP,
                        value: state.heartline,
                        onChange: this.onHeartlineChanged,
                        focusable: true
                    }),
                ),

                preact.h("div", { className: "ProTrackUI_flexRow" },
                    preact.h(CheckBox, {
                        label: Format.stringLiteral('Use Heartline Camera'),
                        toggled: state.cameraIsHeartlineMode,
                        onToggle: this.onHeartlineCameraChanged,
                        modifiers: "stretch",
                    })
                ),
            ),

            // Tab 4, diagnostics
            preact.h("div", { key: "tab4", className: "ProTrackUI_panelInner" },
                state.diagLastError && preact.h("div", { className: "ProTrackUI_flexRow" },
                    preact.h(WarningMessage, { label: Format.stringLiteral('Last error: ' + state.diagLastError), type: Messagetype.Neutral, show: true })
                ),
                preact.h("div", { className: "ProTrackUI_flexRow" },
                    preact.h(CheckBox, {
                        label: Format.stringLiteral('Step-by-step mode (Anchor/Resimulate wait before each step)'),
                        toggled: state.diagStepMode,
                        onToggle: this.onDiagStepModeChanged,
                        modifiers: "stretch",
                    })
                ),
                preact.h("div", { className: "ProTrackUI_distributeRow" },
                    preact.h("div", { className: "ProTrackUI_minRow ProTrackUI_innerGap" },
                        preact.h(Button, {
                            label: Format.stringLiteral('Try file log'),
                            onSelect: this.onDiagFileLog,
                        }),
                        preact.h(Button, {
                            label: Format.stringLiteral('Clear log'),
                            onSelect: this.onDiagClear,
                        }),
                    ),
                    preact.h("div", { className: "ProTrackUI_logStatus" }, 'File log: ' + state.diagFileLog),
                ),
                preact.h("div", { className: "ProTrackUI_log" },
                    (state.diagLog || "").split("\n").map((line, i) =>
                        preact.h("div", { key: i, className: "ProTrackUI_logLine" }, line)
                    )
                ),
            )
        ]

        const dock = DOCK_POSITIONS[state.dockIndex] || DOCK_POSITIONS[0];

        return preact.h("div", { className: "ProTrackUI_root" },
            preact.h("div", { className: "ProTrackUI_dock ProTrackUI_dock_" + dock },
                preact.h("div", { className: "ProTrackUI_toolbar ProTrackUI_innerGap" },
                    preact.h(Button, {
                        label: Format.stringLiteral('Move'),
                        onSelect: this.onMovePanel,
                    }),
                    preact.h(Button, {
                        label: Format.stringLiteral(state.panelHidden ? 'Show ProTrack' : 'Hide'),
                        onSelect: this.onTogglePanel,
                    }),
                ),
                !state.panelHidden && preact.h(Panel,
                {
                    rootClassName: "ProTrackUI_panel",
                    type: PanelType.default,
                    title: Format.stringLiteral('ProTrack'),
                    visibleTabIndex: state.visibleTabIndex,
                    onTabChange: this.onChangeTab,
                    modifiers: props.modifiers,
                    context: props.context,
                    onClose: props.onClose,
                    tabs: [
                        preact.h(Tab, { icon: '/img/icons/gforce.svg', label: Format.stringLiteral("TrackViz") }),
                        preact.h(Tab, { icon: '/img/icons/create.svg', label: Format.stringLiteral("Track Tools") }),
                        // preact.h(Tab, { icon: '/img/icons/placeholder.svg' }),
                        preact.h(Tab, { icon: '/img/icons/settings.svg', label: Format.stringLiteral("Settings") }),
                        preact.h(Tab, { icon: '/img/icons/clock.svg', label: Format.stringLiteral("Diagnostics") })
                    ],
                    children: tabs
                },
                )
            )
        );
    }

    // Profile mode controls, shown in the track tools tab

    renderProfileTools(state) {
        const locked = state.profileLocked;
        const relative = state.profileBankRelative;
        const bankRange = relative ? 360.0 : 180.0;

        // Relative: roll added, and the bank it leads to
        const bankFormatter = (resultKey) => (v) => {
            if (!relative) {
                return Format.stringLiteral(`${Math.round(v)}°`);
            }
            const roll = `${v > 0 ? '+' : ''}${Math.round(v)}°`;
            return Format.stringLiteral(state.profileHasPlan ? `${roll} (to ${Math.round(state[resultKey])}°)` : roll);
        };
        const midFormatter = (v) => Format.stringLiteral(
            `${Math.round(v)}% · ${(state.profileLength * v / 100).toFixed(1)} m`
        );

        const slider = (key, label, min, max, step, formatter) => preact.h(Slider, {
            label: label,
            min: min,
            max: max,
            step: step,
            formatter: formatter,
            value: state[key],
            onChange: this.onProfileSettingChanged(key),
            focusable: true,
            disabled: locked,
        });

        const curveStepper = (key, label) => preact.h(ListStepperRow, {
            showInputIcon: true,
            modal: true,
            items: PROFILE_CURVE_ITEMS,
            listIndex: state[key],
            onChange: this.onProfileSettingChanged(key),
            label: label,
            disabled: locked,
        });

        const checkBox = (key, label) => preact.h(CheckBox, {
            label: Format.stringLiteral(label),
            toggled: state[key],
            onToggle: this.onProfileSettingChanged(key),
            modifiers: "stretch",
            disabled: locked,
        });

        let status = '';
        let warning = false;
        if (locked && state.profileOffSection) {
            status = 'Track end is off the section, cancel to start a new one';
            warning = true;
        } else if (locked) {
            status = `Building · piece ${state.profileEndIndex} / ${state.profileChunkCount}`;
        } else if (state.profileStalled) {
            status = 'The train stalls before the section end';
            warning = true;
        } else if (!state.hasData) {
            status = 'Anchor needed: TrackViz data must reach the track end';
            warning = true;
        } else if (state.profileHasPlan) {
            status = `Ready · ${state.profileChunkCount} pieces`;
        }

        const showInfo = status || state.profileHasPlan;

        const row = (key, ...children) => preact.h("div", { key: key, className: "ProTrackUI_flexRow" }, ...children.map(cell));
        const pages = [
            // Section
            [
                row("profileSectionLength",
                    slider("profileLength", '[Loc_ProTrack_ProfileLength]', 4.0, 100.0, 4.0, Format.distanceUnit_2DP),
                    slider("profileMidPercent", '[Loc_ProTrack_ProfileMidDistance]', 0.0, 100.0, 1.0, midFormatter),
                ),
                row("profileSectionToggles",
                    checkBox("profileBankRelative", 'Relative bank (roll)'),
                    checkBox("profileLevelTurns", 'Level turns'),
                ),
            ],
            // Mid point
            [
                row("profileMidG",
                    slider("profileMidVertG", '[Loc_ProTrack_ProfileMidVertG]', -6.0, 6.0, 0.05, Format.gForce_2DP),
                    slider("profileMidLatG", '[Loc_ProTrack_ProfileMidLatG]', -2.0, 2.0, 0.05, Format.gForce_2DP),
                ),
                row("profileMidShape",
                    slider("profileMidBank", '[Loc_ProTrack_ProfileMidBank]', -bankRange, bankRange, 1.0, bankFormatter("profileMidBankResult")),
                    curveStepper("profileCurveIn", "[Loc_ProTrack_ProfileCurveIn]"),
                ),
            ],
            // End point
            [
                row("profileEndG",
                    slider("profileEndVertG", '[Loc_ProTrack_ProfileEndVertG]', -6.0, 6.0, 0.05, Format.gForce_2DP),
                    slider("profileEndLatG", '[Loc_ProTrack_ProfileEndLatG]', -2.0, 2.0, 0.05, Format.gForce_2DP),
                ),
                row("profileEndShape",
                    slider("profileEndBank", '[Loc_ProTrack_ProfileEndBank]', -bankRange, bankRange, 1.0, bankFormatter("profileEndBankResult")),
                    curveStepper("profileCurveOut", "[Loc_ProTrack_ProfileCurveOut]"),
                ),
            ],
        ];

        return [
            // One line: status, start values, cancel
            showInfo && preact.h("div", { key: "profileInfo", className: "ProTrackUI_infoRow" },
                preact.h("div", { className: "ProTrackUI_infoBar" },
                    preact.h("div", { className: warning ? "ProTrackUI_infoText ProTrackUI_infoWarn" : "ProTrackUI_infoText" }, status),
                    state.profileHasPlan && state.profileLevelLimited && preact.h("div", { className: "ProTrackUI_infoText ProTrackUI_infoWarn" },
                        'Level turns limited past 75°'
                    ),
                    preact.h("div", { className: "ProTrackUI_infoSpacer" }),
                    state.profileHasPlan && preact.h("div", { className: "ProTrackUI_infoText" },
                        `Start ${state.profileStartVertG.toFixed(2)} G vert · ` +
                        `${state.profileStartLatG.toFixed(2)} G lat · ` +
                        `${Math.round(state.profileStartBank)}° bank`
                    ),
                    locked && preact.h(Button, {
                        label: Format.stringLiteral('Cancel section'),
                        onSelect: this.onProfileCancel,
                    }),
                ),
            ),
            // Rows of the page picked next to the track mode
            ...(pages[state.profilePage] || pages[1]),
        ];
    }

    onProfileSettingChanged = (key) => (value) => {
        this.setState({ [key]: value });
        Engine.sendEvent("ProtrackProfileSettingChanged_" + key, value);
    }

    onProfilePageChange = (page) => {
        this.setState({ profilePage: page });
    }

    onProfileCancel = () => {
        Engine.sendEvent("Protrack_ProfileCancelRequested");
    }

    // Panel position

    onMovePanel = () => {
        const dockIndex = (this.state.dockIndex + 1) % DOCK_POSITIONS.length;
        this.setState({ dockIndex: dockIndex });
        saveLayout(dockIndex, this.state.panelHidden);
    }

    onTogglePanel = () => {
        const panelHidden = !this.state.panelHidden;
        this.setState({ panelHidden: panelHidden });
        saveLayout(this.state.dockIndex, panelHidden);
    }

    // Button responders

    onReanchor = () => {
        Engine.sendEvent("Protrack_ReanchorRequested");
    }

    onResimulate = () => {
        Engine.sendEvent("Protrack_ResimulateRequested");
    }

    onChangeCam = () => {
        Engine.sendEvent("Protrack_ChangeCamModeRequested");
    }

    onScrubBackwards = () => {
        Engine.sendEvent("Protrack_PlayChanged", -1);
    }

    onScrubForwards = () => {
        Engine.sendEvent("Protrack_PlayChanged", 1);
    }

    onScrubPause = () => {
        Engine.sendEvent("Protrack_PlayChanged", 0);
    }

    // Value listeners

    onChangeTab = (visibleIndex) => {
        this.setState({ visibleTabIndex: visibleIndex });
    }

    onTrackModeChange = (newTrackMode) => {
        this.setState({ trackMode: newTrackMode });
        Engine.sendEvent("ProtrackTrackModeChanged", newTrackMode);
    }

    onDiagStepModeChanged = (stepMode) => {
        this.setState({ diagStepMode: stepMode });
        Engine.sendEvent("Protrack_DiagStepModeChanged", stepMode);
    }

    onDiagFileLog = () => {
        Engine.sendEvent("Protrack_DiagFileLogRequested");
    }

    onDiagClear = () => {
        Engine.sendEvent("Protrack_DiagClearRequested");
    }

    onHeartlineCameraChanged = (heartlineCamRequested) => {
        this.setState({ cameraIsHeartlineMode: heartlineCamRequested });
        Engine.sendEvent("ProtrackHeartlineCamChanged", heartlineCamRequested);
    }

    onTimeChanged = (value) => {

        // Pause if playing (bad for UX)
        if (this.state.playingInDir != 0) {
            this.onScrubPause();
        }

        this.setState({ time: value });
        Engine.sendEvent("Protrack_TimeChanged", value);
    };

    onLatGChanged = (value) => {
        this.setState({ forceLockLatG: value });
        Engine.sendEvent("ProtrackLatGChanged", value);
    };

    onVertGChanged = (value) => {
        this.setState({ forceLockVertG: value });
        Engine.sendEvent("ProtrackVertGChanged", value);
    };

    onHeartlineChanged = (value) => {
        this.setState({ heartline: value });
        Engine.sendEvent("ProtrackHeartlineChanged", value);
    };

    // Engine visibility listeners

    onShow = () => {
        this.setState({ visible: true });
    }
    onHide = () => {
        this.setState({ visible: false });
    }
}