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
SYNO.SDS.Syno_Toolbox.APP_PATH = "/webman/3rdparty/Syno_Toolbox/";

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
            height: 570,
            minWidth: 720,
            minHeight: 570,
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
            '  .tb-panel { display:none; height:100%; }',
            '  .tb-panel.tb-panel-active { display:block; }',
            '  .tb-iframe { width:100%; height:100%; min-height:400px; border:none; display:block; }',
            '  .tb-row { display:flex; align-items:flex-start; gap:12px; padding:10px 12px; border-bottom:1px solid #eee; }',
            '  .tb-row:last-child { border-bottom:none; }',
            '  .tb-row-main { flex:1 1 auto; }',
            '  .tb-row-name { font-weight:bold; font-size:13px; }',
            '  .tb-row-controls { margin-top:6px; display:flex; flex-wrap:wrap; align-items:center; gap:8px; font-size:12px; color:#555; }',
            '  .tb-row-controls input[type=text], .tb-row-controls input[type=number], .tb-row-controls input[type=password], .tb-row-controls select { padding:3px 5px; font-size:12px; border:1px solid #ccc; border-radius:3px; }',
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
            '  .tb-wolset-backdrop { display:none; position:absolute; top:0; left:0; right:0; bottom:0; background:rgba(0,0,0,0.45); z-index:1000; align-items:center; justify-content:center; }',
            '  .tb-wolset-backdrop.open { display:flex; }',
            '  .tb-wolset { position:relative; background:#fff; color:#222; width:480px; max-width:90%; border-radius:6px; box-shadow:0 4px 24px rgba(0,0,0,0.35); display:flex; flex-direction:column; }',
            '  .tb-wolset-header { padding:12px 16px; border-bottom:1px solid #eee; font-weight:bold; font-size:14px; display:flex; justify-content:space-between; align-items:center; }',
            '  .tb-wolset-close { border:none; background:none; font-size:16px; cursor:pointer; color:#666; line-height:1; padding:4px; }',
            '  .tb-wolset-close:hover { color:#000; }',
            '  .tb-wolset-body { max-height:320px; overflow-y:auto; padding:6px 0; }',
            '  .tb-wolset-item { display:block; padding:6px 16px; font-size:13px; cursor:pointer; }',
            '  .tb-wolset-item:hover { background:#f0f6ff; }',
            '  .tb-wolset-item input { margin-right:8px; }',
            '  .tb-wolset-msg { padding:16px; color:#888; font-size:13px; }',
            '  .tb-wolset-footer { padding:12px 16px 16px 16px; border-top:1px solid #eee; display:flex; justify-content:space-between; align-items:center; gap:12px; }',
            '  .tb-wolset-hint { font-size:12px; color:#888; }',
            '  .tb-wolset-save { padding:5px 18px; border:1px solid #1B8AED; background:#1B8AED; color:#fff; border-radius:4px; cursor:pointer; font-weight:bold; font-size:13px; flex:0 0 auto; }',
            '  .tb-wolset-save:disabled { opacity:0.5; cursor:default; }',
            '  .tb-cpu-header { align-items:center; flex:0 0 auto; }',
            '  .tb-cpu-header .tb-row-main { display:flex; align-items:center; }',
            '  .tb-cpu-settings { padding:5px 14px; border:1px solid #ccc; background:#fff; border-radius:4px; cursor:pointer; font-size:12px; flex:0 0 auto; margin-left:auto; }',
            '  .tb-cpu-frame-wrap { flex:1 1 auto; min-height:0; }',
            '  .tb-cpu-disabled-msg { display:flex; align-items:center; justify-content:center; height:100%; color:#999; font-size:13px; padding:0 24px; text-align:center; }',
            '  .tb-panel[data-panel="cpu_usage"] { display:none; flex-direction:column; height:100%; }',
            '  .tb-panel[data-panel="cpu_usage"].tb-panel-active { display:flex; }',
            '  .tb-cpuset-backdrop { display:none; position:absolute; top:0; left:0; right:0; bottom:0; background:rgba(0,0,0,0.45); z-index:1000; align-items:center; justify-content:center; }',
            '  .tb-cpuset-backdrop.open { display:flex; }',
            '  .tb-cpuset { position:relative; background:#fff; color:#222; width:420px; max-width:90%; border-radius:6px; box-shadow:0 4px 24px rgba(0,0,0,0.35); display:flex; flex-direction:column; }',
            '  .tb-cpuset-header { padding:12px 16px; border-bottom:1px solid #eee; font-weight:bold; font-size:14px; display:flex; justify-content:space-between; align-items:center; }',
            '  .tb-cpuset-close { border:none; background:none; font-size:16px; cursor:pointer; color:#666; line-height:1; padding:4px; }',
            '  .tb-cpuset-close:hover { color:#000; }',
            '  .tb-cpuset-body { padding:10px; font-size:13px; }',
            '  .tb-cpuset-hint { font-size:12px; color:#888; margin-top:10px; }',
            '  .tb-cpuset-footer { padding:10px 10px 10px 10px; border-top:1px solid #eee; display:flex; justify-content:space-between; align-items:center; }',
            '  .tb-cpuset-savestatus { display:flex; align-items:center; gap:6px; font-size:13px; color:#888; }',
            '  .tb-cpuset-spinner { margin-right:0; }',
            '  .tb-cpuset-save { padding:5px 18px; border:1px solid #1B8AED; background:#1B8AED; color:#fff; border-radius:4px; cursor:pointer; font-weight:bold; font-size:13px; }',
            '  .tb-cpuset-save:disabled { opacity:0.5; cursor:default; }',
            '  .tb-backupset-backdrop { display:none; position:absolute; top:0; left:0; right:0; bottom:0; background:rgba(0,0,0,0.45); z-index:1000; align-items:center; justify-content:center; }',
            '  .tb-backupset-backdrop.open { display:flex; }',
            '  .tb-backupset { position:relative; background:#fff; color:#222; width:420px; max-width:90%; border-radius:6px; box-shadow:0 4px 24px rgba(0,0,0,0.35); display:flex; flex-direction:column; }',
            '  .tb-backupset-header { padding:12px 16px; border-bottom:1px solid #eee; font-weight:bold; font-size:14px; display:flex; justify-content:space-between; align-items:center; }',
            '  .tb-backupset-close { border:none; background:none; font-size:16px; cursor:pointer; color:#666; line-height:1; padding:4px; }',
            '  .tb-backupset-close:hover { color:#000; }',
            '  .tb-backupset-body { padding:10px; font-size:13px; }',
            '  .tb-backupset-hint { font-size:12px; color:#888; margin-top:10px; }',
            '  .tb-backupset-footer { padding:10px 10px 10px 10px; border-top:1px solid #eee; display:flex; justify-content:space-between; align-items:center; }',
            '  .tb-backupset-savestatus { display:flex; align-items:center; gap:6px; font-size:13px; color:#888; }',
            '  .tb-backupset-spinner { margin-right:0; }',
            '  .tb-backupset-save { padding:5px 18px; border:1px solid #1B8AED; background:#1B8AED; color:#fff; border-radius:4px; cursor:pointer; font-weight:bold; font-size:13px; }',
            '  .tb-backupset-save:disabled { opacity:0.5; cursor:default; }',
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
            '    <button type="button" class="tb-tab" data-category="packages">Packages</button>',
            '    <button type="button" class="tb-tab" data-category="cpu_usage">CPU Usage</button>',
            '    <button type="button" class="tb-tab" data-category="help">Help</button>',
            '    <button type="button" class="tb-tab" data-category="about">About</button>',
            '  </div>',
            '  <div class="tb-list">',
            '    <div class="tb-panel tb-panel-active" data-panel="info"><div style="padding:20px;color:#999;">Loading&hellip;</div></div>',
            '    <div class="tb-panel" data-panel="tools"></div>',
            '    <div class="tb-panel" data-panel="packages"></div>',
            '    <div class="tb-panel" data-panel="cpu_usage">',
            '      <div class="tb-row tb-cpu-header" data-module-id="cpu_usage">',
            '        <label class="tb-toggle">',
            '          <input type="checkbox" class="tb-enabled">',
            '          <span class="tb-slider"></span>',
            '        </label>',
            '        <div class="tb-row-main">',
            '          <div class="tb-row-name">CPU Usage</div>',
            '        </div>',
            '        <button type="button" class="tb-cpu-settings">Settings</button>',
            '        <input type="hidden" class="tb-cpu-interval">',
            '      </div>',
            '      <div class="tb-cpu-frame-wrap"></div>',
            '    </div>',
            '    <div class="tb-panel" data-panel="help"></div>',
            '    <div class="tb-panel" data-panel="about"></div>',
            '  </div>',
            '  <div class="tb-picker-backdrop">',
            '    <div class="tb-picker">',
            '      <div class="tb-picker-header"><span>Select Folder</span><button type="button" class="tb-picker-close" aria-label="Close">\u00d7</button></div>',
            '      <div class="tb-picker-body"></div>',
            '      <div class="tb-picker-footer"><span class="tb-picker-path"></span><button type="button" class="tb-picker-select">Select This Folder</button></div>',
            '    </div>',
            '  </div>',
            '  <div class="tb-wolset-backdrop">',
            '    <div class="tb-wolset">',
            '      <div class="tb-wolset-header"><span>Hidden Devices</span><button type="button" class="tb-wolset-close" aria-label="Close">\u00d7</button></div>',
            '      <div class="tb-wolset-body"></div>',
            '      <div class="tb-wolset-footer"><span class="tb-wolset-hint">Checked devices are hidden from the Send WOL list</span><button type="button" class="tb-wolset-save">Save</button></div>',
            '    </div>',
            '  </div>',
            '  <div class="tb-cpuset-backdrop">',
            '    <div class="tb-cpuset">',
            '      <div class="tb-cpuset-header"><span>CPU Usage Settings</span><button type="button" class="tb-cpuset-close" aria-label="Close">\u00d7</button></div>',
            '      <div class="tb-cpuset-body">',
            '        <label>Sample every:</label> <select class="tb-cpuset-minute"></select>',
            '        <div class="tb-cpuset-hint">Changing this and clicking Save updates the DSM Task Scheduler entry to match.</div>',
            '      </div>',
            '      <div class="tb-cpuset-footer">',
            '        <span class="tb-cpuset-savestatus">',
            '          <img class="tb-spinner tb-cpuset-spinner" src="/webman/3rdparty/Syno_Toolbox/images/wait_triangle_blue_40p.gif" alt="" width="16" height="16">',
            '          <span class="tb-cpuset-status"></span>',
            '        </span>',
            '        <button type="button" class="tb-cpuset-save">Save</button>',
            '      </div>',
            '    </div>',
            '  </div>',
            '  <div class="tb-backupset-backdrop">',
            '    <div class="tb-backupset">',
            '      <div class="tb-backupset-header"><span>Backup Transfer Settings</span><button type="button" class="tb-backupset-close" aria-label="Close">\u00d7</button></div>',
            '      <div class="tb-backupset-body">',
            '        <label>Shared secret:</label> <input type="password" class="tb-backupset-secret" autocomplete="off" data-lpignore="true" data-1p-ignore data-bwignore="true" placeholder="Leave blank to keep the current secret" style="width:220px;">',
            '        <div class="tb-backupset-hint">Authenticates backup transfers between NAS running Syno Toolbox - set the same secret on every NAS involved. It is never shown here once saved; leave this blank and click Save to keep the secret already stored on this NAS unchanged.</div>',
            '      </div>',
            '      <div class="tb-backupset-footer">',
            '        <span class="tb-backupset-savestatus">',
            '          <img class="tb-spinner tb-backupset-spinner" src="/webman/3rdparty/Syno_Toolbox/images/wait_triangle_blue_40p.gif" alt="" width="16" height="16">',
            '          <span class="tb-backupset-status"></span>',
            '        </span>',
            '        <button type="button" class="tb-backupset-save">Save</button>',
            '      </div>',
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
        this.packagesPanel = el.querySelector('.tb-panel[data-panel="packages"]');
        this.cpuUsagePanel = el.querySelector('.tb-panel[data-panel="cpu_usage"]');
        this.helpPanel = el.querySelector('.tb-panel[data-panel="help"]');
        this.aboutPanel = el.querySelector('.tb-panel[data-panel="about"]');
        this.statusEl = el.querySelector(".tb-status");
        this.spinnerEl = el.querySelector(".tb-spinner");
        this.saveBtn = el.querySelector(".tb-save");

        Ext.fly(el.querySelector(".tb-refresh")).on("click", (function() { this.loadState(false); }).createDelegate(this));
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

        this.wolsetBackdrop = el.querySelector(".tb-wolset-backdrop");
        this.wolsetBody = el.querySelector(".tb-wolset-body");
        Ext.fly(el.querySelector(".tb-wolset-close")).on("click", this.closeWolSettings, this);
        Ext.fly(el.querySelector(".tb-wolset-save")).on("click", this.saveWolSettings, this);
        Ext.fly(this.wolsetBackdrop).on("click", (function(ev) {
            if (ev.getTarget() === this.wolsetBackdrop) { this.closeWolSettings(); }
        }).createDelegate(this));

        this.cpuFrameWrap = el.querySelector(".tb-cpu-frame-wrap");
        this.cpuEnabledCheckbox = el.querySelector('.tb-row[data-module-id="cpu_usage"] .tb-enabled');
        Ext.fly(this.cpuEnabledCheckbox).on("change", (function() {
            this.setDirty(true);
            this.refreshCPUUsageDisplay();
        }).createDelegate(this));
        this.cpusetBackdrop = el.querySelector(".tb-cpuset-backdrop");
        this.cpusetStatusEl = el.querySelector(".tb-cpuset-status");
        this.cpusetSpinnerEl = el.querySelector(".tb-cpuset-spinner");
        this.cpusetMinuteSelect = el.querySelector(".tb-cpuset-minute");
        // DSM's own Task Scheduler UI only offers these 7 values for a
        // minute-repeat schedule (confirmed on both DSM6 and DSM7) -
        // matching that exactly rather than an arbitrary 1-60 range,
        // since task_setup.sh's --interval-type=minute rejects anything
        // outside this set too.
        [1, 5, 10, 15, 20, 25, 30].forEach((function(m) {
            var opt = document.createElement("option");
            opt.value = m;
            opt.textContent = m + (m === 1 ? " minute" : " minutes");
            this.cpusetMinuteSelect.appendChild(opt);
        }).bind(this));
        Ext.fly(el.querySelector(".tb-cpu-settings")).on("click", this.openCPUUsageSettings, this);
        Ext.fly(el.querySelector(".tb-cpuset-close")).on("click", this.closeCPUUsageSettings, this);
        Ext.fly(el.querySelector(".tb-cpuset-save")).on("click", this.saveCPUUsageSettings, this);
        Ext.fly(this.cpusetBackdrop).on("click", (function(ev) {
            if (ev.getTarget() === this.cpusetBackdrop) { this.closeCPUUsageSettings(); }
        }).createDelegate(this));

        this.backupsetBackdrop = el.querySelector(".tb-backupset-backdrop");
        this.backupsetStatusEl = el.querySelector(".tb-backupset-status");
        this.backupsetSpinnerEl = el.querySelector(".tb-backupset-spinner");
        this.backupsetSecretInput = el.querySelector(".tb-backupset-secret");
        Ext.fly(el.querySelector(".tb-backupset-close")).on("click", this.closeBackupSettings, this);
        Ext.fly(el.querySelector(".tb-backupset-save")).on("click", this.saveBackupSettings, this);
        Ext.fly(this.backupsetBackdrop).on("click", (function(ev) {
            if (ev.getTarget() === this.backupsetBackdrop) { this.closeBackupSettings(); }
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

        this.loadState(true);
    },

    switchTab: function(category) {
        var el = this.body.dom;
        Ext.each(el.querySelectorAll(".tb-tab"), function(tabBtn) {
            Ext.fly(tabBtn)[tabBtn.getAttribute("data-category") === category ? "addClass" : "removeClass"]("tb-tab-active");
        });
        Ext.each(el.querySelectorAll(".tb-panel"), function(panelEl) {
            Ext.fly(panelEl)[panelEl.getAttribute("data-panel") === category ? "addClass" : "removeClass"]("tb-panel-active");
        });
        if (category === "packages") { this.ensurePackagesLoaded(); }
        if (category === "cpu_usage") { this.refreshCPUUsageDisplay(); }
        if (category === "help") { this.ensureHelpLoaded(); }
        if (category === "about") { this.ensureAboutLoaded(); }

        // .tb-list's overflow:auto is needed for tabs like Info/Tools
        // that can have more rows than fit - but CPU Usage always
        // exactly fills its space by design (flexbox), so any
        // scrollbar there is a sub-pixel rounding artifact, never
        // legitimate overflow. Force it off specifically for this tab
        // instead of chasing an exact zero-overflow layout.
        this.listEl.style.overflow = (category === "cpu_usage") ? "hidden" : "";
    },

    // Packages shows the live pkg_updates.html written by pkg_updates.sh
    // (run when the window opens and again on every Refresh - see
    // loadState below; nothing runs it at package start anymore).
    // Unlike Help/About's static docs, this content goes stale, so first
    // visit just shows whatever was last generated; reloadPackagesPanel()
    // is what forces a fresh iframe load, called again once that run
    // completes.
    ensurePackagesLoaded: function() {
        if (this.packagesPanel.firstChild) { return; }
        this.reloadPackagesPanel();
    },

    // Shown immediately on Refresh, before the run's response comes
    // back - see loadState. Same spinner image as the toolbar's own
    // "Loading..." indicator (.tb-spinner), rather than a second,
    // differently-styled spinner just for this panel.
    showPackagesLoading: function() {
        this.packagesPanel.innerHTML =
            '<div style="display:flex;align-items:center;justify-content:center;height:100%;color:#888;font-size:13px;">' +
            '<img src="/webman/3rdparty/Syno_Toolbox/images/wait_triangle_blue_40p.gif" alt="" width="28" height="28" style="margin-right:10px;">' +
            'Loading&hellip;</div>';
    },

    // Loads api.cgi's pkgupdateshtml action directly as the iframe
    // document - that action sends a real text/html header (see
    // api.cgi), unlike every other action's JSON envelope, since an
    // iframe needs an actual HTML document, not JSON to parse.
    reloadPackagesPanel: function() {
        this.packagesPanel.innerHTML = '<iframe class="tb-iframe" src="' +
            SYNO.SDS.Syno_Toolbox.API_PATH + '?action=pkgupdateshtml&_ts=' + new Date().getTime() + '"></iframe>';
    },

    // Syncs the toggle + hidden interval field from getstate's fresh
    // module data - called after every renderList() (initial open,
    // Refresh, and post-save), mirroring what renderRow() would do for
    // a normal row's initial checked/value state.
    applyCPUUsageState: function() {
        var mod = this.findModule("cpu_usage");
        if (!mod || !this.cpuEnabledCheckbox) { return; }
        this.cpuEnabledCheckbox.checked = mod.current_enabled === "yes";
        var intervalEl = this.body.dom.querySelector(".tb-cpu-interval");
        if (intervalEl) {
            intervalEl.value = (mod.current_fields && mod.current_fields.minute) ||
                (mod.schedule && mod.schedule.default_repeat_minute) || 5;
        }
        this.refreshCPUUsageDisplay();
    },

    // CPU Usage shows the static cpu_chart.html written by
    // generate_cpu_chart.sh, which cpu_usage.sh's own Task Scheduler
    // task keeps up to date on its own - unlike Packages, nothing here
    // ever needs a privileged "run" call from the UI, since the file's
    // freshness doesn't depend on this window being open. Because of
    // that, cpu_usage is special-cased out of wireRows'/refreshAfterSave's
    // generic live-module run-on-toggle logic (see those functions) -
    // toggling this checkbox should only show/hide the frame locally,
    // never trigger a sample.
    //
    // Reads the checkbox's own current DOM state rather than a cached
    // JS variable, so it's always correct regardless of whether it was
    // just toggled, just loaded from getstate, or just saved.
    refreshCPUUsageDisplay: function() {
        if (!this.cpuFrameWrap || !this.cpuEnabledCheckbox) { return; }
        if (this.cpuEnabledCheckbox.checked) {
            this.cpuFrameWrap.innerHTML = '<iframe class="tb-iframe" src="' +
                SYNO.SDS.Syno_Toolbox.API_PATH + '?action=cpuusagehtml&_ts=' + new Date().getTime() + '"></iframe>';
        } else {
            this.cpuFrameWrap.innerHTML =
                '<div class="tb-cpu-disabled-msg">CPU usage logging is turned off. Enable it and click Save to start logging CPU usage.</div>';
        }
    },

    // ---------------------------------------------------------------
    // CPU Usage Settings modal - same persistence pattern as the WOL
    // Settings modal (saveWolSettings): write the chosen value into a
    // hidden field on the row, then go through the normal full-form
    // save() rather than a partial one. Persists to toolbox.conf via
    // cpu_usage_minute, which synotoolbox_api.sh's save action reads
    // (via the generic sync_scheduled_task) to create/update the real
    // DSM Task Scheduler entry - confirmed working on both DSM6/7.
    // ---------------------------------------------------------------
    openCPUUsageSettings: function() {
        var intervalEl = this.body.dom.querySelector(".tb-cpu-interval");
        var current = (intervalEl && parseInt(intervalEl.value, 10)) || 5;
        this.cpusetMinuteSelect.value = current;
        if (this.cpusetStatusEl) { this.cpusetStatusEl.textContent = ""; }
        Ext.fly(this.cpusetBackdrop).addClass("open");
    },

    closeCPUUsageSettings: function() {
        Ext.fly(this.cpusetBackdrop).removeClass("open");
    },

    saveCPUUsageSettings: function() {
        var intervalEl = this.body.dom.querySelector(".tb-cpu-interval");
        if (!intervalEl) { this.closeCPUUsageSettings(); return; }
        intervalEl.value = this.cpusetMinuteSelect.value;

        var saveBtn = this.cpusetBackdrop.querySelector(".tb-cpuset-save");
        saveBtn.disabled = true;
        if (this.cpusetStatusEl) { this.cpusetStatusEl.textContent = "Saving\u2026"; }
        if (this.cpusetSpinnerEl) { Ext.fly(this.cpusetSpinnerEl).addClass("show"); }

        var formData = this.collectFormJson();
        SYNO.SDS.Syno_Toolbox.apiCall("save", { form_json: Ext.encode(formData) }, "POST", (function(saveResp) {
            saveBtn.disabled = false;
            if (this.cpusetSpinnerEl) { Ext.fly(this.cpusetSpinnerEl).removeClass("show"); }
            if (!saveResp || !saveResp.success) {
                if (this.cpusetStatusEl) { this.cpusetStatusEl.textContent = (saveResp && saveResp.message) || "Failed to save"; }
                return;
            }
            if (this.cpusetStatusEl) { this.cpusetStatusEl.textContent = ""; }
            this.setDirty(false);
            this.closeCPUUsageSettings();
        }).createDelegate(this));
    },

    // ---------------------------------------------------------------
    // Backup Transfer Settings modal - sets config_backup's shared
    // secret used to authenticate NAS-to-NAS backup transfers
    // (receive_backup in synotoolbox_api.sh). The field is deliberately
    // write-only: getstate never echoes the stored secret back to the
    // browser (see synotoolbox_api.sh's getstate case, which drops any
    // "*_secret" suffix), so this modal has nothing to prefill and
    // always opens blank. An empty Save leaves whatever secret is
    // already stored on this NAS untouched rather than clearing it -
    // see synotoolbox_api.sh's save case, which skips a "*_secret" key
    // when its submitted value is blank.
    // ---------------------------------------------------------------
    openBackupSettings: function() {
        if (this.backupsetSecretInput) { this.backupsetSecretInput.value = ""; }
        if (this.backupsetStatusEl) { this.backupsetStatusEl.textContent = ""; }
        Ext.fly(this.backupsetBackdrop).addClass("open");
    },

    closeBackupSettings: function() {
        Ext.fly(this.backupsetBackdrop).removeClass("open");
    },

    saveBackupSettings: function() {
        var secretVal = this.backupsetSecretInput ? this.backupsetSecretInput.value : "";

        var saveBtn = this.backupsetBackdrop.querySelector(".tb-backupset-save");
        saveBtn.disabled = true;
        if (this.backupsetStatusEl) { this.backupsetStatusEl.textContent = "Saving\u2026"; }
        if (this.backupsetSpinnerEl) { Ext.fly(this.backupsetSpinnerEl).addClass("show"); }

        var formData = this.collectFormJson();
        formData["config_backup_shared_secret"] = secretVal;
        SYNO.SDS.Syno_Toolbox.apiCall("save", { form_json: Ext.encode(formData) }, "POST", (function(saveResp) {
            saveBtn.disabled = false;
            if (this.backupsetSpinnerEl) { Ext.fly(this.backupsetSpinnerEl).removeClass("show"); }
            if (!saveResp || !saveResp.success) {
                if (this.backupsetStatusEl) { this.backupsetStatusEl.textContent = (saveResp && saveResp.message) || "Failed to save"; }
                return;
            }
            if (this.backupsetSecretInput) { this.backupsetSecretInput.value = ""; }
            if (this.backupsetStatusEl) { this.backupsetStatusEl.textContent = ""; }
            this.setDirty(false);
            this.closeBackupSettings();
        }).createDelegate(this));
    },

    // Help/About just embed the package's static HTML docs in an iframe.
    // Loaded lazily on first visit to the tab rather than at open, since
    // most sessions never click them.
    // Added cache busting " + Date.now()" so user see the latest version
    // after an package update.
    ensureHelpLoaded: function() {
        if (this.helpPanel.firstChild) { return; }
        this.helpPanel.innerHTML = '<iframe class="tb-iframe" src="' +
            SYNO.SDS.Syno_Toolbox.APP_PATH + 'help/syno_toolbox_tools_help.html?_=' + Date.now() + '"></iframe>';
    },

    ensureAboutLoaded: function() {
        if (this.aboutPanel.firstChild) { return; }
        this.aboutPanel.innerHTML = '<iframe class="tb-iframe" src="' +
            SYNO.SDS.Syno_Toolbox.APP_PATH + 'help/syno_toolbox_overview.html?_=' + Date.now() + '"></iframe>';
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
    loadState: function(isInitial) {
        this.setStatus("Loading\u2026", true);

        // discoverwol: only on package open, not on a manual Refresh -
        // the arp-scan behind this takes ~4.5s, so Refresh (meant to
        // feel instant) never triggers it. Fire-and-forget: we don't
        // wait on its response or let it hold up getstate's own render
        // below - the WOL dropdown just picks up fresher results next
        // time it's populated, once the backgrounded scan finishes.
        if (isInitial) {
            SYNO.SDS.Syno_Toolbox.apiCall("discoverwol", {}, function() {});
            this.startWolScanPolling();
        }

        // Regenerates pkg_updates.html for the Packages tab - runs both
        // when the window opens and on every explicit Refresh, since
        // nothing at package start generates it anymore (modules.json's
        // pkg_updates trigger is "on_save", not "boot"). On a manual
        // Refresh, show the loading placeholder right away if the tab's
        // already been visited, so a slow update check (curling 3
        // endpoints per package) doesn't just leave the old table
        // sitting there looking frozen until it's done. Skipped on
        // initial open - nothing's rendered yet for firstChild to be
        // stale.
        if (!isInitial && this.packagesPanel && this.packagesPanel.firstChild) {
            this.showPackagesLoading();
        }
        SYNO.SDS.Syno_Toolbox.apiCall("run", { module_id: "pkg_updates" }, (function() {
            if (this.packagesPanel && this.packagesPanel.firstChild) { this.reloadPackagesPanel(); }
        }).createDelegate(this));

        SYNO.SDS.Syno_Toolbox.apiCall("getstate", {}, (function(resp) {
            if (!resp || !resp.success) {
                this.setStatus((resp && resp.message) || "Failed to load state");
                this.infoPanel.innerHTML = '<div style="padding:20px;color:#c00;">Could not load modules.</div>';
                this.toolsPanel.innerHTML = "";
                return;
            }
            this.modules = resp.result || [];
            this.dsmBuild = parseInt(resp.dsm_build, 10) || 0;
            this.renderList();
            this.applyCPUUsageState();
            this.setStatus("");
            this.setDirty(false);
        }).createDelegate(this));
    },

    renderList: function() {
        var self = this;
        var infoMods = this.modules.filter(function(m) { return m.category === "info" && !m.hidden_row; });
        var toolsMods = this.modules.filter(function(m) { return m.category === "tools" && !m.hidden_row; });

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
        var resultHtml = (mod.control === "toggle-display" || mod.control === "toggle-run" || mod.control === "toggle-wol-selector" || hasCheckArgs || mod.live === true)
            ? '<div class="' + resultClass + '" data-result-for="' + mod.id + '"></div>'
            : "";
        // Pure info modules - live display with no real enable/disable
        // action behind them - have a toggle that doesn't gate anything,
        // so hide it (visibility, not display, to keep row alignment).
        // toggle-wol-selector is the same story for a different reason:
        // it's a one-shot "send now" action fired by its own button, not
        // a persistent enabled/disabled state, so the toggle is unused.
        var toggleHiddenClass = ((mod.live === true && hasCheckArgs) || mod.control === "toggle-wol-selector" || mod.control === "toggle-password-prompt") ? " tb-toggle-hidden" : "";

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
                    '<input type="text" class="tb-path" placeholder="/volume1/backup" value="' + Ext.util.Format.htmlEncode(f.path || "") + '" style="width:200px;">' +
                    ' <button type="button" class="tb-browse">Browse</button>';

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

            case "toggle-wol-selector":
                var hiddenMacs = (mod.current_fields && mod.current_fields.hidden_macs) || "[]";
                return '<select class="tb-wol-mac" style="min-width:240px;"><option value="">Loading devices\u2026</option></select>' +
                    ' <button type="button" class="tb-send-wol">Send WOL</button>' +
                    ' <button type="button" class="tb-wol-settings" title="Choose which devices to hide from the list">Settings</button>' +
                    ' <img class="tb-spinner tb-wol-spinner" src="/webman/3rdparty/Syno_Toolbox/images/wait_triangle_blue_40p.gif" alt="" width="16" height="16" style="margin-left:6px;">' +
                    ' <span class="tb-wol-status" style="color:#888;"></span>' +
                    '<input type="hidden" class="tb-wol-hidden-macs" value="' + Ext.util.Format.htmlEncode(hiddenMacs) + '">';

            case "toggle-password-prompt":
                return '<label>Enter your admin password:</label> ' +
                    '<input type="password" class="tb-admin-password" autocomplete="off" data-lpignore="true" data-1p-ignore data-bwignore="true" style="width:160px;">' +
                    ' <button type="button" class="tb-enable-ssh-root">Enable</button>' +
                    (mod.companion_id ? ' <button type="button" class="tb-disable-ssh-root" data-companion-id="' + mod.companion_id + '">Disable</button>' : '') +
                    ' <span class="tb-ssh-status" style="color:#888;"></span>';

            default:
                return "";
        }
    },

    // config_backup's real shape: a local target dir, plus up to 2 optional
    // remote backup destinations - each an NAS running Syno_Toolbox,
    // chosen from a discovery dropdown (populated by discovertoolboxnas)
    // rather than typed IP/port/dir/user fields. Transfer itself goes
    // through Syno_Toolbox's own receive_backup endpoint (HTTPS, shared
    // secret set via the Settings modal below), not SSH/scp - so there's
    // no remote/local user or remote dir to configure per NAS.
    renderConfigBackupControls: function(mod, f) {
        var remoteBlock = function(prefix, title) {
            var checked = f[prefix + "backup"] === "yes" ? "checked" : "";
            var savedIp = f[prefix + "ip"] || "";
            var savedPort = f[prefix + "toolbox_port"] || "";
            var savedLabel = f[prefix + "label"] || "";
            var placeholderOpt = savedIp
                ? '<option value="' + Ext.util.Format.htmlEncode(savedIp) + '" selected>' +
                    Ext.util.Format.htmlEncode((savedLabel || savedIp) + " (" + savedIp + ")") + '</option>'
                : '<option value="">Searching\u2026</option>';
            return [
                '<div class="tb-remote-block" data-prefix="' + prefix + '" style="width:100%;border-top:1px dashed #ddd;margin-top:8px;padding-top:6px;">',
                '  <label><input type="checkbox" class="tb-remote-backup"' + checked + '> ' + title + '</label>',
                '  <div class="tb-remote-fields" style="margin-top:4px;display:flex;flex-wrap:wrap;align-items:center;gap:6px;">',
                '    <select class="tb-remote-select" style="min-width:240px;">' + placeholderOpt + '</select>',
                '    <input type="hidden" class="tb-remote-ip" value="' + Ext.util.Format.htmlEncode(savedIp) + '">',
                '    <input type="hidden" class="tb-remote-port" value="' + Ext.util.Format.htmlEncode(savedPort) + '">',
                '    <input type="hidden" class="tb-remote-label" value="' + Ext.util.Format.htmlEncode(savedLabel) + '">',
                '  </div>',
                '</div>'
            ].join("");
        };

        return this.renderFrequencySelect(mod.schedule && mod.schedule.default_frequency, f.frequency) +
            ' <label>Target dir:</label> <input type="text" class="tb-target-dir" placeholder="/volume1/backup" value="' + Ext.util.Format.htmlEncode(f.target_dir || "") + '" style="width:200px;">' +
            ' <button type="button" class="tb-browse-target-dir">Browse</button>' +
            ' <button type="button" class="tb-backup-settings" title="Set the shared secret used to authenticate transfers to other NAS">Settings</button>' +
            remoteBlock("remote_", "Remote backup") +
            remoteBlock("remote2_", "2nd remote backup");
    },

    renderHourSelect: function(defaultHour, currentHour) {
        var selectedHour = parseInt(currentHour, 10) || defaultHour || 6;
        var opts = "";
        for (var h = 1; h <= 12; h++) {
            opts += '<option value="' + h + '"' + (h === selectedHour ? " selected" : "") + '>Every ' + h + ' hour' + (h > 1 ? "s" : "") + '</option>';
        }
        return '<label>Frequency:</label> <select class="tb-hour">' + opts + '</select>';
    },

    // Simple Weekly/Monthly choice for config_backup - DSM's own Task
    // Scheduler has no "every N weeks/months" concept (Daily/Weekly/
    // Monthly are the only repeat modes, each just picking day(s)/
    // ordinal, not a count), so this is an either/or rather than a
    // numeric interval like renderHourSelect. Both options run at a
    // fixed time (Monday 00:00, or the first occurrence of the month)
    // with no further configuration, per Dave's "keep it simple" spec
    // confirmed 2026-09-13 - see task_setup.sh's build_schedule.
    //
    // "Monthly" is only offered on build 64570+ - DSM 6, 7.0, and 7.1
    // (all below that build) have no monthly repeat mode in Task
    // Scheduler at all, confirmed 2026-09-13. If a previously-saved
    // value is "month" but this build doesn't support it, the browser
    // just falls back to the first rendered option ("week") since
    // nothing in the list matches - self-correcting on the next save.
    renderFrequencySelect: function(defaultFrequency, currentFrequency) {
        var selected = currentFrequency || defaultFrequency || "week";
        var opts = [
            { value: "week", label: "Weekly (Monday at 00:00)" },
            { value: "month", label: "Monthly (First Monday at 00:00)" }
        ];
        if ((this.dsmBuild || 0) < 64570) {
            opts = opts.filter(function(o) { return o.value !== "month"; });
        }
        var optsHtml = opts.map(function(o) {
            return '<option value="' + o.value + '"' + (o.value === selected ? " selected" : "") + '>' + o.label + '</option>';
        }).join("");
        return '<label>Frequency:</label> <select class="tb-frequency">' + optsHtml + '</select>';
    },

    // ---------------------------------------------------------------
    // Wire per-row events after render
    // ---------------------------------------------------------------
    wireRows: function() {
        var rows = this.listEl.querySelectorAll(".tb-row");
        Ext.each(rows, function(rowEl) {
            var moduleId = rowEl.getAttribute("data-module-id");
            if (moduleId === "cpu_usage") { return; } // wired once in onAfterRender + applyCPUUsageState - see refreshCPUUsageDisplay's comment for why it opts out of the generic live-module run-on-toggle logic below
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
                var backupSettingsBtn = rowEl.querySelector(".tb-backup-settings");
                if (backupSettingsBtn) {
                    Ext.fly(backupSettingsBtn).on("click", (function() { this.openBackupSettings(); }).createDelegate(this));
                }
            }

            if (mod && mod.control === "toggle-wol-selector") {
                var wolSelect = rowEl.querySelector(".tb-wol-mac");
                if (wolSelect) { this.populateWolDevices(wolSelect, mod); }
                this.wireSendWolRow(rowEl, moduleId);
                this.updateWolSpinner();
                this.applyWolScanMessage();

                var wolSettingsBtn = rowEl.querySelector(".tb-wol-settings");
                if (wolSettingsBtn) {
                    Ext.fly(wolSettingsBtn).on("click", (function() { this.openWolSettings(moduleId); }).createDelegate(this));
                }
            }

            if (mod && mod.control === "toggle-password-prompt") {
                this.wireEnableSshRootRow(rowEl, moduleId);
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
    // Discovery spinner: polls wolscanstatus (the status file
    // discoverwol's setsid'd wrapper maintains) until the scan is no
    // longer "running", then refreshes the dropdown and hides the
    // spinner - covers both a populated list and a script error, since
    // either way the scan has stopped being "in flight".
    // ---------------------------------------------------------------
    startWolScanPolling: function() {
        this.wolScanInFlight = true;
        this.wolScanResult = null;
        this.updateWolSpinner();

        var attempts = 0;
        var maxAttempts = 20; // ~30s at 1.5s/poll - generous safety cap over the ~5s scans seen so far
        var poll = (function() {
            attempts++;
            SYNO.SDS.Syno_Toolbox.apiCall("wolscanstatus", {}, (function(resp) {
                var status = resp && resp.success && resp.result && resp.result.status;
                if (status === "running" && attempts < maxAttempts) {
                    setTimeout(poll, 1500);
                    return;
                }
                this.wolScanInFlight = false;
                this.updateWolSpinner();

                // Stored rather than written to the DOM directly here -
                // a fast scan (like an immediate "arp-scan not found"
                // failure) can reach this point before the page's own
                // getstate()/renderList() has finished its first render,
                // in which case the row (and .tb-wol-status) doesn't
                // exist yet. A one-shot write would just be silently
                // lost with nothing to retry it. Storing the result and
                // having every row render reapply it (same pattern as
                // updateWolSpinner/wolScanInFlight) means it shows up
                // whenever the row actually exists, regardless of which
                // finished first.
                this.wolScanResult = { status: status, rc: resp && resp.result && resp.result.rc };
                this.applyWolScanMessage();

                var wolSelect = this.toolsPanel && this.toolsPanel.querySelector(".tb-wol-mac");
                var mod = this.modules.filter(function(m) { return m.control === "toggle-wol-selector"; })[0];
                if (wolSelect && mod) { this.populateWolDevices(wolSelect, mod); }
            }).createDelegate(this));
        }).createDelegate(this);
        setTimeout(poll, 1500);
    },

    applyWolScanMessage: function() {
        var statusEl = this.toolsPanel && this.toolsPanel.querySelector(".tb-wol-status");
        if (!statusEl || !this.wolScanResult) { return; }

        var status = this.wolScanResult.status;
        if (status === "error") {
            var rc = this.wolScanResult.rc;
            statusEl.textContent = "Device discovery failed" + (rc !== undefined ? " (exit code " + rc + ")" : "") + " - see toolbox.log";
        } else if (status === "running") {
            // hit maxAttempts while still running - not a script
            // failure, just longer than expected
            statusEl.textContent = "Device discovery is taking longer than expected";
        } else {
            statusEl.textContent = "";
        }
    },

    updateWolSpinner: function() {
        var spinnerEl = this.toolsPanel && this.toolsPanel.querySelector(".tb-wol-spinner");
        if (!spinnerEl) { return; }
        Ext.fly(spinnerEl)[this.wolScanInFlight ? "addClass" : "removeClass"]("show");
    },

    getWolHiddenMacs: function() {
        var el = this.toolsPanel && this.toolsPanel.querySelector(".tb-wol-hidden-macs");
        if (!el || !el.value) { return []; }
        try {
            var parsed = JSON.parse(el.value);
            return Array.isArray(parsed) ? parsed : [];
        } catch (e) {
            return [];
        }
    },

    // ---------------------------------------------------------------
    // Send WOL row: dropdown of previously-discovered devices (from
    // discover_ip_macs.sh's persistent store), populated via a
    // listwoldevices action - same shape as populateVolumes/listvolumes.
    // Devices in the hidden-macs list (set via the Settings modal) are
    // filtered out here; the Settings modal itself shows the full,
    // unfiltered list so devices can be un-hidden again.
    // ---------------------------------------------------------------
    populateWolDevices: function(selectEl, mod) {
        SYNO.SDS.Syno_Toolbox.apiCall("listwoldevices", {}, (function(resp) {
            if (!resp || !resp.success || !resp.result || !resp.result.length) {
                selectEl.innerHTML = '<option value="">No devices discovered yet</option>';
                return;
            }
            var hidden = this.getWolHiddenMacs();
            var visible = resp.result.filter(function(dev) { return hidden.indexOf(dev.mac) === -1; });
            if (!visible.length) {
                selectEl.innerHTML = '<option value="">All discovered devices are hidden</option>';
                return;
            }
            var current = (mod.current_fields && mod.current_fields.mac) || "";
            selectEl.innerHTML = visible.map(function(dev) {
                var label = dev.mac + (dev.host ? " - " + dev.host : "") + (dev.ip ? " (" + dev.ip + ")" : "");
                var sel = dev.mac === current ? " selected" : "";
                return '<option value="' + Ext.util.Format.htmlEncode(dev.mac) + '"' + sel + '>' +
                    Ext.util.Format.htmlEncode(label) + '</option>';
            }).join("");
        }).createDelegate(this));
    },

    // Send is a one-shot action, independent of the main Save button:
    // it (1) persists the selected mac to conf via the normal save()
    // call, the same generic write path config_backup's fields use, so
    // it's remembered as current_fields.mac next time this row renders,
    // then (2) calls run, which (per seq_io's {volumes}/{kb} precedent)
    // is expected to substitute {mac} in run_args from that just-saved
    // conf field. Note this reuses the *full* form (collectFormJson),
    // same as the main Save button - clicking Send also commits any
    // other unsaved edits currently sitting in the form.
    wireSendWolRow: function(rowEl, moduleId) {
        var btn = rowEl.querySelector(".tb-send-wol");
        var statusEl = rowEl.querySelector(".tb-wol-status");
        var resultEl = rowEl.querySelector('[data-result-for="' + moduleId + '"]');
        if (!btn) { return; }

        Ext.fly(btn).on("click", (function() {
            var selectEl = rowEl.querySelector(".tb-wol-mac");
            if (!selectEl || !selectEl.value) {
                if (statusEl) { statusEl.textContent = "Select a device first"; }
                return;
            }

            btn.disabled = true;
            if (statusEl) { statusEl.textContent = "Sending\u2026"; }
            if (resultEl) { resultEl.textContent = ""; }

            var formData = this.collectFormJson();
            SYNO.SDS.Syno_Toolbox.apiCall("save", { form_json: Ext.encode(formData) }, "POST", (function(saveResp) {
                if (!saveResp || !saveResp.success) {
                    btn.disabled = false;
                    if (statusEl) { statusEl.textContent = (saveResp && saveResp.message) || "Failed to save selection"; }
                    return;
                }
                this.setDirty(false);

                SYNO.SDS.Syno_Toolbox.apiCall("run", { module_id: moduleId }, (function(runResp) {
                    btn.disabled = false;
                    if (statusEl) { statusEl.textContent = ""; }
                    if (resultEl) {
                        resultEl.innerHTML = runResp && runResp.success
                            ? this.safeResultHtml(runResp.result || "(no output)")
                            : this.safeResultHtml("Error: " + ((runResp && runResp.message) || "unknown"));
                    }
                }).createDelegate(this));
            }).createDelegate(this));
        }).createDelegate(this));
    },

    // One-shot action, independent of Save and of collectFormJson() -
    // unlike send_wol's mac, the password must never enter toolbox.conf
    // or run_args' {field} substitution (both land it in a config file
    // and/or a privileged process's argv - see enable_ssh_root's note
    // in modules.json). Posted directly to `run` as its own field;
    // synotoolbox_api.sh's run case special-cases this module id to pipe
    // it via stdin instead of resolving it through run_module_script.
    wireEnableSshRootRow: function(rowEl, moduleId) {
        var btn = rowEl.querySelector(".tb-enable-ssh-root");
        var pwField = rowEl.querySelector(".tb-admin-password");
        var statusEl = rowEl.querySelector(".tb-ssh-status");
        var resultEl = rowEl.querySelector('[data-result-for="' + moduleId + '"]');
        if (!btn || !pwField) { return; }

        var disableBtn = rowEl.querySelector(".tb-disable-ssh-root");
        if (disableBtn) {
            Ext.fly(disableBtn).on("click", (function() {
                var companionId = disableBtn.getAttribute("data-companion-id");
                disableBtn.disabled = true;
                if (statusEl) { statusEl.textContent = "Disabling\u2026"; }
                if (resultEl) { resultEl.textContent = ""; }

                SYNO.SDS.Syno_Toolbox.apiCall("run", { module_id: companionId }, "POST", (function(resp) {
                    disableBtn.disabled = false;
                    if (statusEl) { statusEl.textContent = ""; }
                    if (resultEl) {
                        resultEl.innerHTML = resp && resp.success
                            ? this.safeResultHtml(resp.result || "(no output)")
                            : this.safeResultHtml("Error: " + ((resp && resp.message) || "unknown"));
                    }
                }).createDelegate(this));
            }).createDelegate(this));
        }


        Ext.fly(btn).on("click", (function() {
            var pw = pwField.value;
            if (statusEl) { statusEl.textContent = ""; }
            if (resultEl) { resultEl.textContent = ""; }
            if (!pw) {
                if (statusEl) { statusEl.textContent = "Enter the admin password first"; }
                return;
            }
            btn.disabled = true;
            if (statusEl) { statusEl.textContent = "Enabling\u2026"; }
            if (resultEl) { resultEl.textContent = ""; }

            SYNO.SDS.Syno_Toolbox.apiCall("run", { module_id: moduleId, admin_password: pw }, "POST", (function(resp) {
                btn.disabled = false;
                if (statusEl) { statusEl.textContent = ""; }
                pwField.value = "";
                if (resultEl) {
                    resultEl.innerHTML = resp && resp.success
                        ? this.safeResultHtml(resp.result || "(no output)")
                        : this.safeResultHtml("Error: " + ((resp && resp.message) || "unknown"));
                }
            }).createDelegate(this));
        }).createDelegate(this));
    },

    // ---------------------------------------------------------------
    // Settings modal: pick which discovered devices to hide from the
    // Send WOL dropdown. Shows the full, unfiltered listwoldevices
    // result (so a previously-hidden device can be found and
    // un-hidden again) with checkboxes pre-checked from the row's
    // current hidden-macs list.
    // ---------------------------------------------------------------
    openWolSettings: function(moduleId) {
        this.wolsetModuleId = moduleId;
        this.wolsetBody.innerHTML = '<div class="tb-wolset-msg">Loading\u2026</div>';
        Ext.fly(this.wolsetBackdrop).addClass("open");

        SYNO.SDS.Syno_Toolbox.apiCall("listwoldevices", {}, (function(resp) {
            if (!resp || !resp.success || !resp.result || !resp.result.length) {
                this.wolsetBody.innerHTML = '<div class="tb-wolset-msg">No devices discovered yet.</div>';
                return;
            }
            var hidden = this.getWolHiddenMacs();
            this.wolsetBody.innerHTML = resp.result.map(function(dev) {
                var label = dev.mac + (dev.host ? " - " + dev.host : "") + (dev.ip ? " (" + dev.ip + ")" : "");
                var checked = hidden.indexOf(dev.mac) !== -1 ? " checked" : "";
                return '<label class="tb-wolset-item"><input type="checkbox" class="tb-wolset-check" value="' +
                    Ext.util.Format.htmlEncode(dev.mac) + '"' + checked + '> ' +
                    Ext.util.Format.htmlEncode(label) + '</label>';
            }).join("");
        }).createDelegate(this));
    },

    closeWolSettings: function() {
        Ext.fly(this.wolsetBackdrop).removeClass("open");
    },

    // Same persistence pattern as Send WOL's own flow: write the
    // chosen value into the row's hidden field, then go through the
    // normal full-form save() rather than a partial one - a partial
    // save missing other modules' _enabled keys risks the enable-diff
    // loop reading them as "disabled". Refreshes the dropdown and
    // closes the modal once saved.
    saveWolSettings: function() {
        var moduleId = this.wolsetModuleId;
        var hiddenMacs = [];
        Ext.each(this.wolsetBody.querySelectorAll(".tb-wolset-check:checked"), function(cb) {
            hiddenMacs.push(cb.value);
        });

        var hiddenEl = this.toolsPanel && this.toolsPanel.querySelector(".tb-wol-hidden-macs");
        if (!hiddenEl) { this.closeWolSettings(); return; }
        hiddenEl.value = JSON.stringify(hiddenMacs);

        var saveBtn = this.wolsetBackdrop.querySelector(".tb-wolset-save");
        saveBtn.disabled = true;

        var formData = this.collectFormJson();
        SYNO.SDS.Syno_Toolbox.apiCall("save", { form_json: Ext.encode(formData) }, "POST", (function(saveResp) {
            saveBtn.disabled = false;
            if (!saveResp || !saveResp.success) {
                var statusEl = this.toolsPanel && this.toolsPanel.querySelector(".tb-wol-status");
                if (statusEl) { statusEl.textContent = (saveResp && saveResp.message) || "Failed to save hidden devices"; }
                return;
            }
            this.setDirty(false);
            this.closeWolSettings();

            var wolSelect = this.toolsPanel && this.toolsPanel.querySelector(".tb-wol-mac");
            var mod = this.modules.filter(function(m) { return m.id === moduleId; })[0];
            if (wolSelect && mod) { this.populateWolDevices(wolSelect, mod); }
        }).createDelegate(this));
    },

    // ---------------------------------------------------------------
    // config_backup row: both remote blocks' dropdowns are populated
    // once, together, from a single discovertoolboxnas call when the
    // row is wired (page open/refresh) - no per-block "Discover" click
    // needed anymore. A block's previously-saved selection is kept
    // even if that NAS doesn't answer this particular scan (offline,
    // different subnet) rather than silently dropped, so a real save
    // never loses a working destination just because discovery missed
    // it once.
    // ---------------------------------------------------------------
    wireConfigBackupRow: function(rowEl, mod) {
        var self = this;
        var blocks = rowEl.querySelectorAll(".tb-remote-block");

        SYNO.SDS.Syno_Toolbox.apiCall("discovertoolboxnas", {}, (function(resp) {
            var found = (resp && resp.success && resp.result) || [];

            Ext.each(blocks, function(block) {
                var select = block.querySelector(".tb-remote-select");
                var ipHidden = block.querySelector(".tb-remote-ip");
                var portHidden = block.querySelector(".tb-remote-port");
                var labelHidden = block.querySelector(".tb-remote-label");
                var savedIp = ipHidden.value;

                var optsHtml = '<option value="">None</option>';
                var matchedSaved = false;
                optsHtml += found.map(function(nas) {
                    var hostname = nas.toolbox_hostname || nas.hostname || nas.ip;
                    var selected = nas.ip === savedIp ? " selected" : "";
                    if (selected) { matchedSaved = true; }
                    return '<option value="' + Ext.util.Format.htmlEncode(nas.ip) + '"' +
                        ' data-port="' + Ext.util.Format.htmlEncode(String(nas.toolbox_port || 5001)) + '"' +
                        ' data-label="' + Ext.util.Format.htmlEncode(hostname) + '"' +
                        selected + '>' +
                        Ext.util.Format.htmlEncode(hostname + " (" + nas.ip + ")") + '</option>';
                }).join("");

                if (savedIp && !matchedSaved) {
                    optsHtml += '<option value="' + Ext.util.Format.htmlEncode(savedIp) + '"' +
                        ' data-port="' + Ext.util.Format.htmlEncode(portHidden.value || "5001") + '"' +
                        ' data-label="' + Ext.util.Format.htmlEncode(labelHidden.value || savedIp) + '"' +
                        ' selected>' +
                        Ext.util.Format.htmlEncode((labelHidden.value || savedIp) + " (" + savedIp + ") \u2013 not found this scan") + '</option>';
                }

                select.innerHTML = optsHtml;

                Ext.fly(select).on("change", (function() {
                    var opt = select.options[select.selectedIndex];
                    ipHidden.value = select.value;
                    portHidden.value = opt ? (opt.getAttribute("data-port") || "") : "";
                    labelHidden.value = opt ? (opt.getAttribute("data-label") || "") : "";
                    self.setDirty(true);
                }).createDelegate(self));
            });
        }).createDelegate(this));
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

            var frequencyEl = rowEl.querySelector(".tb-frequency");
            if (frequencyEl) { form[id + "_frequency"] = frequencyEl.value; }

            if (rowEl.getAttribute("data-module-id") === "config_backup" ||
                rowEl.querySelector(".tb-target-dir")) {
                var targetDirEl = rowEl.querySelector(".tb-target-dir");
                if (targetDirEl) { form[id + "_target_dir"] = targetDirEl.value; }

                Ext.each(rowEl.querySelectorAll(".tb-remote-block"), function(block) {
                    var prefix = block.getAttribute("data-prefix"); // "remote_" or "remote2_"
                    var backupCb = block.querySelector(".tb-remote-backup");
                    form[id + "_" + prefix + "backup"] = backupCb && backupCb.checked ? "yes" : "no";
                    form[id + "_" + prefix + "ip"] = block.querySelector(".tb-remote-ip").value;
                    form[id + "_" + prefix + "toolbox_port"] = block.querySelector(".tb-remote-port").value;
                    form[id + "_" + prefix + "label"] = block.querySelector(".tb-remote-label").value;
                    // This UI only ever builds toolbox-method destinations
                    // (no SSH/File Station fields exist here anymore) - has
                    // to be written explicitly on every save, otherwise a
                    // fresh install falls through to the script's "ssh"
                    // default with none of the fields SSH needs, and an
                    // older install keeps whatever stale method value it
                    // had from before this redesign.
                    form[id + "_" + prefix + "method"] = "toolbox";
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

            var wolMacEl = rowEl.querySelector(".tb-wol-mac");
            if (wolMacEl) { form[id + "_mac"] = wolMacEl.value; }

            var wolHiddenEl = rowEl.querySelector(".tb-wol-hidden-macs");
            if (wolHiddenEl) { form[id + "_hidden_macs"] = wolHiddenEl.value; }

            var cpuIntervalEl = rowEl.querySelector(".tb-cpu-interval");
            if (cpuIntervalEl) { form[id + "_minute"] = cpuIntervalEl.value; }
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
            this.dsmBuild = parseInt(resp.dsm_build, 10) || 0;

            var cpuMod = this.findModule("cpu_usage");
            var cpuNewlyEnabled = changedIds.indexOf("cpu_usage") !== -1 &&
                cpuMod && cpuMod.current_enabled === "yes";

            if (cpuNewlyEnabled) {
                // Seed one 0.0 point before the iframe reload inside
                // applyCPUUsageState, so the first load already shows
                // it instead of the "waiting for first sample"
                // fallback - see seedcpuusage in api.cgi and
                // cpu_usage.sh's "seed" arg.
                SYNO.SDS.Syno_Toolbox.apiCall("seedcpuusage", {}, (function() {
                    this.applyCPUUsageState();
                }).createDelegate(this));
            } else {
                this.applyCPUUsageState();
            }

            changedIds.forEach(function(id) {
                if (id === "cpu_usage") { return; } // handled by applyCPUUsageState above - no backend run needed, see refreshCPUUsageDisplay's comment
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
