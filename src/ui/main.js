Ext.namespace("SYNO.SDS.Syno_Toolbox");

// -----------------------------------------------------------------
// App entry point
// -----------------------------------------------------------------
Ext.define("SYNO.SDS._ThirdParty.App.Syno_Toolbox", {
    extend: "SYNO.SDS.AppInstance",
    appWindowName: "SYNO.SDS.Syno_Toolbox.MainWindow",
    constructor: function() {
        this.callParent(arguments);
    }
});

// -----------------------------------------------------------------
// Shared API helper (ported unchanged from CPUTemp's pattern)
// -----------------------------------------------------------------
SYNO.SDS.Syno_Toolbox.API_PATH = "/webman/3rdparty/Syno_Toolbox/api.cgi";

SYNO.SDS.Syno_Toolbox.apiCall = function(action, params, method, callback) {
    // 4-arg form: apiCall(action, params, method, cb)
    // 3-arg form (GET, matches CPUTemp): apiCall(action, params, cb)
    if (typeof method === "function") {
        callback = method;
        method = "GET";
    }
    Ext.Ajax.request({
        url: SYNO.SDS.Syno_Toolbox.API_PATH,
        method: method || "GET",
        params: Ext.apply({ action: action, _ts: new Date().getTime() }, params || {}),
        success: function(response) {
            var resp;
            try {
                resp = Ext.decode(response.responseText);
            } catch (e) {
                resp = { success: false, message: "Bad response from api.cgi" };
            }
            callback(resp);
        },
        failure: function() {
            callback({ success: false, message: "Request to api.cgi failed" });
        }
    });
};

// -----------------------------------------------------------------
// Main window
// -----------------------------------------------------------------
Ext.define("SYNO.SDS.Syno_Toolbox.MainWindow", {
    extend: "SYNO.SDS.AppWindow",

    constructor: function(a) {
        this.appInstance = a.appInstance;
        this.modules = [];       // raw manifest+state entries from getstate
        this.dirty = false;
        SYNO.SDS.Syno_Toolbox.MainWindow.superclass.constructor.call(this, Ext.apply({
            layout: "fit",
            resizable: true,
            cls: "syno-app-win toolbox-win",
            maximizable: true,
            minimizable: true,
            showHelp: false,
            width: 720,
            height: 560,
            html: this.buildHtml(),
            listeners: {
                afterrender: { fn: this.onAfterRender, scope: this }
            }
        }, a));
    },

    buildHtml: function() {
        return [
            '<style>',
            '  .tb-body { display:flex; flex-direction:column; height:100%; padding:8px; box-sizing:border-box; }',
            '  .tb-toolbar { flex:0 0 auto; padding-bottom:8px; display:flex; align-items:center; gap:8px; }',
            '  .tb-toolbar button { padding:6px 20px; cursor:pointer; border-radius:4px; font-size:13px; font-weight:bold; border:1px solid #1B8AED; background-color:#1B8AED; color:#fff; }',
            '  .tb-toolbar button:hover { background-color:#057FEB; }',
            '  .tb-toolbar button:disabled { opacity:0.5; cursor:default; }',
            '  .tb-status { font-size:13px; color:#888; }',
            '  .tb-spinner { display:none; vertical-align:middle; margin-right:0px; }',
            '  .tb-spinner.show { display:inline-block; }',
            '  .tb-tabs { flex:0 0 auto; display:flex; gap:2px; border-bottom:1px solid #e0e0e0; margin-bottom:0; }',
            '  .tb-tab { padding:8px 18px; cursor:pointer; border:none; background:none; font-size:13px; font-weight:bold; color:#888; border-bottom:2px solid transparent; }',
            '  .tb-tab:hover { color:#1B8AED; }',
            '  .tb-tab.tb-tab-active { color:#1B8AED; border-bottom-color:#1B8AED; }',
            '  .tb-list { flex:1 1 auto; overflow:auto; border:1px solid #e0e0e0; border-top:none; border-radius:0 0 4px 4px; }',
            '  .tb-panel { display:none; }',
            '  .tb-panel.tb-panel-active { display:block; }',
            '  .tb-row { display:flex; align-items:flex-start; gap:12px; padding:10px 12px; border-bottom:1px solid #eee; }',
            '  .tb-row:last-child { border-bottom:none; }',
            '  .tb-row-main { flex:1 1 auto; }',
            '  .tb-row-name { font-weight:bold; font-size:13px; }',
            '  .tb-row-controls { margin-top:6px; display:flex; flex-wrap:wrap; align-items:center; gap:8px; font-size:12px; color:#555; }',
            '  .tb-row-controls input[type=text], .tb-row-controls input[type=number], .tb-row-controls select { padding:3px 5px; font-size:12px; border:1px solid #ccc; border-radius:3px; }',
            '  .tb-row-result { margin-top:6px; font-family:Verdana,Arial,sans-serif; font-size:11px; color:#777; white-space:pre-wrap; -webkit-user-select:text; -moz-user-select:text; -ms-user-select:text; user-select:text; }',
            '  .tb-row-result-monospace { margin-top:6px; font-family:Consolas,Monaco,"Courier New",monospace; font-size:11px; color:#777; white-space:pre-wrap; -webkit-user-select:text; -moz-user-select:text; -ms-user-select:text; user-select:text; }',
            '  .tb-toggle { width:38px; height:20px; position:relative; display:inline-block; flex:0 0 auto; }',
            '  .tb-toggle.tb-toggle-hidden { visibility:hidden; }',
            '  .tb-toggle input { opacity:0; width:0; height:0; }',
            '  .tb-toggle .tb-slider { position:absolute; inset:0; background:#ccc; border-radius:20px; cursor:pointer; transition:.15s; }',
            '  .tb-toggle .tb-slider:before { content:""; position:absolute; height:16px; width:16px; left:2px; top:2px; background:#fff; border-radius:50%; transition:.15s; }',
            '  .tb-toggle input:checked + .tb-slider { background:#1B8AED; }',
            '  .tb-toggle input:checked + .tb-slider:before { transform:translateX(18px); }',
            '  .tb-picker-backdrop { display:none; position:absolute; top:0; left:0; right:0; bottom:0; background:rgba(0,0,0,0.45); z-index:1000; align-items:center; justify-content:center; }',
            '  .tb-picker-backdrop.open { display:flex; }',
            '  .tb-picker { position:relative; background:#fff; color:#222; width:560px; max-width:90%; border-radius:6px; box-shadow:0 4px 24px rgba(0,0,0,0.35); display:flex; flex-direction:column; }',
            '  .tb-picker-header { padding:12px 16px; border-bottom:1px solid #eee; font-weight:bold; font-size:14px; display:flex; justify-content:space-between; align-items:center; }',
            '  .tb-picker-close { border:none; background:none; font-size:16px; cursor:pointer; color:#666; line-height:1; padding:4px; }',
            '  .tb-picker-close:hover { color:#000; }',
            '  .tb-picker-body { height:280px; min-height:280px; overflow-y:auto; padding:6px 0; }',
            '  .tb-picker-item { padding:7px 16px; cursor:pointer; font-size:13px; }',
            '  .tb-picker-item:hover { background:#f0f6ff; }',
            '  .tb-picker-msg { padding:16px; color:#888; font-size:13px; }',
            '  .tb-picker-footer { padding:12px 16px 16px 16px; border-top:1px solid #eee; display:flex; flex-direction:column; gap:8px; }',
            '  .tb-picker-path { align-self:flex-start; font-size:13px; color:#888; word-break:break-all; margin:8px 0; min-height:17px; }',
            '  .tb-picker-select { align-self:flex-end; padding:5px 18px; border:1px solid #1B8AED; background:#1B8AED; color:#fff; border-radius:4px; cursor:pointer; font-weight:bold; font-size:13px; }',
            '  .tb-picker-select:disabled { border-color:#ccc; background:#ccc; cursor:default; }',
            '</style>',
            '<div class="tb-body">',
            '  <div class="tb-toolbar">',
            '    <button type="button" class="tb-save" disabled>Save</button>',
            '    <button type="button" class="tb-refresh">Refresh</button>',
            '    <img class="tb-spinner" src="/webman/3rdparty/Syno_Toolbox/images/wait_triangle_blue_40p.gif" alt="" width="20" height="20">',
            '    <span class="tb-status"></span>',
            '  </div>',
            '  <div class="tb-tabs">',
            '    <button type="button" class="tb-tab tb-tab-active" data-category="info">Info</button>',
            '    <button type="button" class="tb-tab" data-category="tools">Tools</button>',
            '  </div>',
            '  <div class="tb-list">',
            '    <div class="tb-panel tb-panel-active" data-panel="info"><div style="padding:20px;color:#999;">Loading&hellip;</div></div>',
            '    <div class="tb-panel" data-panel="tools"></div>',
            '  </div>',
            '  <div class="tb-picker-backdrop">',
            '    <div class="tb-picker">',
            '      <div class="tb-picker-header"><span>Select Folder</span><button type="button" class="tb-picker-close" aria-label="Close">\u00d7</button></div>',
            '      <div class="tb-picker-body"></div>',
            '      <div class="tb-picker-footer"><span class="tb-picker-path"></span><button type="button" class="tb-picker-select">Select This Folder</button></div>',
            '    </div>',
            '  </div>',
            '</div>'
        ].join("");
    },

    onAfterRender: function() {
        var el = this.body.dom;
        this.listEl = el.querySelector(".tb-list");
        this.infoPanel = el.querySelector('.tb-panel[data-panel="info"]');
        this.toolsPanel = el.querySelector('.tb-panel[data-panel="tools"]');
        this.statusEl = el.querySelector(".tb-status");
        this.spinnerEl = el.querySelector(".tb-spinner");
        this.saveBtn = el.querySelector(".tb-save");

        Ext.fly(el.querySelector(".tb-refresh")).on("click", this.loadState, this);
        Ext.fly(this.saveBtn).on("click", this.onSave, this);

        Ext.each(el.querySelectorAll(".tb-tab"), function(tabBtn) {
            Ext.fly(tabBtn).on("click", (function() { this.switchTab(tabBtn.getAttribute("data-category")); }).createDelegate(this));
        }, this);

        this.pickerBackdrop = el.querySelector(".tb-picker-backdrop");
        this.pickerBody = el.querySelector(".tb-picker-body");
        this.pickerPathEl = el.querySelector(".tb-picker-path");
        this.pickerSelectBtn = el.querySelector(".tb-picker-select");
        Ext.fly(el.querySelector(".tb-picker-close")).on("click", this.closeFolderPicker, this);
        Ext.fly(el.querySelector(".tb-picker-select")).on("click", this.pickerSelectCurrent, this);
        Ext.fly(this.pickerBackdrop).on("click", (function(ev) {
            if (ev.getTarget() === this.pickerBackdrop) { this.closeFolderPicker(); }
        }).createDelegate(this));

        // DSM's desktop chrome suppresses the native right-click menu
        // globally (likely a document-level listener, same instinct as
        // the user-select:none override above). Stopping propagation
        // here keeps it from reaching that handler, so Copy etc. shows
        // up normally over our own content.
        Ext.fly(el).on("contextmenu", function(ev) { ev.stopPropagation(); });

        // Same idea for text selection itself (reported broken on DSM 6):
        // if DSM's chrome also listens for selectstart globally and calls
        // preventDefault, our user-select:text CSS can't override that at
        // the JS level - stopping propagation here keeps the event from
        // ever reaching that listener.
        Ext.fly(el).on("selectstart", function(ev) { ev.stopPropagation(); });

        this.loadState();
    },

    switchTab: function(category) {
        var el = this.body.dom;
        Ext.each(el.querySelectorAll(".tb-tab"), function(tabBtn) {
            Ext.fly(tabBtn)[tabBtn.getAttribute("data-category") === category ? "addClass" : "removeClass"]("tb-tab-active");
        });
        Ext.fly(this.infoPanel)[category === "info" ? "addClass" : "removeClass"]("tb-panel-active");
        Ext.fly(this.toolsPanel)[category === "tools" ? "addClass" : "removeClass"]("tb-panel-active");
    },

    // ---------------------------------------------------------------
    // Folder picker - routed entirely through our own privileged backend
    // (listshares / listfolder actions), not the Synology webapi directly.
    // Backend already runs as root, so it can just read the filesystem -
    // no SynoToken, no DSM 6 vs 7 API-version branching, and everything
    // stays in real /volumeN/... paths end to end (no virtual-path
    // mapping needed, since neither listshares nor listfolder ever
    // returns a FileStation-style virtual path).
    // ---------------------------------------------------------------
    openFolderPicker: function(inputEl) {
        this.pickerTargetInput = inputEl;
        this.pickerCurrentReal = "";
        this.pickerPathEl.textContent = "";
        Ext.fly(this.pickerBackdrop).addClass("open");
        this.pickerLoadShares();
    },

    closeFolderPicker: function() {
        Ext.fly(this.pickerBackdrop).removeClass("open");
    },

    pickerLoadShares: function() {
        this.pickerCurrentReal = "";
        this.pickerPathEl.textContent = "";
        this.pickerSelectBtn.disabled = true;
        this.pickerBody.innerHTML = '<div class="tb-picker-msg">Loading\u2026</div>';
        SYNO.SDS.Syno_Toolbox.apiCall("listshares", {}, (function(resp) {
            if (!resp || !resp.success || !resp.result || !resp.result.length) {
                this.pickerBody.innerHTML = '<div class="tb-picker-msg">' +
                    ((resp && resp.message) || "No shared folders found.") + '</div>';
                return;
            }
            this.pickerBody.innerHTML = resp.result.map(function(share) {
                return '<div class="tb-picker-item" data-path="' + Ext.util.Format.htmlEncode(share.path) + '">\uD83D\uDCC1 ' +
                    Ext.util.Format.htmlEncode(share.name) + '</div>';
            }).join("");
            this.pickerWireItems();
        }).createDelegate(this));
    },

    pickerLoadFolder: function(path) {
        this.pickerCurrentReal = path;
        this.pickerPathEl.textContent = path.replace(/^\/volume\d+/, "") || "/";
        this.pickerSelectBtn.disabled = false;
        this.pickerBody.innerHTML = '<div class="tb-picker-msg">Loading\u2026</div>';
        SYNO.SDS.Syno_Toolbox.apiCall("listfolder", { path: path }, (function(resp) {
            if (!resp || !resp.success) {
                this.pickerBody.innerHTML = '<div class="tb-picker-msg" style="color:#c00;">' +
                    Ext.util.Format.htmlEncode((resp && resp.message) || "Could not list this folder.") + '</div>' +
                    '<div class="tb-picker-item" data-back="shares">\u2b05\ufe0f Shares</div>';
                this.pickerWireItems();
                return;
            }
            var html = '<div class="tb-picker-item" data-back="shares">\u2b05\ufe0f Shares</div>';
            var parent = path.substring(0, path.lastIndexOf("/")) || "/";
            if (parent.split("/").length > 2) {
                html += '<div class="tb-picker-item" data-path="' + Ext.util.Format.htmlEncode(parent) + '">\u2b06\ufe0f .. (up)</div>';
            }
            resp.result.forEach(function(f) {
                html += '<div class="tb-picker-item" data-path="' + Ext.util.Format.htmlEncode(f.path) + '">\uD83D\uDCC1 ' +
                    Ext.util.Format.htmlEncode(f.name) + '</div>';
            });
            this.pickerBody.innerHTML = html;
            this.pickerWireItems();
        }).createDelegate(this));
    },

    pickerWireItems: function() {
        var self = this;
        Ext.each(this.pickerBody.querySelectorAll(".tb-picker-item"), function(item) {
            Ext.fly(item).on("click", function() {
                if (item.getAttribute("data-back") === "shares") {
                    self.pickerLoadShares();
                    return;
                }
                self.pickerLoadFolder(item.getAttribute("data-path"));
            });
        });
    },

    pickerSelectCurrent: function() {
        if (!this.pickerCurrentReal || !this.pickerTargetInput) { return; }
        this.pickerTargetInput.value = this.pickerCurrentReal;
        this.setDirty(true);
        this.closeFolderPicker();
    },

    setStatus: function(msg, busy) {
        if (this.statusEl) { this.statusEl.textContent = msg || ""; }
        if (this.spinnerEl) {
            if (busy && msg) {
                Ext.fly(this.spinnerEl).addClass("show");
            } else {
                Ext.fly(this.spinnerEl).removeClass("show");
            }
        }
    },

    setDirty: function(dirty) {
        this.dirty = dirty;
        this.saveBtn.disabled = !dirty;
    },

    // ---------------------------------------------------------------
    // Load module state and render rows
    // ---------------------------------------------------------------
    loadState: function() {
        this.setStatus("Loading\u2026", true);
        SYNO.SDS.Syno_Toolbox.apiCall("getstate", {}, (function(resp) {
            if (!resp || !resp.success) {
                this.setStatus((resp && resp.message) || "Failed to load state");
                this.infoPanel.innerHTML = '<div style="padding:20px;color:#c00;">Could not load modules.</div>';
                this.toolsPanel.innerHTML = "";
                return;
            }
            this.modules = resp.result || [];
            this.renderList();
            this.setStatus("");
            this.setDirty(false);
        }).createDelegate(this));
    },

    renderList: function() {
        var self = this;
        var infoMods = this.modules.filter(function(m) { return m.category !== "tools"; });
        var toolsMods = this.modules.filter(function(m) { return m.category === "tools"; });

        var infoHtml = infoMods.map(this.renderRow, this).join("");
        var toolsHtml = toolsMods.map(this.renderRow, this).join("");

        this.infoPanel.innerHTML = infoHtml || '<div style="padding:20px;color:#999;">No info modules.</div>';
        this.toolsPanel.innerHTML = toolsHtml || '<div style="padding:20px;color:#999;">No tool modules.</div>';
        this.wireRows();
    },

    // ---------------------------------------------------------------
    // Row rendering per control type
    // ---------------------------------------------------------------
    renderRow: function(mod) {
        var checked = mod.current_enabled === "yes" ? "checked" : "";
        var controlsHtml = this.renderControls(mod);
        var hasCheckArgs = !!(mod.check_args && mod.check_args !== null);
        var resultClass = mod.result_style === "monospace" ? "tb-row-result tb-row-result-monospace" : "tb-row-result";
        var resultHtml = (mod.control === "toggle-display" || mod.control === "toggle-run" || hasCheckArgs || mod.live === true)
            ? '<div class="' + resultClass + '" data-result-for="' + mod.id + '"></div>'
            : "";
        // Pure info modules - live display with no real enable/disable
        // action behind them - have a toggle that doesn't gate anything,
        // so hide it (visibility, not display, to keep row alignment).
        var toggleHiddenClass = (mod.live === true && hasCheckArgs) ? " tb-toggle-hidden" : "";

        return [
            '<div class="tb-row" data-module-id="' + mod.id + '">',
            '  <label class="tb-toggle' + toggleHiddenClass + '">',
            '    <input type="checkbox" class="tb-enabled" ' + checked + '>',
            '    <span class="tb-slider"></span>',
            '  </label>',
            '  <div class="tb-row-main">',
            '    <div class="tb-row-name">' + Ext.util.Format.htmlEncode(mod.name) + '</div>',
            controlsHtml ? '    <div class="tb-row-controls">' + controlsHtml + '</div>' : "",
            resultHtml,
            '  </div>',
            '</div>'
        ].join("");
    },

    // Extra per-control-type fields, alongside the universal enable toggle.
    renderControls: function(mod) {
        var f = mod.current_fields || {};
        switch (mod.control) {

            case "toggle-schedule":
                return this.renderHourSelect(mod.schedule && mod.schedule.default_repeat_hour, f.hour);

            case "toggle-config-backup":
                return this.renderConfigBackupControls(mod, f);

            case "toggle-filepicker":
                return '<label>' + (mod.filepicker && mod.filepicker.label || "Path") + ':</label> ' +
                    '<input type="text" class="tb-path" placeholder="/volume1/backup" value="' + Ext.util.Format.htmlEncode(f.path || "") + '">' +
                    ' <button type="button" class="tb-browse">Browse\u2026</button>';

            case "toggle-volume-numeric":
                var def = (mod.numeric && mod.numeric.default) || 1024;
                var min = (mod.numeric && mod.numeric.min) || 4;
                var kbVal = f.kb || def;
                return '<div class="tb-volumes-wrap" data-source="listvolumes"><span style="color:#999;">Loading volumes\u2026</span></div>' +
                    ' <label>' + (mod.numeric && mod.numeric.label || "Value") + ':</label> ' +
                    '<input type="number" class="tb-kb" min="' + min + '" value="' + kbVal + '">';

            case "toggle-selector":
                var opts = (mod.selector && mod.selector.options) || [];
                var currentMode = f.mode || (opts[0] && opts[0].value);
                var optHtml = opts.map(function(o) {
                    var sel = o.value === currentMode ? " selected" : "";
                    return '<option value="' + o.value + '"' + sel + '>' + o.label + '</option>';
                }).join("");
                var sec = mod.selector && mod.selector.secondary_toggle;
                var secChecked = sec && f.raidf1 === sec.value ? " checked" : "";
                return '<select class="tb-mode">' + optHtml + '</select>' +
                    (sec ? ' <label><input type="checkbox" class="tb-raid-f1"' + secChecked + '> ' + sec.label + '</label>' : "");

            default:
                return "";
        }
    },

    // config_backup's real shape: a local target dir, plus up to 2 optional
    // remote SSH backup destinations. "Discover NAS" is repurposed here to
    // prefill a Remote IP field rather than building an arbitrary target list.
    renderConfigBackupControls: function(mod, f) {
        var self = this;
        var remoteBlock = function(prefix, title) {
            var checked = f[prefix + "backup"] === "yes" ? "checked" : "";
            return [
                '<div class="tb-remote-block" data-prefix="' + prefix + '" style="width:100%;border-top:1px dashed #ddd;margin-top:8px;padding-top:6px;">',
                '  <label><input type="checkbox" class="tb-remote-backup"' + checked + '> ' + title + '</label>',
                '  <div class="tb-remote-fields" style="margin-top:4px;display:flex;flex-wrap:wrap;gap:6px;">',
                '    <input type="text" class="tb-remote-ip" placeholder="Remote IP" value="' + Ext.util.Format.htmlEncode(f[prefix + "ip"] || "") + '" style="width:110px;">',
                '    <input type="number" class="tb-remote-port" placeholder="Port" value="' + Ext.util.Format.htmlEncode(f[prefix + "port"] || "22") + '" style="width:60px;">',
                '    <input type="text" class="tb-remote-dir" placeholder="Remote dir" value="' + Ext.util.Format.htmlEncode(f[prefix + "dir"] || "") + '" style="width:130px;">',
                '    <input type="text" class="tb-local-user" placeholder="Local user" value="' + Ext.util.Format.htmlEncode(f["local_user" + (prefix === "remote2_" ? "2" : "")] || "") + '" style="width:90px;">',
                '    <input type="text" class="tb-remote-user" placeholder="Remote user" value="' + Ext.util.Format.htmlEncode(f[prefix + "user"] || "") + '" style="width:90px;">',
                '    <button type="button" class="tb-discover-remote">Discover NAS\u2026</button>',
                '  </div>',
                '</div>'
            ].join("");
        };

        return this.renderHourSelect(mod.schedule && mod.schedule.default_repeat_hour, f.hour) +
            ' <label>Target dir:</label> <input type="text" class="tb-target-dir" placeholder="/volume1/backup" value="' + Ext.util.Format.htmlEncode(f.target_dir || "") + '" style="width:160px;">' +
            ' <button type="button" class="tb-browse-target-dir">Browse\u2026</button>' +
            remoteBlock("remote_", "Remote backup") +
            remoteBlock("remote2_", "2nd remote backup") +
            '<div class="tb-discover-status" style="width:100%;color:#888;margin-top:4px;"></div>' +
            '<div class="tb-discover-results" style="width:100%;"></div>';
    },

    renderHourSelect: function(defaultHour, currentHour) {
        var selectedHour = parseInt(currentHour, 10) || defaultHour || 6;
        var opts = "";
        for (var h = 1; h <= 11; h++) {
            opts += '<option value="' + h + '"' + (h === selectedHour ? " selected" : "") + '>Every ' + h + ' hour' + (h > 1 ? "s" : "") + '</option>';
        }
        return '<label>Frequency:</label> <select class="tb-hour">' + opts + '</select>';
    },

    // ---------------------------------------------------------------
    // Wire per-row events after render
    // ---------------------------------------------------------------
    wireRows: function() {
        var rows = this.listEl.querySelectorAll(".tb-row");
        Ext.each(rows, function(rowEl) {
            var moduleId = rowEl.getAttribute("data-module-id");
            var mod = this.findModule(moduleId);
            var checkbox = rowEl.querySelector(".tb-enabled");
            var hasCheckArgs = !!(mod && mod.check_args && mod.check_args !== null);

            Ext.fly(checkbox).on("change", (function() {
                this.setDirty(true);
                // "live" modules re-run their result on toggle, but only
                // while enabled - unlike check_args modules (below), which
                // always reflect the NAS's actual state regardless of the
                // toggle.
                if (mod && mod.live === true && !hasCheckArgs) {
                    if (checkbox.checked) {
                        this.runModule(moduleId, rowEl);
                    } else {
                        var resultEl = rowEl.querySelector('[data-result-for="' + moduleId + '"]');
                        if (resultEl) { resultEl.textContent = ""; }
                    }
                }
            }).createDelegate(this));

            Ext.each(rowEl.querySelectorAll("input, select"), function(field) {
                if (field === checkbox) { return; }
                Ext.fly(field).on("change", (function() { this.setDirty(true); }).createDelegate(this));
            }, this);

            if (hasCheckArgs) {
                // Always reflects the NAS's real current state, regardless
                // of whether this module's toggle is on or off.
                this.checkModule(moduleId, rowEl);
            } else if (mod && mod.live === true && checkbox.checked) {
                // Live modules (no check_args) only show a result while
                // their own toggle is enabled.
                this.runModule(moduleId, rowEl);
            }

            var volumesWrap = rowEl.querySelector(".tb-volumes-wrap");
            if (volumesWrap) {
                this.populateVolumes(volumesWrap, mod, rowEl);
            }

            var browseBtn = rowEl.querySelector(".tb-browse");
            if (browseBtn) {
                var pathInput = rowEl.querySelector(".tb-path");
                Ext.fly(browseBtn).on("click", (function() { this.openFolderPicker(pathInput); }).createDelegate(this));
            }

            var browseTargetDirBtn = rowEl.querySelector(".tb-browse-target-dir");
            if (browseTargetDirBtn) {
                var targetDirInput = rowEl.querySelector(".tb-target-dir");
                Ext.fly(browseTargetDirBtn).on("click", (function() { this.openFolderPicker(targetDirInput); }).createDelegate(this));
            }

            if (mod && mod.control === "toggle-config-backup") {
                this.wireConfigBackupRow(rowEl, mod);
            }
        }, this);
    },

    // ---------------------------------------------------------------
    // Volume checkboxes (seq_io) - populated from listvolumes
    // ---------------------------------------------------------------
    populateVolumes: function(wrapEl, mod, rowEl) {
        SYNO.SDS.Syno_Toolbox.apiCall("listvolumes", {}, (function(resp) {
            if (!resp || !resp.success || !resp.result || !resp.result.length) {
                wrapEl.innerHTML = '<span style="color:#c00;">No mounted volumes found</span>';
                return;
            }
            var current = ((mod.current_fields && mod.current_fields.volumes) || "").split(",");
            wrapEl.innerHTML = resp.result.map(function(vol) {
                var checked = current.indexOf(vol) !== -1 ? "checked" : "";
                return '<label style="margin-right:10px;"><input type="checkbox" class="tb-volume-cb" value="' + vol + '" ' + checked + '> ' + vol + '</label>';
            }).join("");
            Ext.each(wrapEl.querySelectorAll(".tb-volume-cb"), function(cb) {
                Ext.fly(cb).on("change", (function() { this.setDirty(true); }).createDelegate(this));
            }, this);
        }).createDelegate(this));
    },

    // ---------------------------------------------------------------
    // config_backup row: each remote block has its own "Discover NAS"
    // button that fills that block's IP field from a picked result -
    // this replaces the earlier (wrong) design where discovery built an
    // arbitrary multi-target list. Config Backup only ever has 2 remote
    // slots, fixed by the script itself.
    // ---------------------------------------------------------------
    wireConfigBackupRow: function(rowEl, mod) {
        var statusEl = rowEl.querySelector(".tb-discover-status");
        var resultsEl = rowEl.querySelector(".tb-discover-results");

        Ext.each(rowEl.querySelectorAll(".tb-discover-remote"), function(btn) {
            var block = btn.closest ? btn.closest(".tb-remote-block") : null;
            Ext.fly(btn).on("click", (function() {
                statusEl.textContent = "Searching\u2026";
                resultsEl.innerHTML = "";
                SYNO.SDS.Syno_Toolbox.apiCall("discovernas", {}, (function(resp) {
                    if (!resp || !resp.success) {
                        statusEl.textContent = (resp && resp.message) || "Discovery failed";
                        return;
                    }
                    statusEl.textContent = resp.result.length + " found - click one to use as this remote's IP";
                    resultsEl.innerHTML = resp.result.map(function(nas) {
                        return '<div class="tb-discover-row" data-ip="' + Ext.util.Format.htmlEncode(nas.ip || "") +
                            '" style="cursor:pointer;padding:2px 0;color:#1B8AED;">' +
                            '+ ' + Ext.util.Format.htmlEncode(nas.hostname || nas.ip) + ' (' + Ext.util.Format.htmlEncode(nas.ip || "") + ', ' + Ext.util.Format.htmlEncode(nas.model || "?") + ')</div>';
                    }).join("");
                    Ext.each(resultsEl.querySelectorAll(".tb-discover-row"), function(rowDiv) {
                        Ext.fly(rowDiv).on("click", (function() {
                            var ipField = rowEl.querySelector('.tb-remote-block[data-prefix="' +
                                (block ? block.getAttribute("data-prefix") : "remote_") + '"] .tb-remote-ip');
                            if (ipField) { ipField.value = rowDiv.getAttribute("data-ip"); }
                            resultsEl.innerHTML = "";
                            statusEl.textContent = "";
                            this.setDirty(true);
                        }).createDelegate(this));
                    }, this);
                }).createDelegate(this));
            }).createDelegate(this));
        }, this);
    },

    findModule: function(id) {
        for (var i = 0; i < this.modules.length; i++) {
            if (this.modules[i].id === id) { return this.modules[i]; }
        }
        return null;
    },

    // Escapes module output by default, then selectively re-enables a single,
    // tightly-matched <a href="https://...">label</a> pattern - the only HTML
    // a module's check/run output is allowed to carry. Everything else in the
    // string stays escaped, so module output can never inject arbitrary HTML.
    safeResultHtml: function(text) {
        var escaped = Ext.util.Format.htmlEncode(text);
        return escaped.replace(
            /&lt;a href=&quot;(https:\/\/[^&"]+)&quot;&gt;([^&<]*)&lt;\/a&gt;/g,
            '<a href="$1" target="_blank" rel="noopener noreferrer">$2</a>'
        );
    },

    runModule: function(moduleId, rowEl) {
        var resultEl = rowEl.querySelector('[data-result-for="' + moduleId + '"]');
        if (resultEl) { resultEl.textContent = "Running\u2026"; }
        SYNO.SDS.Syno_Toolbox.apiCall("run", { module_id: moduleId }, (function(resp) {
            if (!resultEl) { return; }
            resultEl.innerHTML = resp && resp.success
                ? this.safeResultHtml(resp.result || "(no output)")
                : this.safeResultHtml("Error: " + ((resp && resp.message) || "unknown"));
        }).createDelegate(this));
    },

    // Runs a module's check_args and shows the result - this reflects the
    // NAS's actual current state and always runs regardless of whether
    // the module's own toggle is enabled or disabled.
    checkModule: function(moduleId, rowEl) {
        var resultEl = rowEl.querySelector('[data-result-for="' + moduleId + '"]');
        if (resultEl) { resultEl.textContent = "Checking\u2026"; }
        SYNO.SDS.Syno_Toolbox.apiCall("check", { module_id: moduleId }, (function(resp) {
            if (!resultEl) { return; }
            resultEl.innerHTML = resp && resp.success
                ? this.safeResultHtml(resp.result || "(no output)")
                : this.safeResultHtml("Error: " + ((resp && resp.message) || "unknown"));
        }).createDelegate(this));
    },

    // ---------------------------------------------------------------
    // Collect current row state into the flat key=value shape
    // synotoolbox_api.sh's save action expects.
    // ---------------------------------------------------------------
    collectFormJson: function() {
        var form = {};
        var rows = this.listEl.querySelectorAll(".tb-row");
        Ext.each(rows, function(rowEl) {
            var id = rowEl.getAttribute("data-module-id");
            var checkbox = rowEl.querySelector(".tb-enabled");
            form[id + "_enabled"] = checkbox.checked ? "yes" : "no";

            var hourEl = rowEl.querySelector(".tb-hour");
            if (hourEl) { form[id + "_hour"] = hourEl.value; }

            if (rowEl.getAttribute("data-module-id") === "config_backup" ||
                rowEl.querySelector(".tb-target-dir")) {
                var targetDirEl = rowEl.querySelector(".tb-target-dir");
                if (targetDirEl) { form[id + "_target_dir"] = targetDirEl.value; }

                Ext.each(rowEl.querySelectorAll(".tb-remote-block"), function(block) {
                    var prefix = block.getAttribute("data-prefix"); // "remote_" or "remote2_"
                    var backupCb = block.querySelector(".tb-remote-backup");
                    form[id + "_" + prefix + "backup"] = backupCb && backupCb.checked ? "yes" : "no";
                    form[id + "_" + prefix + "ip"] = block.querySelector(".tb-remote-ip").value;
                    form[id + "_" + prefix + "port"] = block.querySelector(".tb-remote-port").value;
                    form[id + "_" + prefix + "dir"] = block.querySelector(".tb-remote-dir").value;
                    form[id + "_" + prefix + "user"] = block.querySelector(".tb-remote-user").value;
                    var localUserKey = prefix === "remote2_" ? "local_user2" : "local_user";
                    form[id + "_" + localUserKey] = block.querySelector(".tb-local-user").value;
                });
            }

            var pathEl = rowEl.querySelector(".tb-path");
            if (pathEl) { form[id + "_path"] = pathEl.value; }

            var volumesWrap = rowEl.querySelector(".tb-volumes-wrap");
            if (volumesWrap) {
                var vols = [];
                Ext.each(volumesWrap.querySelectorAll(".tb-volume-cb:checked"), function(cb) { vols.push(cb.value); });
                form[id + "_volumes"] = vols.join(",");
            }

            var kbEl = rowEl.querySelector(".tb-kb");
            if (kbEl) { form[id + "_kb"] = kbEl.value; }

            var modeEl = rowEl.querySelector(".tb-mode");
            if (modeEl) { form[id + "_mode"] = modeEl.value; }

            var raidF1El = rowEl.querySelector(".tb-raid-f1");
            if (raidF1El) { form[id + "_raidf1"] = raidF1El.checked ? "raidf1" : ""; }
        });
        return form;
    },

    onSave: function() {
        this.setStatus("Saving\u2026", true);
        this.saveBtn.disabled = true;
        var formData = this.collectFormJson();
        var changedIds = this.computeChangedModuleIds(formData);
        var formJson = Ext.encode(formData);
        SYNO.SDS.Syno_Toolbox.apiCall("save", { form_json: formJson }, "POST", (function(resp) {
            if (resp && resp.success) {
                this.setStatus("Saved");
                this.refreshAfterSave(changedIds, resp.results || {});
            } else {
                this.setStatus((resp && resp.message) || "Failed to save");
                this.saveBtn.disabled = false;
            }
        }).createDelegate(this));
    },

    // Which modules' _enabled state actually flipped, compared to what was
    // loaded (i.e. what the backend's own save-diff will have acted on).
    // Only these need their result text refreshed - editing seq_io's kb
    // value without toggling it, for example, doesn't change any other
    // row and shouldn't touch it.
    computeChangedModuleIds: function(formData) {
        var changed = [];
        this.modules.forEach(function(mod) {
            if (formData[mod.id + "_enabled"] !== mod.current_enabled) {
                changed.push(mod.id);
            }
        });
        return changed;
    },

    // Re-fetches state (cheap - one JSON call) to refresh the baseline for
    // the next Save's diff, but does NOT rebuild the DOM or re-run
    // listvolumes/listshares/discovernas/check/run for every row. Only the
    // rows whose enabled state actually changed this save get their result
    // text re-run, since those are the only ones the backend just acted on.
    // save()'s own captured output is shown directly when present (this is
    // the only place the "hard refresh" style messages can ever appear -
    // check_args is a read-only probe and never prints them). checkModule
    // is only a fallback for modules like restore_fan_speed that have no
    // disable_args, so save() ran nothing for them to capture.
    refreshAfterSave: function(changedIds, results) {
        SYNO.SDS.Syno_Toolbox.apiCall("getstate", {}, (function(resp) {
            this.setDirty(false);
            if (!resp || !resp.success) { return; }
            this.modules = resp.result || [];

            changedIds.forEach(function(id) {
                var rowEl = this.listEl.querySelector('.tb-row[data-module-id="' + id + '"]');
                var mod = this.findModule(id);
                if (!rowEl || !mod) { return; }
                var hasCheckArgs = !!(mod.check_args && mod.check_args !== null);

                if (results && results[id] !== undefined) {
                    var resultEl = rowEl.querySelector('[data-result-for="' + id + '"]');
                    if (resultEl) { resultEl.innerHTML = this.safeResultHtml(results[id] || "(no output)"); }
                } else if (hasCheckArgs) {
                    this.checkModule(id, rowEl);
                } else if (mod.live === true) {
                    var checkbox = rowEl.querySelector(".tb-enabled");
                    if (checkbox && checkbox.checked) {
                        this.runModule(id, rowEl);
                    } else {
                        var resultEl2 = rowEl.querySelector('[data-result-for="' + id + '"]');
                        if (resultEl2) { resultEl2.textContent = ""; }
                    }
                }
            }, this);
        }).createDelegate(this));
    },

    onClose: function() {
        SYNO.SDS.Syno_Toolbox.MainWindow.superclass.onClose.apply(this, arguments);
        this.doClose();
        return true;
    }
});
