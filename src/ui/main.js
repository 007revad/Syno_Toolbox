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
            '  .tb-list { flex:1 1 auto; overflow:auto; border:1px solid #e0e0e0; border-radius:4px; }',
            '  .tb-row { display:flex; align-items:flex-start; gap:12px; padding:10px 12px; border-bottom:1px solid #eee; }',
            '  .tb-row:last-child { border-bottom:none; }',
            '  .tb-row-main { flex:1 1 auto; }',
            '  .tb-row-name { font-weight:bold; font-size:13px; }',
            '  .tb-row-controls { margin-top:6px; display:flex; flex-wrap:wrap; align-items:center; gap:8px; font-size:12px; color:#555; }',
            '  .tb-row-controls input[type=text], .tb-row-controls input[type=number], .tb-row-controls select { padding:3px 5px; font-size:12px; border:1px solid #ccc; border-radius:3px; }',
            '  .tb-row-result { margin-top:6px; font-family:Verdana,Arial,sans-serif; font-size:11px; color:#777; white-space:pre-wrap; }',
            '  .tb-toggle { width:38px; height:20px; position:relative; display:inline-block; flex:0 0 auto; }',
            '  .tb-toggle input { opacity:0; width:0; height:0; }',
            '  .tb-toggle .tb-slider { position:absolute; inset:0; background:#ccc; border-radius:20px; cursor:pointer; transition:.15s; }',
            '  .tb-toggle .tb-slider:before { content:""; position:absolute; height:16px; width:16px; left:2px; top:2px; background:#fff; border-radius:50%; transition:.15s; }',
            '  .tb-toggle input:checked + .tb-slider { background:#1B8AED; }',
            '  .tb-toggle input:checked + .tb-slider:before { transform:translateX(18px); }',
            '</style>',
            '<div class="tb-body">',
            '  <div class="tb-toolbar">',
            '    <button type="button" class="tb-save" disabled>Save</button>',
            '    <button type="button" class="tb-refresh">Refresh</button>',
            '    <span class="tb-status"></span>',
            '  </div>',
            '  <div class="tb-list"><div style="padding:20px;color:#999;">Loading&hellip;</div></div>',
            '</div>'
        ].join("");
    },

    onAfterRender: function() {
        var el = this.body.dom;
        this.listEl = el.querySelector(".tb-list");
        this.statusEl = el.querySelector(".tb-status");
        this.saveBtn = el.querySelector(".tb-save");

        Ext.fly(el.querySelector(".tb-refresh")).on("click", this.loadState, this);
        Ext.fly(this.saveBtn).on("click", this.onSave, this);
        Ext.fly(el).on("contextmenu", function(ev) { ev.stopPropagation(); });

        this.loadState();
    },

    setStatus: function(msg) {
        if (this.statusEl) { this.statusEl.textContent = msg || ""; }
    },

    setDirty: function(dirty) {
        this.dirty = dirty;
        this.saveBtn.disabled = !dirty;
    },

    // ---------------------------------------------------------------
    // Load module state and render rows
    // ---------------------------------------------------------------
    loadState: function() {
        this.setStatus("Loading\u2026");
        SYNO.SDS.Syno_Toolbox.apiCall("getstate", {}, (function(resp) {
            if (!resp || !resp.success) {
                this.setStatus((resp && resp.message) || "Failed to load state");
                this.listEl.innerHTML = '<div style="padding:20px;color:#c00;">Could not load modules.</div>';
                return;
            }
            this.modules = resp.result || [];
            this.renderList();
            this.setStatus("");
            this.setDirty(false);
        }).createDelegate(this));
    },

    renderList: function() {
        var html = this.modules.map(this.renderRow, this).join("");
        this.listEl.innerHTML = html || '<div style="padding:20px;color:#999;">No modules found.</div>';
        this.wireRows();
    },

    // ---------------------------------------------------------------
    // Row rendering per control type
    // ---------------------------------------------------------------
    renderRow: function(mod) {
        var checked = mod.current_enabled === "yes" ? "checked" : "";
        var controlsHtml = this.renderControls(mod);
        var hasCheckArgs = !!(mod.check_args && mod.check_args !== null);
        var resultHtml = (mod.control === "toggle-display" || mod.control === "toggle-run" || hasCheckArgs || mod.live === true)
            ? '<div class="tb-row-result" data-result-for="' + mod.id + '"></div>'
            : "";

        return [
            '<div class="tb-row" data-module-id="' + mod.id + '">',
            '  <label class="tb-toggle">',
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
                    ' <button type="button" class="tb-browse" disabled title="DSM file picker not yet wired">Browse\u2026</button>';

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

    runModule: function(moduleId, rowEl) {
        var resultEl = rowEl.querySelector('[data-result-for="' + moduleId + '"]');
        if (resultEl) { resultEl.textContent = "Running\u2026"; }
        SYNO.SDS.Syno_Toolbox.apiCall("run", { module_id: moduleId }, (function(resp) {
            if (!resultEl) { return; }
            resultEl.textContent = resp && resp.success
                ? (resp.result || "(no output)")
                : ("Error: " + ((resp && resp.message) || "unknown"));
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
            resultEl.textContent = resp && resp.success
                ? (resp.result || "(no output)")
                : ("Error: " + ((resp && resp.message) || "unknown"));
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
        this.setStatus("Saving\u2026");
        this.saveBtn.disabled = true;
        var formJson = Ext.encode(this.collectFormJson());
        SYNO.SDS.Syno_Toolbox.apiCall("save", { form_json: formJson }, "POST", (function(resp) {
            if (resp && resp.success) {
                this.setStatus("Saved");
                this.loadState();
            } else {
                this.setStatus((resp && resp.message) || "Failed to save");
                this.saveBtn.disabled = false;
            }
        }).createDelegate(this));
    },

    onClose: function() {
        SYNO.SDS.Syno_Toolbox.MainWindow.superclass.onClose.apply(this, arguments);
        this.doClose();
        return true;
    }
});
