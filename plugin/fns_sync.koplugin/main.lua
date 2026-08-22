--[[--
FNS Sync — sync KOreader highlights/notes to Obsidian via Fast Note Sync.

Current implementation:
  - M1: Plugin skeleton (WidgetContainer:extend, _meta autoloaded)
    Settings persistence (G_reader_settings["fns_sync"])
    Full settings menu tree + service connection / per-book overrides
  - M2: FNS HTTP client (getNote / overwriteNote / createNote)
  - M3: render markdown from annotations + sync current book
  - M4: marker-based precise insertion (HL@ block diff)
  - M5: AnnotationsModified + CloseDocument auto-sync (debounced),
    silent offline-skip via skip_run_when_online (TOCTOU fix)
  - M6: Offline queue (this file, see "Offline queue" section)
    - Persists pending books to G_reader_settings["fns_sync_queue"]
    - Drains on NetworkConnected (1s debounce) + 3 fallback paths
    - Serial chain processing (_queue_processing lock, distinct from
      M5's _sync_in_flight) to avoid concurrent sync on the same book
    - Failure handling: attempts++ → freeze at MAX_RETRY_ATTEMPTS(5);
      token-invalid (307/308) → freeze ALL + toast
    - Book file gone (renamed/deleted) → drop entry, don't burn attempts
  - M7: Bidirectional sync (cross-device pull via three-way merge)
    - bidirectional_sync_enabled gate (off by default; first-use privacy
      confirmation dialog)
    - Three-way merge: server_ts_set vs local_ts_set vs last_synced_ts_set
      (per-book, persisted in G_reader_settings["fns_sync_last_synced"])
    - Sync round = atomic unit (pull → merge → apply both → push → update
      last); see _doSyncCurrentBookBidirectional
    - Version mismatch handling: skip + warn, M8 will add text-search
      fallback (see memory project-m7-version-mismatch)
    - Format gate: only crengine formats support pull (EPUB/MOBI/AZW3/
      FB2/TXT/HTML); PDF/CBZ/DJVU skip pull phase (rolling=false)
    - Queue path (M6) bypasses bidirectional — always uses Legacy
      (user decision #4: 离线书不做拉取)

Stubbed:
  - onSyncAllHistory (M8+): walk history dir, batch sync per book

Not in scope:
  - Encryption of queue at rest (accepted risk, see config.lua PII note)
  - Text-search fallback for cross-device book version mismatch (M8)
  - Syncing note/color/drawer fields cross-device (M8)
  - Per-book reset sync state UI (reset_config is the current fallback)

@module fns_sync.main
--]]--

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("logger")

local Config = require("config")
local Api = require("api")
local Ai = require("ai")
local Excerpt = require("excerpt")
local LocalStore = require("localstore")
local Marker = require("marker")
local Threeway = require("threeway")
local Event = require("ui/event")

local FnsSync = WidgetContainer:extend{
    name = "fns_sync",
    -- M6: is_doc_only=true ensures the plugin is instantiated only in
    -- ReaderUI, not in FileManager. Without this, broadcastEvent (e.g.
    -- NetworkConnected) reaches both instances, and self._queue_processing
    -- becomes per-instance → mutual exclusion fails (HIGH-A fix).
    -- Trade-off: FileManager-only online events won't drain the queue;
    -- user must open a book. Acceptable given typical reading flow.
    is_doc_only = true,
    -- M8: AI assistant runtime state (per-session, NOT persisted).
    -- _ai_session is nil when no AI conversation is active; otherwise a
    -- table { original_text = "...", messages = { {role, content}, ... } }.
    -- Reset on: book close, ReaderUI teardown, user clicks "关闭".
    -- A fresh "问 AI" button click starts a new session.
    _ai_session = nil,
}

-- ===========================================================================
-- Lifecycle
-- ===========================================================================

function FnsSync:init()
    self.settings = G_reader_settings:readSetting("fns_sync", {})
    -- Backfill any missing defaults (preserves user values already set).
    -- M8 Task D fix (reviewer H-1): table-typed defaults are one-level
    -- shallow-copied so nested-key edits via _editString (e.g.
    -- "ai_quick_prompts.translate") don't mutate Config.DEFAULTS by
    -- reference. Sufficient for {string: string} maps like color_emoji_map
    -- and ai_quick_prompts. Deeper structures (e.g. book_overrides) are
    -- populated by their own helpers, not via _editString.
    for k, v in pairs(Config.DEFAULTS) do
        if self.settings[k] == nil then
            if type(v) == "table" then
                local copy = {}
                for tk, tv in pairs(v) do copy[tk] = tv end
                self.settings[k] = copy
            else
                self.settings[k] = v
            end
        end
    end

    -- Schema version migration. Each `if prev < N` block ports older
    -- settings forward; chained blocks handle skips (v1 → v3 runs v1→v2,
    -- v2→v3 in order). DEFAULTS backfill above only fills nil fields,
    -- so templates persisted by older plugin versions would otherwise
    -- linger forever — this is the only place they get refreshed.
    local prev_version = self.settings.config_version or 1
    if prev_version < Config.CURRENT_CONFIG_VERSION then
        -- v1 → v2 (M4): HIGHLIGHTS_START/END region markers replaced by
        -- {{HIGHLIGHTS}} placeholder + per-item HL@ blocks; excerpt
        -- timestamp changed from <!-- H:.. --> to *H: ..*. Old templates
        -- persisted in settings must be forcibly refreshed, otherwise
        -- renderFullNote falls back to appending HL@ blocks at the end
        -- (leaving an empty HIGHLIGHTS_START/END zone) and renderExcerpt
        -- keeps emitting the HTML-comment timestamp.
        if prev_version < 2 then
            self.settings.note_template = Config.DEFAULTS.note_template
            self.settings.excerpt_template = Config.DEFAULTS.excerpt_template
            logger.info("[FNS] migrated settings v1→v2: refreshed note_template and excerpt_template")
        end
        -- v2 → v3: excerpt template restructured — page number now on its
        -- own line, multi-line body quote prefix handled in renderExcerpt,
        -- redundant *H: {datetime}* removed (HL@ block markers already
        -- carry the datetime). Refresh excerpt_template so existing users
        -- pick up the new format on next sync.
        if prev_version < 3 then
            self.settings.excerpt_template = Config.DEFAULTS.excerpt_template
            logger.info("[FNS] migrated settings v2→v3: refreshed excerpt_template (new page/body layout)")
        end
        -- v3 → v4 (M7): sync_on_book_open (M5 placeholder, never wired in
        -- code) renamed to pull_on_book_open (M7 bidirectional pull trigger).
        -- If user manually set sync_on_book_open=true (rare), carry over;
        -- otherwise this is a no-op (DEFAULTS backfill already set
        -- pull_on_book_open=false above). bidirectional_sync_enabled and
        -- bidirectional_first_use_confirmed are net-new — no migration
        -- needed (backfill sets them to false).
        if prev_version < 4 then
            if self.settings.sync_on_book_open ~= nil then
                self.settings.pull_on_book_open = self.settings.sync_on_book_open
                self.settings.sync_on_book_open = nil
                logger.info("[FNS] migrated settings v3→v4: sync_on_book_open → pull_on_book_open")
            else
                logger.info("[FNS] migrated settings v3→v4: no rename needed (sync_on_book_open was nil)")
            end
        end

        -- v4 → v5 (M8): AI assistant fields added (ai_enabled, ai_api_base,
        -- ai_api_key, ai_model, ai_system_prompt, ai_max_tokens,
        -- ai_temperature, ai_timeout_sec, ai_quick_prompts). DEFAULTS
        -- backfill above already sets them to defaults; no explicit
        -- migration needed unless we want to refresh user-modified values.
        -- This block is intentionally a no-op log marker for traceability.
        if prev_version < 5 then
            logger.info("[FNS] migrated settings v4→v5: AI fields backfilled from DEFAULTS")
        end

        -- v5 → v6 (M8): reasoning models (deepseek-v4-flash) spend
        -- max_tokens on hidden reasoning before writing content; at the
        -- old default 1024 the budget could be exhausted by reasoning
        -- alone, leaving content="" with finish_reason="length" (Kindle
        -- log 2026-08-15 22:18-22:19, three consecutive failures). Raise
        -- a still-default 1024 to the new default; any other user-chosen
        -- value is kept as-is.
        if prev_version < 6 then
            -- tonumber: _editString may have stored the old default as
            -- string "1024" (see MEDIUM-1 in 2026-08-15 review).
            if tonumber(self.settings.ai_max_tokens) == 1024 then
                self.settings.ai_max_tokens = Config.DEFAULTS.ai_max_tokens
                logger.info("[FNS] migrated settings v5→v6: ai_max_tokens 1024 → "
                    .. tostring(Config.DEFAULTS.ai_max_tokens) .. " (reasoning model budget)")
            else
                logger.info("[FNS] migrated settings v5→v6: no change needed (ai_max_tokens="
                    .. tostring(self.settings.ai_max_tokens) .. ")")
            end
        end

        -- v6 → v7 (M8): multi-turn conversations (5-message context) push
        -- DeepSeek reasoning past 30s — Kindle log 2026-08-15 11:29-12:59
        -- shows three wantread at exactly 30s, then 3-17s successes after
        -- retry (thinking-time variance). Raise a still-default 30 to 60;
        -- any other user-chosen value is kept.
        if prev_version < 7 then
            if tonumber(self.settings.ai_timeout_sec) == 30 then
                self.settings.ai_timeout_sec = Config.DEFAULTS.ai_timeout_sec
                logger.info("[FNS] migrated settings v6→v7: ai_timeout_sec 30 → "
                    .. tostring(Config.DEFAULTS.ai_timeout_sec))
            else
                logger.info("[FNS] migrated settings v6→v7: no change needed (ai_timeout_sec="
                    .. tostring(self.settings.ai_timeout_sec) .. ")")
            end
        end

        self.settings.config_version = Config.CURRENT_CONFIG_VERSION
    end

    G_reader_settings:saveSetting("fns_sync", self.settings)

    -- M5 auto-sync runtime state (NOT persisted — runtime only).
    -- _auto_sync_action is a stable closure used as UIManager:scheduleIn /
    -- unschedule action key. A fresh closure each call would break unschedule
    -- (it matches by reference), leaking tasks after close-document.
    -- _sync_in_flight guards against concurrent syncs (manual button + auto
    -- trigger racing on the same book).
    self._auto_sync_action = function() self:_autoSyncCurrentBook() end
    self._sync_in_flight = false

    -- M6: Offline queue state.
    -- self.queue is the persistent table (keyed by book path) stored in
    -- G_reader_settings["fns_sync_queue"]. Each entry: { ts, attempts, title }.
    -- Contains PII (book paths + titles); see config.lua privacy note.
    self.queue = G_reader_settings:readSetting("fns_sync_queue", {}) or {}

    -- _queue_processing guards _processQueue against re-entry (HIGH-2 fix).
    -- Distinct from _sync_in_flight (M5 lock) so queue processing and
    -- realtime M5 sync don't deadlock each other (HIGH-B fix).
    self._queue_processing = false

    -- _last_network_event_ts for 100ms debounce of onNetworkConnected
    -- (M-7 fix: network jitter can fire the event multiple times rapidly).
    self._last_network_event_ts = 0

    -- M6 review (H-3): stable closure for queue drain. All scheduleIn /
    -- nextTick calls reference this single function so onCloseWidget can
    -- unschedule them. Without this, UIManager closures hold dead self
    -- references after ReaderUI teardown → operate on half-destroyed state.
    self._queue_drain_action = function() self:_processQueue() end

    -- M7: bidirectional sync runtime state.
    -- _pull_in_flight suppresses onAnnotationsModified during remote-pull
    -- batches (server-fetched highlights get addItem'd → AnnotationsModified
    -- fires → would retrigger M5 debounce → push → self-loop). Set true
    -- before addItem loop, false after the single cause="remote_pull"
    -- dispatch that follows it.
    -- _pull_action is a stable closure (UIManager:unschedule matches by
    -- reference, same pattern as _auto_sync_action / _queue_drain_action).
    -- Used by onOpenDocument's scheduleIn(2s) delayed pull trigger; must be
    -- assigned ONCE in init so onCloseWidget can unschedule it cleanly.
    self._pull_in_flight = false
    self._pull_action = function() self:_pullRemoteHighlights() end

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- M6 review fix (C failure): NetworkConnected may broadcast before
    -- our widget registers (race on restart), so don't rely on the event
    -- alone. Schedule a one-shot queue check 2s after init if online.
    -- 2s (longer than _PROCESS_QUEUE_DELAY=0.5) gives ReaderUI time to
    -- fully come up before we start firing HTTP.
    local queue_size = 0
    for _ in pairs(self.queue) do queue_size = queue_size + 1 end
    local online = NetworkMgr:isOnline()
    logger.info(string.format("[FNS] init: queue_size=%d online=%s offline_queue=%s",
        queue_size, tostring(online), tostring(self.settings.offline_queue_enabled)))
    if online then
        logger.info("[FNS] init: scheduleIn(2s) → _processQueue (startup drain)")
        UIManager:scheduleIn(2, self._queue_drain_action)
    else
        logger.info("[FNS] init: offline, waiting for onNetworkConnected")
    end

    -- M8: Register "Ask AI" button in highlight menu. Uses KOReader's
    -- official addToHighlightDialog hook (see qrclipboard.koplugin/main.lua
    -- for reference). Previous attempt (2026-08-12 rollback) tried to
    -- override onShowHighlightMenu event — that event is NOT broadcast by
    -- KOReader; the correct mechanism is registration via this method.
    -- The button shows up in BOTH entry paths (select-new-text AND
    -- long-press-existing-highlight → "…" → menu).
    if self.ui and self.ui.highlight and self.document then
        self.ui.highlight:addToHighlightDialog("12_fns_ask_ai", function(this)
            return {
                text = _("问 AI"),
                show_in_highlight_dialog_func = function()
                    -- Only show when AI is enabled AND api_key is set
                    return self.settings.ai_enabled == true
                       and self.settings.ai_api_key ~= nil
                       and self.settings.ai_api_key ~= ""
                end,
                callback = function()
                    -- M8 Task E-step1 决策 6 二次修订（方案 Y → 方案 Z）。
                    -- 一次修订（方案 Y）：去掉 saveHighlight，hl_ts 用 os.date fallback。
                    --   原因：误判 saveHighlight 是卡顿主因 + 担心抖动 bug。
                    --   副作用：AI@ 块 orphaned 追加到笔记末尾，**没有 HL@ 上下文**，
                    --   用户读笔记时困惑（"AI 在回答什么原文？"）。
                    -- 二次修订（方案 Z）：恢复 saveHighlight（异步），让 HL@ 必存。
                    --   - code-explorer 调研：saveHighlight 实际只做 addItem（纯内存），
                    --     不写盘，不是卡顿主因（真凶是 dismissablePopen）。
                    --   - 异步执行（scheduleIn(0,)）避免任何潜在阻塞。
                    --   - clear() 不删 annotation（KOreader 源码已确认）。
                    --   - M7 双重防护（_pull_in_flight + cause=remote_pull）确保不抖动。
                    -- 用户代价：问 AI 后高亮强制保留（即使不想要也要手动删）。
                    UIManager:scheduleIn(0, function()
                        -- 1. Capture selected_text eagerly（clear 后会丢）
                        local selected_text
                        if this.selected_text and this.selected_text.text then
                            selected_text = this.selected_text.text
                        elseif this.selected_text and this.selected_text.pos0 and this.selected_text.pos1 then
                            if this.ui.document and this.ui.document.getTextFromXPointers then
                                selected_text = this.ui.document:getTextFromXPointers(
                                    this.selected_text.pos0, this.selected_text.pos1)
                            end
                        end

                        if not selected_text or selected_text == "" then
                            UIManager:show(InfoMessage:new{ text = _("未获取到选区文本"), timeout = 2 })
                            return
                        end

                        -- 2. 解析 hl_ts（双入口）
                        local hl_ts
                        if this.selected_text.datetime then
                            -- 入口 B：长按已有高亮，datetime 已存在
                            hl_ts = this.selected_text.datetime
                        else
                            -- 入口 A：新选区，调 saveHighlight 持久化。
                            -- addItem (readerannotation.lua:507) 会填 item.datetime = os.date(...)。
                            -- saveHighlight 后 this.selected_text.datetime 仍为 nil（KOreader 不回填），
                            -- 但反查 annotations 找刚保存的 item 可拿到 datetime。
                            if this.saveHighlight then this:saveHighlight() end
                            if this.ui and this.ui.annotation
                               and this.selected_text.pos0 and this.selected_text.pos1 then
                                for _, item in ipairs(this.ui.annotation.annotations or {}) do
                                    if item.pos0 == this.selected_text.pos0
                                       and item.pos1 == this.selected_text.pos1 then
                                        hl_ts = item.datetime
                                        break
                                    end
                                end
                            end
                        end

                        -- 3. Fallback（反查失败时）
                        if not hl_ts then
                            hl_ts = os.date("%Y-%m-%d %H:%M:%S")
                            logger.warn("[FNS-AI] could not resolve hl_ts after saveHighlight, fallback: " .. hl_ts)
                        end

                        -- 4. 关闭 highlight menu（保留高亮）
                        if this.onClose then this:onClose(true) end

                        -- 5. 立即 clear 选区（不再延迟 0.1 秒；scheduleIn(0) 已让位给 InputDialog）
                        if this.clear then this:clear() end

                        logger.info("[FNS-AI] ask-ai button clicked (方案 Z), selected_text len=" .. tostring(#selected_text) .. " hl_ts=" .. tostring(hl_ts))

                        -- 6. 弹 InputDialog
                        self:_openAiInputDialog(selected_text, hl_ts)
                    end)
                end,
            }
        end)
        logger.info("[FNS] registered '问 AI' button in highlight menu")
    end

    -- M8 Task E H-2 fix: reload any pending AI@ blocks persisted from a
    -- prior session (e.g. crash between "加入笔记" and next sync).
    self:_loadPendingAi()
end

-- M8: Reset AI session state. Called on book close, ReaderUI teardown,
-- and when user dismisses the TextViewer with "关闭".
function FnsSync:_resetAiSession()
    self._ai_session = nil
end

-- M8: Open the InputDialog for the user to type their question.
-- If session is nil, starts a new session with the captured highlight as
-- the "original text". If session exists, continues the conversation
-- (messages already has prior Q&A pairs).
-- E-step1 review fix (方案 P): 传入的 hl_ts 显式非 nil 且与当前 session 不同
-- → 切换高亮 → 调 _resetAiSession 重置对话（每个高亮 = 新对话）。
-- "继续问"按钮（_openAiResponseViewer）不传 hl_ts → nil → 不触发重置。
function FnsSync:_openAiInputDialog(original_text, hl_ts)
    -- 方案 P：切换高亮检测（防御日志便于实测）
    if hl_ts ~= nil and self._ai_session and self._ai_session.hl_ts ~= hl_ts then
        logger.info(("[FNS-AI] hl_ts switch detected, resetting AI session: old=%s new=%s"):format(
            tostring(self._ai_session.hl_ts), tostring(hl_ts)))
        self:_resetAiSession()
    end

    -- Start new session if none
    if not self._ai_session then
        self._ai_session = {
            original_text = original_text or "",
            hl_ts = hl_ts,  -- M8 Task E: HL@ ts for AI@ block matching
            messages = {
                { role = "system", content = self.settings.ai_system_prompt },
                { role = "user", content = "【原文摘录】\n" .. (original_text or "") },
            },
        }
    end

    -- Build quick-prompt buttons row. Each button fills the input with
    -- the corresponding template (placeholder {text} → original_text).
    -- Only translate/explain/comment show as buttons (summarize is read
    -- by the TextViewer's "让 AI 总结" button, not here).
    local order = { "translate", "explain", "comment" }
    local labels = { translate = _("翻译"), explain = _("解释"), comment = _("评论") }
    local quick_buttons_row = {}
    for _, key in ipairs(order) do
        local template = self.settings.ai_quick_prompts and self.settings.ai_quick_prompts[key]
        if template then
            table.insert(quick_buttons_row, {
                text = labels[key] or key,
                callback = function()
                    local filled = (template or ""):gsub("{text}", self._ai_session.original_text or "")
                    if self._ai_input_dialog then
                        self._ai_input_dialog:setInputText(filled)
                    end
                end,
            })
        end
    end

    local buttons = {
        quick_buttons_row,
        {
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(self._ai_input_dialog)
                    self._ai_input_dialog = nil
                end,
            },
            {
                text = _("发送"),
                is_enter_default = true,
                callback = function()
                    local question = self._ai_input_dialog:getInputText() or ""
                    if question == "" then
                        UIManager:show(InfoMessage:new{ text = _("请输入问题"), timeout = 2 })
                        return
                    end
                    table.insert(self._ai_session.messages, { role = "user", content = question })
                    UIManager:close(self._ai_input_dialog)
                    self._ai_input_dialog = nil
                    self:_callAiAndShow(self._ai_session.messages)
                end,
            },
        },
    }

    -- Truncate original_text to 60 chars in the description so the input
    -- field is not pushed below the fold on Kindle's 6" screen.
    local orig = self._ai_session.original_text or ""
    local orig_preview = orig:sub(1, 60) .. (#orig > 60 and "…" or "")

    self._ai_input_dialog = InputDialog:new{
        title = _("问 AI"),
        input = "",
        input_hint = _("输入你的问题…"),
        description = _("【原文】") .. orig_preview,
        buttons = buttons,
        stop_events_propagation = true,
    }
    UIManager:show(self._ai_input_dialog)
    self._ai_input_dialog:onShowKeyboard()
end

-- M8: Call Ai:chat with UIManager:nextTick wrapper (same pattern as
-- _triggerSync), then show TextViewer on success or InfoMessage on
-- failure. Closure captures settings + session eagerly so it doesn't
-- depend on self.ui after nextTick (close-document race).
function FnsSync:_callAiAndShow(messages)
    -- E-step1 review fix (consistency HIGH-2): guard against session==nil.
    -- Edge case: InputDialog open while user switches book → onCloseDocument
    -- resets session → user taps "send" → closure would crash on session.messages.
    local session = self._ai_session
    if not session then
        logger.warn("[FNS-AI] _callAiAndShow: session is nil (closed mid-conversation?), aborting")
        UIManager:show(InfoMessage:new{ text = _("会话已关闭，请重新问 AI"), timeout = 3 })
        return
    end

    local loading = InfoMessage:new{ text = _("正在思考…"), timeout = 0 }
    UIManager:show(loading)
    -- code-reviewer HIGH-1: KOReader's input loop runs due nextTick tasks
    -- BEFORE repaint, so the loading InfoMessage would never be painted —
    -- with 30s+ reasoning calls the UI freezes with zero feedback. Paint
    -- synchronously before handing control to the blocking Ai:chat.
    UIManager:forceRePaint()

    -- Capture eagerly (STRONG INVARIANT: do not read self.ui inside
    -- nextTick closure — see _triggerSync comment in this file).
    local settings = self.settings
    -- session was already captured + nil-checked at function entry

    UIManager:nextTick(function()
        -- code-reviewer LOW-1: 如果 nextTick 触发前 session 被 reset
        -- （如用户关书触发 onCloseDocument），不要往 stale session 写。
        if self._ai_session ~= session then
            logger.warn("[FNS-AI] _callAiAndShow: session changed during nextTick, aborting")
            UIManager:close(loading)
            return
        end

        local ok, result_or_err = pcall(function()
            return Ai:chat(settings, messages)
        end)

        UIManager:close(loading)

        if not ok then
            logger.warn("[FNS-AI] Ai:chat pcall failed: " .. tostring(result_or_err))
            -- M8 Task D fix (reviewer C-1): pop the user message appended
            -- by the caller so the next attempt doesn't double-send.
            local last = session.messages[#session.messages]
            if last and last.role == "user" then table.remove(session.messages) end
            UIManager:show(InfoMessage:new{
                text = _("AI 调用内部错误，详见 crash.log（grep [FNS-AI]）"),
                timeout = 5,
            })
            return
        end

        local result = result_or_err
        if not result.ok then
            -- M8 Task D fix (reviewer C-1): same pop as pcall-fail path.
            local last = session.messages[#session.messages]
            if last and last.role == "user" then table.remove(session.messages) end
            UIManager:show(InfoMessage:new{
                text = result.message or _("AI 调用失败"),
                timeout = 5,
            })
            return
        end

        -- Append assistant reply to session
        table.insert(session.messages, { role = "assistant", content = result.content })

        self:_openAiResponseViewer()
    end)
end

-- M8: Open TextViewer showing conversation history and action buttons.
-- TextViewer is recreated each time (fresh dialog is simpler than reinit
-- across keyboard transitions).
function FnsSync:_openAiResponseViewer()
    local session = self._ai_session
    if not session then return end

    -- Render conversation as plain-text (no emoji — Kindle e-ink).
    local parts = {}
    -- M8 Task E 决策 5 (C-2): 顶部固定提示
    table.insert(parts, _("提示：加入笔记将写入最后一问一答，可先用【让 AI 总结】生成精炼内容。"))
    table.insert(parts, "")
    table.insert(parts, "【原文摘录】")
    table.insert(parts, session.original_text or "")
    table.insert(parts, "")
    -- messages[1] is system, messages[2] is user-original-text; skip both
    -- (original_text already shown above). Show from messages[3] onward.
    for i = 3, #session.messages do
        local m = session.messages[i]
        if m.role == "user" then
            table.insert(parts, "【问】")
            table.insert(parts, m.content)
        elseif m.role == "assistant" then
            table.insert(parts, "【答】")
            table.insert(parts, m.content)
        end
        table.insert(parts, "")
    end

    local buttons_table = {
        {
            {
                text = _("继续问"),
                callback = function()
                    UIManager:close(self._ai_response_viewer)
                    self._ai_response_viewer = nil
                    self:_openAiInputDialog(session.original_text)
                end,
            },
            {
                text = _("让 AI 总结"),
                callback = function()
                    UIManager:close(self._ai_response_viewer)
                    self._ai_response_viewer = nil
                    local summarize_prompt = (self.settings.ai_quick_prompts and self.settings.ai_quick_prompts.summarize) or "请总结以上对话"
                    table.insert(session.messages, { role = "user", content = summarize_prompt })
                    self:_callAiAndShow(session.messages)
                end,
            },
        },
        {
            {
                text = _("加入笔记"),
                callback = function()
                    -- M8 Task E 决策 7: debounce 3 秒（防同秒 ts 冲突 + 防误触）
                    local now = os.time()
                    local last = self._last_ai_note_at or 0
                    if now - last < 3 then
                        UIManager:show(InfoMessage:new{ text = _("请稍候再试"), timeout = 2 })
                        return
                    end
                    self._last_ai_note_at = now
                    self:_addAiContentToNote()
                end,
            },
        },
    }

    -- 2026-08-16: 自定义"关闭"按钮已删除——与 add_default_buttons 追加的
    -- 系统默认行（Find/⇱/⇲/Close）重复。默认 Close/点窗外/多指滑动均走
    -- TextViewer:onClose → close_callback（下方），行为与原按钮一致；
    -- "继续问"/"让 AI 总结"用 UIManager:close，不触发 close_callback，
    -- 会话正确保留。
    self._ai_response_viewer = TextViewer:new{
        title = _("AI 对话"),
        text = table.concat(parts, "\n"),
        text_type = "general",
        add_default_buttons = true,
        buttons_table = buttons_table,
        close_callback = function()
            self._ai_response_viewer = nil
            self:_resetAiSession()
        end,
    }
    UIManager:show(self._ai_response_viewer)
end

-- M8 Task E: 把最后一问一答作为 AI@ 块写入笔记。
-- 决策 3：取 session.messages 最后一条 assistant（2026-08-18 起连同
-- 对应问题一起写入；快捷提问只记标签，手输问题删除其中原文，不留占位）。
-- 决策 4：多次加产生多个 AI@ 块（每次新 ts）。
-- 决策 9：触发 _triggerSync，失败时沿用 M6 队列暂存。
function FnsSync:_addAiContentToNote()
    local session = self._ai_session
    if not session or not session.original_text or session.original_text == "" then
        UIManager:show(InfoMessage:new{ text = _("无 AI 内容可加入"), timeout = 2 })
        return
    end

    -- 取最后一条 assistant（同时记下位置，用于向上找对应的问题）
    local last_assistant
    local last_assistant_idx
    for i = #session.messages, 1, -1 do
        if session.messages[i].role == "assistant" then
            last_assistant = session.messages[i].content
            last_assistant_idx = i
            break
        end
    end
    if not last_assistant then
        UIManager:show(InfoMessage:new{ text = _("AI 还未回复，无内容可加入"), timeout = 2 })
        return
    end

    -- 找该回答对应的问题：从回答位置向上找最近的 user 消息。下限 3 ——
    -- messages[1] 是 system、messages[2] 是"【原文摘录】"引导消息，都不算
    -- 问题。找不到（正常流程不可达，防御）→ 只写回答。
    local last_question
    for i = last_assistant_idx - 1, 3, -1 do
        if session.messages[i].role == "user" then
            last_question = session.messages[i].content
            break
        end
    end

    -- 问题 + 回答一起写入（2026-08-18 用户决策 A+B：笔记里不出现原文，
    -- 也不出现占位标记）。快捷提问（翻译/解释/评论）精确匹配后只记标签；
    -- 其余问题把完整包含的原文整段删掉（原文已在紧邻的 HL@ 块里）。
    -- 模板填充比对复刻按钮填充的 gsub 写法（含同样的 % 边界行为），保证
    -- 比对结果与实际发出的问题一致；删除原文时按字节转义（中文多字节
    -- 逐字节转后仍表字面量），防原文含 % ( ) 等 Lua 模式特殊字符。
    local note_content
    if last_question then
        local q
        local quick_labels = { translate = _("翻译"), explain = _("解释"), comment = _("评论") }
        for key, label in pairs(quick_labels) do
            local template = self.settings.ai_quick_prompts and self.settings.ai_quick_prompts[key]
            if template then
                local filled = (template:gsub("{text}", session.original_text))
                if last_question == filled then
                    q = label
                    break
                end
            end
        end
        if not q then
            local escaped = (session.original_text:gsub("([^%w])", "%%%1"))
            q = (last_question:gsub(escaped, ""))
            q = q:gsub("^%s+", ""):gsub("%s+$", "")
        end
        if q ~= "" then
            note_content = "【问】\n" .. q .. "\n\n【答】\n" .. last_assistant
        else
            note_content = last_assistant
        end
    else
        note_content = last_assistant
    end

    -- A1 防重复（2026-08-15 用户决策）：加入后不再关闭对话框，误触两次
    -- 的概率升高；同一条 assistant 回答只允许加入一次，追问产生新回答
    -- 后才可再次加入。_resetAiSession 重建 session 时该字段自然清空。
    if session.last_added_assistant == last_assistant then
        UIManager:show(InfoMessage:new{ text = _("本条回答已加入过，追问后再加入新内容"), timeout = 3 })
        return
    end

    -- 构造 pending AI 块
    local book_path = self:_getCurrentBookPath()
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    self._pending_ai_blocks = self._pending_ai_blocks or {}
    table.insert(self._pending_ai_blocks, {
        ts = ts,
        hl_ts = session.hl_ts,
        content = note_content,
        model = self.settings.ai_model or "unknown",
        book_path = book_path,  -- H-5 fix: bind to current book for drain filtering
    })
    self:_savePendingAi()  -- H-2 fix: persist to survive crash/restart

    -- 2026-08-15 用户决策：加入后保持对话窗口打开，可继续追问
    -- （原实现关闭 TextViewer，用户必须重新长按高亮才能再问）。
    session.last_added_assistant = last_assistant

    UIManager:show(InfoMessage:new{
        text = _("已加入笔记，可继续追问"),
        timeout = 3,
    })
    logger.info(("[FNS-AI] queued AI@ block ts=%s hl_ts=%s chars=%d (Q+A merged) book=%s"):format(
        ts, tostring(session.hl_ts), #note_content, tostring(book_path)))

    -- H-3 fix: cancel any pending M5 debounce timer so we don't double-sync
    -- (saveHighlight from Task C callback triggers AnnotationsModified →
    -- M5 schedules a debounced sync; this cancel avoids a redundant POST).
    self:_cancelAutoSyncTimer()

    -- 触发同步（沿用 M5 路径；失败自动入 M6 队列。M9 本地模式：写本地
    -- 文件，失败不入队——pending AI 块保留在 G_reader_settings 下次重试）
    self:_triggerSync({ silent = false })
end

-- M8 Task E H-2 fix: persist pending AI@ blocks to G_reader_settings so
-- they survive crash/restart (mirrors M6 _saveQueue pattern). Without
-- this, a KOreader crash between "加入笔记" and next sync loses the data.
function FnsSync:_savePendingAi()
    G_reader_settings:saveSetting("fns_sync_pending_ai", self._pending_ai_blocks or {})
end

function FnsSync:_loadPendingAi()
    local pending = G_reader_settings:readSetting("fns_sync_pending_ai", {}) or {}
    if #pending > 0 then
        self._pending_ai_blocks = pending
        logger.info(("[FNS-AI] loaded %d pending AI@ blocks from storage"):format(#pending))
    end
end

--- M8 Task E: drain pending AI@ blocks matching book_path into segments.
-- E-step1 review fix (CRITICAL): thin wrapper over Marker.drainAiBlocks.
-- Previously drain cleared pending in-place BEFORE POST, so POST failure
-- (e.g. network wantwrite) lost AI@ blocks permanently. Now drain is read-only
-- on pending; caller commits via _commitDrainedAi only after POST success.
-- H-4 fix: preserves enqueue order (multiple AI@ for same HL@ stack correctly).
-- H-5 fix: filters by book_path; mismatched blocks stay in pending.
-- LOW-4 fix: fallback append marks the AI@ meta with orphaned="true".
-- @param segments table  parsed segments (NOT modified; new copy returned)
-- @param book_path string  current book file path
-- @return drained_list, new_segments
--   drained_list: pending block references that were merged (caller commits)
--   new_segments: copy of segments with AI@ blocks inserted
function FnsSync:_drainPendingAiBlocks(segments, book_path)
    local drained, new_segments = Marker.drainAiBlocks(self._pending_ai_blocks, segments, book_path)
    logger.info(("[FNS-AI] drained %d AI@ blocks (commit pending after POST success)"):format(#drained))
    return drained, new_segments
end

--- M8 Task E-step1 review fix: commit drained AI@ blocks (remove from pending).
-- Called by 3 sync paths (Legacy / first-create / Bidirectional) only AFTER
-- POST success. POST failure leaves pending untouched → blocks auto-retry
-- on next sync.
-- Uses (ts .. "|" .. hl_ts) as dedup key: ts uniqueness guaranteed by
-- _addAiContentToNote's 3-second debounce (decision 7). Object-identity keys
-- would be fragile if KOreader reloads G_reader_settings mid-flight.
-- @param drained list  drained block references returned by _drainPendingAiBlocks
function FnsSync:_commitDrainedAi(drained)
    if not drained or #drained == 0 then return end
    if not self._pending_ai_blocks or #self._pending_ai_blocks == 0 then return end

    -- code-reviewer MEDIUM: 同 (ts, hl_ts) 重复理论风险（debounce 3 秒 +
    -- 单一入口 _addAiContentToNote 实际挡住），但记录 key 命中次数以便
    -- 实测时观察是否真有碰撞。
    local drained_keys = {}
    for _, d in ipairs(drained) do
        local key = (d.ts or "") .. "|" .. (d.hl_ts or "")
        drained_keys[key] = (drained_keys[key] or 0) + 1
        if drained_keys[key] > 1 then
            logger.warn(("[FNS-AI] duplicate drained key detected (ts+hl_ts collision): %s count=%d"):format(
                key, drained_keys[key]))
        end
    end

    local remaining = {}
    for _, p in ipairs(self._pending_ai_blocks) do
        local key = (p.ts or "") .. "|" .. (p.hl_ts or "")
        if drained_keys[key] and drained_keys[key] > 0 then
            drained_keys[key] = drained_keys[key] - 1
        else
            table.insert(remaining, p)
        end
    end

    local removed = #self._pending_ai_blocks - #remaining
    self._pending_ai_blocks = #remaining > 0 and remaining or nil
    self:_savePendingAi()
    logger.info(("[FNS-AI] committed %d AI@ blocks (%d remaining across all books)"):format(
        removed, #remaining))
end

function FnsSync:saveSettings()
    G_reader_settings:saveSetting("fns_sync", self.settings)
end

-- M6: Persist the offline queue. Best-effort: KOreader's LuaSettings does
-- not return a status from saveSetting (it sets the in-memory table; flush
-- happens on shutdown). HIGH-E fix is partial — we trust KOreader's write
-- path; on corruption, the queue may be lost on restart. Mitigation: queue
-- entries are reconstructable from local metadata.lua (highlights persist
-- there), so worst case is "no auto-retry", not "data loss".
function FnsSync:_saveQueue()
    G_reader_settings:saveSetting("fns_sync_queue", self.queue)
end

-- M7: per-book last_synced ts-set persistence. Used by three-way merge as
-- the "base" reference — ts present here means "we've already seen this
-- highlight synchronized in a prior round, so its absence on local+server
-- now means delete, not first-insert".
--
-- Storage simplification vs progress v4 design: stored inside
-- G_reader_settings (key "fns_sync_last_synced") instead of a dedicated
-- fns_sync_state.lua file with atomic temp+fsync+rename. Trade-off:
-- KOreader's LuaSettings flush is good-enough for this size (per-book ts
-- set rarely exceeds ~100 entries); we lose hard-crash atomicity but gain
-- implementation simplicity. Revisit with independent file if measurement
-- shows corruption in the field.
--
-- Structure: { [book_path] = { [ts_string] = true, ... }, ... }
function FnsSync:_getLastSyncedSet(book_path)
    local all = G_reader_settings:readSetting("fns_sync_last_synced", {}) or {}
    return all[book_path] or {}
end

function FnsSync:_saveLastSyncedSet(book_path, ts_set)
    local all = G_reader_settings:readSetting("fns_sync_last_synced", {}) or {}
    all[book_path] = ts_set
    G_reader_settings:saveSetting("fns_sync_last_synced", all)
end

-- ===========================================================================
-- Generic UI helpers
-- ===========================================================================

--- Open an input dialog bound to settings[key].
-- Supports dotted nested keys (e.g. "ai_quick_prompts.translate") for M8
-- quick-prompt templates. Top-level keys still work as before.
function FnsSync:_editString(key, title, hint, allow_newline)
    local function getNested(tbl, path)
        local parts = {}
        for p in tostring(path):gmatch("[^.]+") do table.insert(parts, p) end
        local cur = tbl
        for _, p in ipairs(parts) do
            if type(cur) ~= "table" then return nil end
            cur = cur[p]
        end
        return cur
    end
    local function setNested(tbl, path, value)
        local parts = {}
        for p in tostring(path):gmatch("[^.]+") do table.insert(parts, p) end
        local cur = tbl
        for i = 1, #parts - 1 do
            if type(cur[parts[i]]) ~= "table" then cur[parts[i]] = {} end
            cur = cur[parts[i]]
        end
        cur[parts[#parts]] = value
    end

    local current_value = getNested(self.settings, key)
    local dialog = InputDialog:new{
        title = title,
        input = tostring(current_value or ""),
        input_hint = hint or "",
        allow_newline = allow_newline == true,
        save_callback = function(content)
            setNested(self.settings, key, content)
            self:saveSettings()
        end,
        reset_callback = function()
            local default = getNested(Config.DEFAULTS, key)
            return default ~= nil and tostring(default) or ""
        end,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Edit a per-book override field (title or author) for the currently open book.
-- Empty input clears the field's override; if no override fields remain, the
-- whole entry is removed (falls back to doc_props entirely).
function FnsSync:_editBookOverride(field, label)
    local path = self:_getCurrentBookPath()
    if not path then
        UIManager:show(InfoMessage:new{ text = _("无打开的书"), timeout = 2 })
        return
    end
    self.settings.book_overrides = self.settings.book_overrides or {}
    local o = self.settings.book_overrides[path] or {}
    -- Pre-fill with current override value, or fall back to effective meta
    local current = o[field]
    if current == nil or current == "" then
        current = self:_getBookMetadata()[field] or ""
    end

    local dialog = InputDialog:new{
        title = label,
        input = current,
        input_hint = _("留空清除自定义，回退到文件元数据"),
        save_callback = function(content)
            -- Trim trailing newlines (InputDialog sometimes appends them)
            content = content:gsub("\n+$", "")
            self.settings.book_overrides[path] = self.settings.book_overrides[path] or {}
            if content == "" then
                self.settings.book_overrides[path][field] = nil
                -- Drop the entry entirely if both fields are gone
                local remaining = self.settings.book_overrides[path]
                local empty = true
                for _ in pairs(remaining) do empty = false; break end
                if empty then
                    self.settings.book_overrides[path] = nil
                end
            else
                self.settings.book_overrides[path][field] = content
            end
            self:saveSettings()
        end,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Remove all per-book overrides for the currently open book.
function FnsSync:_clearBookOverride()
    local path = self:_getCurrentBookPath()
    if not path then return end
    if not self.settings.book_overrides or not self.settings.book_overrides[path] then
        UIManager:show(InfoMessage:new{ text = _("当前书没有自定义信息"), timeout = 2 })
        return
    end
    self.settings.book_overrides[path] = nil
    self:saveSettings()
    UIManager:show(InfoMessage:new{ text = _("已重置为文件元数据"), timeout = 2 })
end

--- Toggle a boolean setting and persist.
function FnsSync:_toggleBool(key)
    self.settings[key] = not self.settings[key]
    self:saveSettings()
end

--- M7: Toggle bidirectional sync with first-use privacy confirmation.
-- First-time enable pops a ConfirmBox with the privacy notice (per design
-- v4 + user decision #1, progress 2026-08-06). Subsequent toggles bypass
-- the dialog (bidirectional_first_use_confirmed gates).
-- Disabling is always silent (no "are you sure" — user intent is clear).
function FnsSync:_toggleBidirectionalSync()
    if self.settings.bidirectional_sync_enabled then
        -- Turning OFF: simple toggle (consistent with other settings)
        self:_toggleBool("bidirectional_sync_enabled")
        return
    end
    -- Turning ON
    if self.settings.bidirectional_first_use_confirmed then
        -- Already confirmed before: silent toggle
        self:_toggleBool("bidirectional_sync_enabled")
        return
    end
    -- First-time enable: show privacy confirmation dialog
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("即将开启双向同步。\n\n【隐私告知】\n开启后，每条高亮会额外记录精确的 DOM 坐标（XPointer）到 Obsidian 笔记。如果 Obsidian vault 被共享/公开/入侵，攻击者可借此了解你的阅读进度和书籍结构。\n\n【数据流变化】\nObsidian 端的内容会同步回 KOreader。如果你在 Obsidian 删除了某条高亮，本设备的高亮也会被删除（跨设备同步删除）。\n\n【首次启用】\n首次启用会拉取服务器端的所有历史高亮到本设备。\n\n确认开启？"),
        ok_text = _("开启"),
        cancel_text = _("取消"),
        ok_callback = function()
            self.settings.bidirectional_sync_enabled = true
            self.settings.bidirectional_first_use_confirmed = true
            self:saveSettings()
            logger.info("[FNS] bidirectional_sync_enabled=true (first-use confirmed)")
            UIManager:show(InfoMessage:new{
                text = _("双向同步已开启。\n\n下次同步时会自动拉取/推送差异。\n也可点\"立即拉取远端高亮\"手动触发。"),
                timeout = 5,
            })
        end,
    })
end

-- ===========================================================================
-- Action callbacks
-- ===========================================================================

function FnsSync:isConfigured()
    return self.settings.server_url ~= ""
        and self.settings.api_token ~= ""
        and self.settings.vault ~= ""
end

--- M9: local mode = FNS server NOT configured. Notes are then written to
--- local files under <home>/<local_notes_root>/ via LocalStore instead of
--- POSTed to the server (same legacy pipeline, store injection). Derived,
--- not a user setting: configure FNS and local mode turns itself off.
function FnsSync:_isLocalMode()
    return not self:isConfigured()
end

--- Run the test connection probe and show result via InfoMessage.
function FnsSync:onTestConnection()
    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("请先填写 FNS 服务 URL、API Token 和 Vault 名"),
        })
        return
    end
    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{
            text = _("正在测试连接…"),
            timeout = 1,
        })
        UIManager:nextTick(function()
            local result = Api:testConnection(self.settings)
            UIManager:show(InfoMessage:new{
                text = result.message,
                timeout = (result.success and 2) or 5,
            })
        end)
    end)
end

--- Reset every setting back to Config.DEFAULTS (with confirmation).
function FnsSync:onResetConfig()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("将所有 FNS 同步配置重置为默认值？此操作不可撤销。"),
        ok_text = _("重置"),
        cancel_text = _("取消"),
        ok_callback = function()
            self.settings = {}
            for k, v in pairs(Config.DEFAULTS) do
                self.settings[k] = v
            end
            self:saveSettings()
            UIManager:show(InfoMessage:new{
                text = _("配置已重置为默认值"),
            })
        end,
    })
end

--- Get the absolute file path of the currently open book, or nil if no book.
function FnsSync:_getCurrentBookPath()
    if not self.ui or not self.ui.document then return nil end
    return self.ui.document.file
end

--- Pull doc_props into a flat metadata table for rendering.
-- Per-book overrides (settings.book_overrides[path]) take precedence over
-- doc_props for title and author; language always comes from doc_props.
function FnsSync:_getBookMetadata()
    local props = (self.ui and self.ui.doc_props) or {}
    local meta = {
        title    = props.title or "",
        author   = props.authors or "",
        language = props.language or "",
    }
    local path = self:_getCurrentBookPath()
    if not path then return meta end
    local overrides = self.settings.book_overrides or {}
    local o = overrides[path]
    if not o then return meta end
    -- Override only with non-empty strings; empty means "cleared by user"
    -- but we already pruned empty fields in _editBookOverride, so they won't
    -- be present in `o`. Defensive check anyway.
    if o.title and o.title ~= "" then meta.title = o.title end
    if o.author and o.author ~= "" then meta.author = o.author end
    return meta
end

--- Sanitize a server-returned message before exposing to UI/logs.
-- M6 (HIGH-H + review S-1 hardening): some gateways echo Authorization
-- headers or token fragments in 4xx bodies. Match common credential
-- patterns case-insensitively (via character classes, since Lua patterns
-- lack flags) and replace with <redacted>. Covers Bearer / Authorization /
-- Token / api_key / password / secret markers; both ":" and "=" separators.
-- Limitations: URL-encoded / Base64-wrapped / JSON-escaped tokens may bypass.
-- Accepted — legitimate server errors don't encode credentials this way.
local function _sanitizeServerMessage(raw)
    if raw == nil then return "" end
    local s = tostring(raw)
    local patterns = {
        "[Bb][Ee][Aa][Rr][Ee][Rr]%s+[%w_%-%.]+",      -- Bearer xxx
        "[Aa]uthorization%s*[:=]%s*%S+",               -- Authorization: xxx
        "[Tt]oken%s*[:=]%s*[%w_%-%.]+",                -- Token: xxx
        "[Aa]pi[_-]?[Kk]ey%s*[:=]%s*[%w_%-%.]+",       -- api_key=xxx
        "[Pp]assword%s*[:=]%s*%S+",                    -- password=xxx
        "[Ss]ecret%s*[:=]%s*%S+",                      -- secret=xxx
    }
    for _, pat in ipairs(patterns) do
        s = s:gsub(pat, "<redacted>")
    end
    if #s > 200 then s = s:sub(1, 200) .. "…" end
    return s
end

--- Show a unified sync-error InfoMessage from an Api result table.
function FnsSync:_showSyncError(result)
    local raw_msg = result.message
    local safe_msg = _sanitizeServerMessage(raw_msg)
    local msg
    if result.local_error then
        -- M9: LocalStore failure (disk full / permissions / bad filename)
        msg = _("本地文件读写失败：") .. (safe_msg ~= "" and safe_msg or _("未知错误"))
        logger.warn("[FNS] local store error: " .. safe_msg)
    elseif result.network_error then
        msg = _("网络错误：") .. (safe_msg ~= "" and safe_msg or _("未知错误"))
        logger.warn("[FNS] sync error (network): " .. safe_msg)
    else
        msg = string.format(_("同步失败 [code=%s]：%s"),
            tostring(result.biz_code or "?"),
            safe_msg ~= "" and safe_msg or _("未知错误"))
        logger.warn("[FNS] sync error biz_code=" .. tostring(result.biz_code)
            .. " msg=" .. safe_msg)
    end
    UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
end

--- Sync current book: GET → marker-zone replace → POST (or create if absent).
-- Marker zone is fully rewritten on every sync (M3 strategy, see progress
-- doc 2026-08-02). User edits OUTSIDE the markers are preserved.
--- Shared sync entry for both manual button (silent=false) and auto-sync
-- (silent=true). Captures annotations/meta/path eagerly so the closure
-- doesn't depend on self.ui after return — matters for the close-document
-- path where ReaderUI may be torn down before nextTick fires.
-- STRONG INVARIANT: do NOT read self.ui inside the nextTick closure below.
-- All ui-derived state must be captured into locals above this point.
-- Guards: _sync_in_flight (concurrent sync skip), enabled, isConfigured,
-- annotations non-empty. All UI feedback gated by `silent`.
--
-- opts.skip_run_when_online: bypass NetworkMgr:runWhenOnline wrapper.
-- Auto-sync paths set this true because runWhenOnline has a TOCTOU window
-- between _autoSyncCurrentBook's isOnline check and the actual call — if
-- the network drops in between, runWhenOnline would pop a "turn on WiFi?"
-- prompt, which is catastrophic on the close-document path (prompt lands
-- on FileManager after reader teardown). Auto paths already gate on
-- isOnline explicitly, so the wrapper is redundant; manual button keeps
-- the wrapper because a user-initiated action reasonably prompts for WiFi.
function FnsSync:_triggerSync(opts)
    opts = opts or {}
    local silent = opts.silent == true
    if self._sync_in_flight then
        logger.info("[FNS] sync skipped: another in flight")
        return
    end
    if not self.settings.enabled then
        if not silent then
            UIManager:show(InfoMessage:new{ text = _("FNS 同步未启用") })
        end
        return
    end
    -- M9: 未配置 FNS → 本地模式（笔记写本地文件，无需服务器）。G1 拍板：
    -- 本地模式仍尊重 enabled 总开关（上面已检查），这里不再拦截。
    local local_mode = self:_isLocalMode()
    if local_mode then
        logger.info("[FNS] M9 local mode: sync will write local files")
    end
    local annotations = self.ui and self.ui.annotation
        and self.ui.annotation.annotations or {}
    -- Bidirectional path (M7): allow empty annotations — first-time pull
    -- after enabling the toggle legitimately has zero local highlights
    -- (entire round is server → local). Only short-circuit when push-only.
    -- M9: local mode has no remote to pull from → always push-only here,
    -- even if bidirectional_sync_enabled is a leftover true from FNS days.
    if #annotations == 0 and (local_mode or not self.settings.bidirectional_sync_enabled) then
        if not silent then
            UIManager:show(InfoMessage:new{ text = _("当前书没有高亮/笔记") })
        end
        return
    end

    local meta = self:_getBookMetadata()
    local path = Excerpt:resolvePath(self.settings, meta)
    logger.info(string.format("[FNS] sync start (%s): title=%s annotations=%d path=%s",
        silent and "auto" or "manual",
        tostring(meta.title), #annotations, path))

    self._sync_in_flight = true
    local run = function()
        if not silent then
            UIManager:show(InfoMessage:new{ text = _("正在同步…"), timeout = 1 })
        end
        UIManager:nextTick(function()
            local ok, err = pcall(function()
                self:_doSyncCurrentBook(annotations, meta, path, silent, local_mode)
            end)
            -- Finally block: reset BOTH locks regardless of pcall outcome.
            -- _sync_in_flight protects this entry; _pull_in_flight is set
            -- inside Bidirectional Step 9 and MUST be released even if
            -- getTextFromXPointers / addItem / overwriteNote throws —
            -- otherwise onAnnotationsModified permanently skips M5 debounce
            -- (silent-failure-hunter H-1, found in M7 Day 3 review).
            self._sync_in_flight = false
            self._pull_in_flight = false
            if not ok then
                logger.warn("[FNS] sync pcall failed: " .. tostring(err))
                -- silent=false (manual button) path: tell user something went
                -- wrong instead of leaving them with a vanishing spinner
                -- (silent-failure-hunter L-1).
                if not silent then
                    UIManager:show(InfoMessage:new{
                        text = _("同步内部错误，详见 crash.log（grep [FNS]）"),
                        timeout = 5,
                    })
                end
            end
        end)
    end
    -- M9 G2: 本地模式无需网络——直接执行，不包 runWhenOnline，飞行模式下
    -- 点"同步到本地笔记"不会弹"开 WiFi"提示。
    if opts.skip_run_when_online or local_mode then
        run()
    else
        NetworkMgr:runWhenOnline(run)
    end
end

-- Manual button. Force-clears the in-flight lock first: a previous
-- runWhenOnline that hung on an offline WiFi-prompt (and was cancelled by
-- the user) would otherwise leave the lock stuck, blocking all future syncs.
-- A manual press is an explicit user intent — let it through even at the
-- cost of a potential concurrent request (the API is idempotent on path).
function FnsSync:onSyncCurrentBook()
    logger.info("[FNS] event: onSyncCurrentBook (manual button)")
    self._sync_in_flight = false
    self:_triggerSync{ silent = false }
end

--- M9 (D3): open the current book's local note file in a TextViewer.
--- Works in BOTH modes: in FNS mode the local file only exists before the
--- first seed upload (then it becomes .uploaded.bak), so this mainly
--- serves local mode — but FNS users can still peek at a pre-upload file.
function FnsSync:onViewLocalNote()
    logger.info("[FNS] event: onViewLocalNote")
    if not (self.ui and self.ui.document) then
        UIManager:show(InfoMessage:new{ text = _("请先打开一本书"), timeout = 2 })
        return
    end
    local meta = self:_getBookMetadata()
    local path = Excerpt:resolvePath(self.settings, meta)
    local r = LocalStore:getNote(self.settings, path)
    if not r.ok then
        self:_showSyncError(r)
        return
    end
    if not r.exists then
        UIManager:show(InfoMessage:new{
            text = _("本地笔记还不存在，先点一次同步生成"),
            timeout = 3,
        })
        return
    end
    UIManager:show(TextViewer:new{
        title = _("本地笔记"),
        text = r.content,
        text_type = "general",
        add_default_buttons = true,
    })
end

--- Dispatcher (M7): route to Legacy (M5/M6 behavior) or Bidirectional
--- (M7 three-way merge with pull). bidirectional_sync_enabled defaults to
--- nil/false until Day 2b wires it into Config.DEFAULTS — until then the
--- dispatcher always routes to Legacy, so enabling the toggle in settings
--- by hand has no effect until Day 2b ships.
--- Queue path (M6 _processQueueItem) calls _doSyncCurrentBookLegacy DIRECTLY
--- (per user decision #4: 离线书不做拉取 — see progress 2026-08-06).
function FnsSync:_doSyncCurrentBook(annotations, meta, path, silent, local_mode)
    -- M9: local mode always takes the Legacy shape with LocalStore injected
    -- (bidirectional pull has no meaning without a remote).
    if local_mode then
        return self:_doSyncCurrentBookLegacy(annotations, meta, path, silent, LocalStore)
    end
    if self.settings.bidirectional_sync_enabled then
        return self:_doSyncCurrentBookBidirectional(annotations, meta, path, silent)
    end
    return self:_doSyncCurrentBookLegacy(annotations, meta, path, silent, Api)
end

function FnsSync:_doSyncCurrentBookLegacy(annotations, meta, path, silent, store)
    -- M9: storage backend injection. Api (default) = FNS server; LocalStore
    -- = local files. Signature/result compatible (see localstore.lua), so
    -- the pipeline below runs unmodified for both.
    store = store or Api
    -- Render current KOreader highlights into a { ts -> block_content } table.
    -- This is the source-of-truth for what should be in the note after sync.
    --
    -- Returns a result table (M6): { ok=true, ... } on success,
    -- { ok=false, reason="get_failed"|"overwrite_failed"|"create_failed"|"race"|"no_annotations",
    --   result=<api_result> } on API failure.
    -- M5 caller (_triggerSync via nextTick) ignores the return value, so this
    -- addition is backward-compatible. M6 caller (_processQueueItem) inspects
    -- the result to advance attempts / detect token failure / drop entry.

    -- M6 review fix (E failure defense): refuse to sync empty annotations.
    -- Without this guard, Marker.diff(segments, {}) would mark ALL existing
    -- HL@ blocks for deletion → wipe the user's Obsidian note. The M5 path
    -- is protected by _triggerSync's pre-check, but the M6 queue path
    -- bypasses _triggerSync, so we guard here too.
    if annotations == nil or #annotations == 0 then
        if not silent then
            UIManager:show(InfoMessage:new{ text = _("当前书没有高亮/笔记"), timeout = 2 })
        end
        return { ok = false, reason = "no_annotations" }
    end

    local highlights_by_ts = Excerpt:renderExcerptBlock(annotations, self.settings)

    local get_result = store:getNote(self.settings, path)
    if not get_result.ok then
        if not silent then self:_showSyncError(get_result) end
        return { ok = false, reason = "get_failed", result = get_result }
    end

    -- M9 D4 (seed upload): FNS first-create but a local-mode note exists →
    -- use it as the base content. Reuse the exists-branch diff pipeline
    -- below so local content is merged with current highlights, then POST
    -- via overwrite (FNS POST /api/note is modify-or-create). On POST
    -- success the local file is renamed .uploaded.bak (G3).
    local seed_uploaded = false
    if not get_result.exists and store == Api then
        local seed = LocalStore:getNote(self.settings, path)
        if seed.ok and seed.exists then
            logger.info("[FNS] M9 seed: local note found, seeding first FNS sync: " .. path)
            get_result = {
                ok = true, exists = true,
                content = seed.content,
                note = { ctime = seed.note and seed.note.ctime },
            }
            seed_uploaded = true
        end
    end

    if get_result.exists then
        -- Existing note: parse → diff → applyDiff → serialize → overwrite.
        -- User content (text outside HL@ blocks) is preserved verbatim.
        logger.info("[FNS] note exists, doing item-level diff")
        local segments = Marker.parse(get_result.content)
        local actions = Marker.diff(segments, highlights_by_ts)
        local new_segments = Marker.applyDiff(segments, actions)

        -- M8 Task E: drain pending AI@ blocks (decision 8).
        -- 时机：applyDiff 之后、serialize 之前 —— 这样本地新加的 HL@ 已被
        -- diff+applyDiff 插入到 segments，AI@ 能精确按 hl_ts 匹配。
        -- 找不到匹配 → 末尾追加（fallback, orphaned=true）。
        -- E-step1 review CRITICAL fix: drain is read-only on pending;
        -- _commitDrainedAi only after POST success (POST failure auto-retries
        -- on next sync).
        local drained, drained_segments = self:_drainPendingAiBlocks(new_segments, self:_getCurrentBookPath())
        new_segments = drained_segments

        -- M8 (2026-08-15 user decision B1): cascade-delete AI@ blocks whose
        -- host HL@ was deleted this round. Runs AFTER drain so a pending
        -- AI@ whose host was just deleted is removed too (not re-orphaned).
        -- B4: cascade is skipped wholesale when exceeding the safety max.
        local deleted_hl_ts = {}
        for _, a in ipairs(actions) do
            if a.op == "delete" then table.insert(deleted_hl_ts, a.ts) end
        end
        -- CRITICAL fix (2026-08-16 闪退): assigning to bare `_` here CLOBBERED
        -- the file-scope gettext upvalue `_` with a number — every later
        -- `_("...")` call crashed KOReader (Kindle log main.lua:1166/1307).
        -- Never assign to `_` without `local` in this file.
        local cascade_n_skipped
        local _n_cascaded_ai
        new_segments, _n_cascaded_ai, cascade_n_skipped = Marker.cascadeDeleteAi(new_segments, deleted_hl_ts)
        if cascade_n_skipped > 0 and not silent then
            UIManager:show(InfoMessage:new{
                text = string.format(_("AI 块级联删除数量异常（%d），已拦截，请检查笔记"), cascade_n_skipped),
                timeout = 5,
            })
        end

        local new_content = Marker.serialize(new_segments)

        -- Verbose-only diff trace (M6 review): useful when diagnosing
        -- "why didn't my highlight sync" — enable verbose logging in
        -- KOreader settings to see parsed ts / client ts / computed actions.
        local _seg_ts, _hl_ts, _act_summary = {}, {}, {}
        for _, s in ipairs(segments) do
            if s.type == "hl" then table.insert(_seg_ts, s.ts) end
        end
        for ts in pairs(highlights_by_ts) do table.insert(_hl_ts, ts) end
        for _, a in ipairs(actions) do
            table.insert(_act_summary, a.op .. ":" .. tostring(a.ts))
        end
        logger.dbg("[FNS] diff trace: server_hl=" .. #_seg_ts
            .. " client_hl=" .. #_hl_ts
            .. " actions=" .. #actions
            .. " server_ts=[" .. table.concat(_seg_ts, "|") .. "]"
            .. " client_ts=[" .. table.concat(_hl_ts, "|") .. "]"
            .. " actions_detail=[" .. table.concat(_act_summary, "|") .. "]")


        local original_ctime = get_result.note and get_result.note.ctime
        local post_result = store:overwriteNote(self.settings, path, new_content, original_ctime)
        if post_result.ok then
            -- M9 G3: seed uploaded → rename local file so FNS-Notes/ keeps
            -- no stale copy (never deletes user content).
            if seed_uploaded then
                LocalStore:markUploaded(self.settings, path)
            end
            -- E-step1 review fix: only commit drained AI@ blocks after POST success
            self:_commitDrainedAi(drained)
            local n_ins, n_upd, n_del = 0, 0, 0
            for _, a in ipairs(actions) do
                if a.op == "insert" then n_ins = n_ins + 1
                elseif a.op == "update" then n_upd = n_upd + 1
                elseif a.op == "delete" then n_del = n_del + 1 end
            end
            logger.info(string.format("[FNS] sync success at %s: +%d ~%d -%d",
                path, n_ins, n_upd, n_del))
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("同步成功（+%d 更新%d 删除%d）：\n%s"),
                        n_ins, n_upd, n_del, path),
                    timeout = 3,
                })
            end
            return { ok = true, n_ins = n_ins, n_upd = n_upd, n_del = n_del }
        else
            if not silent then self:_showSyncError(post_result) end
            return { ok = false, reason = "overwrite_failed", result = post_result }
        end
    else
        -- First time: render from template, createNote with createOnly=true.
        logger.info("[FNS] note does not exist, creating new")
        local new_content = Excerpt:renderFullNote(highlights_by_ts, self.settings, meta)

        -- M8 Task E H-1 fix: drain pending AI@ blocks even on first-create.
        -- Without this, AI@ blocks would sit in memory until next sync.
        -- E-step1 review CRITICAL fix: drain is read-only on pending;
        -- commit only after createNote success.
        local drained = {}
        if self._pending_ai_blocks and #self._pending_ai_blocks > 0 then
            local temp_segments = Marker.parse(new_content)
            local d, new_temp = self:_drainPendingAiBlocks(temp_segments, self:_getCurrentBookPath())
            if #d > 0 then
                drained = d
                new_content = Marker.serialize(new_temp)
            end
        end

        local create_result = store:createNote(self.settings, path, new_content)
        if create_result.ok then
            -- E-step1 review fix: commit drained AI@ blocks only after create success
            self:_commitDrainedAi(drained)
            if create_result.created then
                logger.info("[FNS] sync success: created note with " .. #annotations .. " annotations at " .. path)
                if not silent then
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("已创建笔记并同步 %d 条摘录：\n%s"), #annotations, path),
                        timeout = 3,
                    })
                end
                return { ok = true, created = true }
            elseif create_result.already_exists then
                logger.info("[FNS] createNote returned already_exists (race), path=" .. path)
                if not silent then
                    UIManager:show(InfoMessage:new{
                        text = _("笔记刚被其他客户端创建，请重试同步"),
                        timeout = 3,
                    })
                end
                return { ok = false, reason = "race", result = create_result }
            end
        else
            if not silent then self:_showSyncError(create_result) end
            return { ok = false, reason = "create_failed", result = create_result }
        end
    end
    -- Defensive fallback (should be unreachable).
    return { ok = false, reason = "unknown" }
end

--- Bidirectional sync (M7): three-way merge with pull.
-- One sync round = atomic unit (per design v4 H-A2 + M7 Day 3 architect H-1):
--   1. GET server note → parse → server_segments (each hl seg carries seg.meta)
--   2. local annotations → local_ts_set + current_meta_map (pos0/pos1/chapter)
--   3. load last_synced[book_path]
--   4. Threeway.computeActions → {insert_on_server, delete_on_server,
--      insert_on_local, delete_on_local}
--   5. apply server-side actions via Marker.applyDiff → new_server_content
--   6. extract text + validate (defer local mutation to step 8)
--   7. overwriteNote(new_server_content)
--   8. on server-write success: apply local actions
--      - addItem for each validated insert_on_local
--      - direct table.remove for delete_on_local (no dispatch)
--      (server-write failure discards items_to_add → retry is idempotent)
--   9. update last_synced = new_server_ts ∪ successfully_added_local_ts
--  10. dispatch AnnotationsModified ONCE with cause="remote_pull"
--  11. toast with stats
--
-- Version-mismatch policy (user decision 2026-08-07, see memory
-- project-m7-version-mismatch): when extracted text doesn't substring-match
-- server seg.content, skip addItem + warn log + don't count ts into
-- last_synced (auto-retry next round). Highlight colored on wrong text is
-- more confusing than missing one. M8 will add text-search fallback.
--
-- Format gate (progress 2026-08-06): only crengine formats (EPUB/MOBI/AZW3/
-- FB2/TXT/HTML) support pull. PDF/CBZ/DJVU skip the pull phase silently
-- (self.ui.rolling == false) but still push local-new to server.
function FnsSync:_doSyncCurrentBookBidirectional(annotations, meta, path, silent)
    annotations = annotations or {}

    -- M7 Day 3 review (security-reviewer H-1): XPointer format validation.
    -- Real XPointers from crengine look like "/body/DocFragment/.../p[3]/text()[2].123"
    -- (per readerlink.lua samples). Whitelist: leading "/" + alphanumeric +
    -- "/ . [ ] ( ) _ -" only. Rejects strings with quotes, angle brackets,
    -- spaces, etc. — defends against attacker-controlled META fields in
    -- Obsidian vault (could otherwise break marker parsing or feed garbage
    -- to crengine's getTextFromXPointers).
    local function isValidXPointer(xp)
        return type(xp) == "string"
            and #xp > 0 and #xp <= Config.MAX_XPOINTER_LEN
            and xp:find("^/[%w_%-%./%[%]()]+$") ~= nil
    end

    -- can_pull gates the entire local-insert phase. paging mode (PDF etc.)
    -- has no XPointer, getTextFromXPointers doesn't apply — skip pull only.
    local can_pull = self.ui and self.ui.rolling == true
    if not can_pull then
        logger.info("[FNS] bidirectional sync: paging mode (PDF?), pull phase will be skipped")
    end

    -- Step 1: render local highlights (push direction + meta source)
    local highlights_by_ts = Excerpt:renderExcerptBlock(annotations, self.settings)

    -- Step 2: build local_ts_set + current_meta_map from annotations
    local local_ts_set = {}
    local current_meta_map = {}
    for _, ann in ipairs(annotations) do
        if ann.datetime then
            local_ts_set[ann.datetime] = true
            if can_pull and ann.pos0 and ann.pos1 then
                current_meta_map[ann.datetime] = {
                    pos0 = ann.pos0,
                    pos1 = ann.pos1,
                    chapter = ann.chapter,
                }
            end
        end
    end

    -- Step 3: GET server note
    local get_result = Api:getNote(self.settings, path)
    if not get_result.ok then
        if not silent then self:_showSyncError(get_result) end
        return { ok = false, reason = "get_failed", result = get_result }
    end

    -- Step 4: first-time sync (note doesn't exist) → create + initialize last_synced
    if not get_result.exists then
        logger.info("[FNS] bidirectional first-sync: creating note with META fields")
        local new_content = Excerpt:renderFullNote(highlights_by_ts, self.settings, meta, current_meta_map)
        local create_result = Api:createNote(self.settings, path, new_content)
        if not create_result.ok then
            if not silent then self:_showSyncError(create_result) end
            return { ok = false, reason = "create_failed", result = create_result }
        end
        if create_result.created then
            -- All local highlights just got pushed → last_synced = local_ts_set.
            self:_saveLastSyncedSet(path, local_ts_set)
            logger.info(string.format("[FNS] bidirectional first-sync success: %d highlights at %s",
                #annotations, path))
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("首次双向同步完成（已创建笔记并推送 %d 条）：\n%s"),
                        #annotations, path),
                    timeout = 3,
                })
            end
            return { ok = true, created = true, n_pushed = #annotations }
        end
        if create_result.already_exists then
            logger.info("[FNS] bidirectional first-sync race: another client created note")
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = _("笔记刚被其他客户端创建，请重试同步"),
                    timeout = 3,
                })
            end
            return { ok = false, reason = "race", result = create_result }
        end
        return { ok = false, reason = "create_unknown", result = create_result }
    end

    -- Step 5: parse server content → server_segments + lookup maps.
    -- Security gate (M7 Day 3 security-reviewer H-2): reject notes larger
    -- than Config.MAX_NOTE_BYTES — attacker-controlled vault could otherwise
    -- send a multi-MB note that blocks KOreader UI for seconds during parse.
    if #get_result.content > Config.MAX_NOTE_BYTES then
        logger.warn(string.format("[FNS] server note too large (%d bytes > %d), refusing to sync",
            #get_result.content, Config.MAX_NOTE_BYTES))
        if not silent then
            UIManager:show(InfoMessage:new{
                text = string.format(_("服务器笔记过大（%d KB），跳过同步以免 UI 卡顿"),
                    math.floor(#get_result.content / 1024)),
                timeout = 5,
            })
        end
        return { ok = false, reason = "note_too_large" }
    end
    local server_segments = Marker.parse(get_result.content)
    local server_ts_set = {}
    local server_seg_by_ts = {}
    for _, seg in ipairs(server_segments) do
        if seg.type == "hl" then
            server_ts_set[seg.ts] = true
            server_seg_by_ts[seg.ts] = seg
        end
    end

    -- Step 6: anomaly defense (progress v4 I 项).
    -- server_ts_set empty + last_ts_set non-empty could mean:
    --   (a) user genuinely cleared all HL@ in Obsidian → intended (decision #2,
    --       Obsidian delete = cross-device delete local) → proceed
    --   (b) parse failed / HL@ format corrupted → refuse (would wipe local)
    -- Distinguish: does server_segments have any non-empty user text?
    local last_ts_set = self:_getLastSyncedSet(path)
    if not next(server_ts_set) and next(last_ts_set) then
        local has_user_content = false
        for _, seg in ipairs(server_segments) do
            if seg.type == "user" and seg.content and seg.content:match("%S") then
                has_user_content = true
                break
            end
        end
        if not has_user_content then
            logger.warn("[FNS] server note empty (user cleared all HL@) — proceeding with delete-all-local semantics")
        else
            logger.warn("[FNS] server note has content but no HL@ blocks parsed — refusing to sync")
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = _("服务器笔记格式异常（无法解析 HL@ 块），跳过同步以免误删本地高亮"),
                    timeout = 5,
                })
            end
            return { ok = false, reason = "parse_failed" }
        end
    end

    -- Step 7: three-way merge
    local actions = Threeway.computeActions(server_ts_set, local_ts_set, last_ts_set)
    logger.info(string.format("[FNS] threeway actions: +server=%d -server=%d +local=%d -local=%d",
        #actions.insert_on_server, #actions.delete_on_server,
        #actions.insert_on_local, #actions.delete_on_local))
    -- M7 DEBUG: detailed ts lists for diagnosing "why didn't X sync".
    -- Enable verbose logging in KOreader settings to see these. ts lists
    -- are sorted for stable diff; no XPointer or text content logged (privacy).
    if logger.dbg then
        local function sorted_keys(set)
            local arr = {}
            for k in pairs(set or {}) do table.insert(arr, k) end
            table.sort(arr)
            return "[" .. table.concat(arr, "|") .. "]"
        end
        local function sorted_list(arr)
            local copy = {}
            for _, v in ipairs(arr or {}) do table.insert(copy, v) end
            table.sort(copy)
            return "[" .. table.concat(copy, "|") .. "]"
        end
        logger.dbg("[FNS] threeway server_ts=" .. sorted_keys(server_ts_set))
        logger.dbg("[FNS] threeway local_ts=" .. sorted_keys(local_ts_set))
        logger.dbg("[FNS] threeway last_ts=" .. sorted_keys(last_ts_set))
        logger.dbg("[FNS] threeway insert_on_server=" .. sorted_list(actions.insert_on_server))
        logger.dbg("[FNS] threeway delete_on_server=" .. sorted_list(actions.delete_on_server))
        logger.dbg("[FNS] threeway insert_on_local=" .. sorted_list(actions.insert_on_local))
        logger.dbg("[FNS] threeway delete_on_local=" .. sorted_list(actions.delete_on_local))
        -- silent-failure-hunter M-3: surface "impossible / corrupt last" ts list
        -- (in last but not in server nor local). Non-empty suggests last_synced
        -- state corruption (e.g. partial settings flush after crash).
        local impossible = {}
        for ts in pairs(last_ts_set) do
            if not server_ts_set[ts] and not local_ts_set[ts] then
                table.insert(impossible, ts)
            end
        end
        if #impossible > 0 then
            table.sort(impossible)
            logger.dbg("[FNS] threeway impossible_ts (in last only)=" .. "[" .. table.concat(impossible, "|") .. "]")
        end
    end

    -- Step 8: apply server-side actions → new_server_content.
    -- Convert Threeway actions to Marker actions (op/ts/content/meta format),
    -- reuse Marker.applyDiff for ordering + seg construction.
    local marker_actions = {}
    for _, ts in ipairs(actions.insert_on_server) do
        table.insert(marker_actions, {
            op = "insert", ts = ts,
            content = highlights_by_ts[ts],
            meta = current_meta_map[ts],
        })
    end
    for _, ts in ipairs(actions.delete_on_server) do
        table.insert(marker_actions, { op = "delete", ts = ts })
    end
    local new_server_segments = Marker.applyDiff(server_segments, marker_actions)

    -- M8 Task E: drain pending AI@ blocks (decision 8, bidirectional path).
    -- 时机：applyDiff 之后、serialize 之前 —— 这样本地新加的 HL@ 已被
    -- diff+applyDiff 插入到 segments，AI@ 能精确按 hl_ts 匹配。
    -- 找不到匹配 → 末尾追加（fallback）。
    -- 与 _doSyncCurrentBookLegacy 的 drain 逻辑一致（共享 helper）。
    -- H-1/H-4/H-5 fix: see _drainPendingAiBlocks.
    -- E-step1 review CRITICAL fix: drain is read-only on pending; commit
    -- only after overwriteNote success (Step 10).
    local drained, drained_server_segments = self:_drainPendingAiBlocks(new_server_segments, self:_getCurrentBookPath())
    new_server_segments = drained_server_segments

    -- M8 (2026-08-15 user decision B2): bidirectional cascade-delete —
    -- hosts deleted on ANY device (delete_on_server includes both
    -- locally-deleted and other-device-deleted) take their AI@ blocks with
    -- them. Runs AFTER drain for the same reason as the Legacy path.
    -- B4: cascade is skipped wholesale when exceeding the safety max.
    -- CRITICAL fix (2026-08-16 闪退): see Legacy path — bare `_` assignment
    -- clobbered the gettext upvalue and crashed every later `_("...")` call.
    local cascade_n_skipped
    local _n_cascaded_ai
    new_server_segments, _n_cascaded_ai, cascade_n_skipped = Marker.cascadeDeleteAi(new_server_segments, actions.delete_on_server)
    if cascade_n_skipped > 0 and not silent then
        UIManager:show(InfoMessage:new{
            text = string.format(_("AI 块级联删除数量异常（%d），已拦截，请检查笔记"), cascade_n_skipped),
            timeout = 5,
        })
    end

    local new_server_content = Marker.serialize(new_server_segments)

    -- Step 9: extract text + validate (DEFER local mutation to Step 11).
    -- architect H-1 fix (M7 Day 3 review): split extract from apply so
    -- overwriteNote failure leaves local state untouched → retry is
    -- idempotent. addItem/table.remove are postponed to Step 11.
    local items_to_add = {}      -- list of { ts=..., item=... } (validated)
    local indices_to_remove = {} -- desc-sorted indices into annotations
    local n_skip_no_meta = 0
    local n_skip_text_empty = 0
    local n_skip_text_mismatch = 0
    -- n_skip_failed + n_inserted_local + n_deleted_local computed in Step 11
    -- (addItem can still fail even after validation passes).

    if can_pull then
        for _, ts in ipairs(actions.insert_on_local) do
            local seg = server_seg_by_ts[ts]
            local meta = seg and seg.meta
            -- M7 Day 3 review (security-reviewer H-1): XPointer format gate.
            -- Rejects server-provided META values that don't match real
            -- crengine XPointer shape (defends against attacker-controlled
            -- vault + accidental format corruption).
            if not meta or not isValidXPointer(meta.pos0) or not isValidXPointer(meta.pos1) then
                n_skip_no_meta = n_skip_no_meta + 1
                logger.warn(string.format(
                    "[FNS] pull insert skipped (no meta or invalid XPointer): ts=%s pos0_len=%d pos1_len=%d",
                    tostring(ts),
                    meta and #tostring(meta.pos0) or 0,
                    meta and #tostring(meta.pos1) or 0))
            else
                -- M7 Day 3 review (security-reviewer M-2): chapter length + content gate.
                -- Defends against metadata.lua injection via overly-long or newline-
                -- bearing chapter strings (which would corrupt KOreader sidecar).
                local chapter = meta.chapter
                if chapter ~= nil and (type(chapter) ~= "string"
                                        or #chapter > Config.MAX_CHAPTER_LEN
                                        or chapter:find("[\r\n]")) then
                    logger.warn("[FNS] pull insert: chapter field invalid (too long or has newline), clearing. ts=" .. tostring(ts))
                    chapter = nil
                end
                -- Truncate XPointer in logs (progress v4 L-C2 DEBUG hygiene).
                local pos0_str = tostring(meta.pos0)
                local pos1_str = tostring(meta.pos1)
                local extracted = self.ui.document:getTextFromXPointers(meta.pos0, meta.pos1)
                if extracted == nil or extracted == "" then
                    n_skip_text_empty = n_skip_text_empty + 1
                    logger.warn(string.format(
                        "[FNS] pull insert skipped (text extraction empty, XPointer invalid?): ts=%s pos0=%s(%d) pos1=%s(%d)",
                        tostring(ts), pos0_str:sub(1, 40), #pos0_str, pos1_str:sub(1, 40), #pos1_str))
                elseif not string.find(seg.content, extracted, 1, true) then
                    -- Substring check fails: extracted text not in server's markdown
                    -- content → book version differs between devices (XPointer landed
                    -- on different text). Skip + warn; don't count into last_synced
                    -- so next round retries. (M8 will add text-search fallback, see
                    -- memory project-m7-version-mismatch.)
                    -- Privacy: log extracted LENGTH only, not content (extracted is
                    -- user's actual highlighted text, may be sensitive). server
                    -- content is the markdown we wrote, less sensitive, head 40 OK.
                    n_skip_text_mismatch = n_skip_text_mismatch + 1
                    logger.warn(string.format(
                        "[FNS] pull insert skipped (text mismatch, version diff?): ts=%s extracted_len=%d server_content_head=%q",
                        tostring(ts),
                        #tostring(extracted),
                        tostring(seg.content):sub(1, 40)))
                else
                    -- Defer addItem to Step 11 (after server write succeeds).
                    -- Stash the item + its ts together for the apply phase.
                    table.insert(items_to_add, {
                        ts = ts,
                        item = {
                            page = meta.pos0,    -- rolling mode: XPointer start
                            pos0 = meta.pos0,
                            pos1 = meta.pos1,
                            text = extracted,
                            chapter = chapter,   -- validated/cleared above
                            drawer = "lighten",  -- default; M8 may sync this
                            datetime = ts,
                        },
                    })
                end
            end
        end
    else
        if #actions.insert_on_local > 0 then
            logger.info(string.format("[FNS] pull phase skipped (paging mode): %d server-new highlights not pulled",
                #actions.insert_on_local))
        end
    end

    -- delete_on_local: build indices_to_remove list. Actual table.remove
    -- deferred to Step 11 (same atomicity rationale as items_to_add).
    -- At apply time we'll use direct table.remove (NOT removeItemByIndex,
    -- which would dispatch AnnotationsModified without cause=remote_pull →
    -- M5 self-loop).
    if #actions.delete_on_local > 0 then
        local delete_ts_set = {}
        for _, ts in ipairs(actions.delete_on_local) do
            delete_ts_set[ts] = true
        end
        for i, ann in ipairs(self.ui.annotation.annotations) do
            if ann.datetime and delete_ts_set[ann.datetime] then
                table.insert(indices_to_remove, i)
            end
        end
        -- Sort descending so removal doesn't shift not-yet-processed indices
        -- (matters at apply time in Step 11).
        table.sort(indices_to_remove, function(a, b) return a > b end)
    end

    -- Step 10: overwriteNote.
    -- NOW commit server-side. If this fails, items_to_add + indices_to_remove
    -- are discarded and local state is unchanged → next round retries
    -- idempotently (architect H-1/H-2 fix, M7 Day 3 review).
    -- original_ctime: pass 0 (not nil) when missing — overwriteNote's nil
    -- semantics are unclear, 0 means "no ctime to preserve" universally
    -- (code-reviewer M-3, M7 Day 3 review).
    local original_ctime = (get_result.note and get_result.note.ctime) or 0
    local post_result = Api:overwriteNote(self.settings, path, new_server_content, original_ctime)
    if not post_result.ok then
        -- E-step1 review fix: POST failure must NOT commit drained AI@ blocks.
        -- Pending stays untouched → next sync auto-retries.
        if not silent then self:_showSyncError(post_result) end
        return { ok = false, reason = "overwrite_failed", result = post_result }
    end

    -- E-step1 review fix: POST success → commit drained AI@ blocks.
    self:_commitDrainedAi(drained)

    -- Step 11: apply local actions (deferred from Step 9). NOW mutate local.
    -- _pull_in_flight suppresses onAnnotationsModified during the addItem
    -- batch (each addItem → AnnotationsModified → M5 debounce would fire
    -- mid-pull without this guard). Released before Step 12 dispatch so
    -- the cause="remote_pull" event we send is the only one M5 sees.
    self._pull_in_flight = true
    local n_inserted_local = 0
    local n_deleted_local = 0
    local n_skip_failed = 0
    local successfully_added_local_ts = {}

    for _, entry in ipairs(items_to_add) do
        local ok, idx_or_err = pcall(function()
            return self.ui.annotation:addItem(entry.item)
        end)
        if ok and idx_or_err then
            n_inserted_local = n_inserted_local + 1
            successfully_added_local_ts[entry.ts] = true
        else
            n_skip_failed = n_skip_failed + 1
            logger.warn("[FNS] pull insert addItem failed: ts=" .. tostring(entry.ts)
                .. " err=" .. tostring(idx_or_err))
        end
    end

    -- delete_on_local: direct table.remove (NOT removeItemByIndex).
    for _, idx in ipairs(indices_to_remove) do
        table.remove(self.ui.annotation.annotations, idx)
        n_deleted_local = n_deleted_local + 1
    end
    self._pull_in_flight = false

    -- Step 12: update last_synced = new_server_ts ∪ successfully_added_local_ts.
    -- new_server_ts = (server_ts ∪ insert_on_server) - delete_on_server.
    --
    -- CRITICAL: skipped local inserts are NOT counted. If we counted them,
    -- next round's three-way merge would see "server has X, local missing,
    -- last has X" → classify as delete_on_local (user removed) and never
    -- retry insert_on_local. By excluding them, next round re-evaluates
    -- them as "server has X, local missing, last missing" → insert_on_local
    -- (retry). This implements the user-decision policy "跳过+警告，下次重试"
    -- (see memory project-m7-version-mismatch).
    local skipped_local_ts = {}
    for _, ts in ipairs(actions.insert_on_local) do
        if not successfully_added_local_ts[ts] then
            skipped_local_ts[ts] = true
        end
    end
    local new_last = {}
    for ts in pairs(server_ts_set) do
        if not skipped_local_ts[ts] then
            new_last[ts] = true
        end
    end
    for _, ts in ipairs(actions.insert_on_server) do new_last[ts] = true end
    for _, ts in ipairs(actions.delete_on_server) do new_last[ts] = nil end
    for ts in pairs(successfully_added_local_ts) do new_last[ts] = true end
    self:_saveLastSyncedSet(path, new_last)

    -- Step 13: dispatch AnnotationsModified ONCE with cause="remote_pull".
    -- Other listeners (footer / bookmark view) get the update; M5 debounce
    -- explicitly skips this cause (see onAnnotationsModified).
    if n_inserted_local > 0 or n_deleted_local > 0 then
        self.ui:handleEvent(Event:new("AnnotationsModified", {
            nb_highlights_added = n_inserted_local - n_deleted_local,
            cause = "remote_pull",
        }))
    end

    -- Step 14: log + toast
    local n_skip_total = n_skip_no_meta + n_skip_text_empty + n_skip_text_mismatch + n_skip_failed
    logger.info(string.format(
        "[FNS] bidirectional sync success at %s: +local=%d -local=%d +server=%d -server=%d skip=%d(no_meta=%d empty=%d mismatch=%d failed=%d)",
        path, n_inserted_local, n_deleted_local,
        #actions.insert_on_server, #actions.delete_on_server,
        n_skip_total, n_skip_no_meta, n_skip_text_empty, n_skip_text_mismatch, n_skip_failed))
    if not silent then
        local msg = string.format(_("双向同步完成：\n+本地 %d  -本地 %d\n+远端 %d  -远端 %d"),
            n_inserted_local, n_deleted_local,
            #actions.insert_on_server, #actions.delete_on_server)
        if n_skip_total > 0 then
            msg = msg .. string.format(_("\n\n跳过 %d 条（详见 crash.log）"), n_skip_total)
        end
        UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
    end

    return {
        ok = true,
        n_inserted_local = n_inserted_local,
        n_deleted_local = n_deleted_local,
        n_inserted_server = #actions.insert_on_server,
        n_deleted_server = #actions.delete_on_server,
        n_skipped = n_skip_total,
    }
end

--- "Pull remote highlights" button entry (M7). Per design v4 H-A2, pull and
--- push are inseparable (one sync round), so this is a thin wrapper around
--- _triggerSync with the bidirectional gate already on. The button label
--- emphasizes "pull" because that's the user-visible new capability, but it
--- always also pushes local-new highlights to server.
--- "Pull remote highlights" button entry + onOpenDocument scheduled entry (M7).
-- Per design v4 H-A2, pull and push are inseparable (one sync round), so this
-- is a thin wrapper around _triggerSync with the bidirectional gate already on.
-- The button label emphasizes "pull" because that's the user-visible new
-- capability, but it always also pushes local-new highlights to server.
--
-- @param manual bool|nil  true = user pressed button (override concurrent
--   guard like onSyncCurrentBook). false/nil = auto-scheduled from
--   onOpenDocument's scheduleIn(2s) — DON'T override, defer to close-document
--   fallback if M5 realtime is in flight.
--   M7 Day 3 review (architect H-3): scheduled pull forcing the lock would
--   preempt M5's debounce window, silently dropping a just-made highlight's
--   push until next user action. Manual override is fine (explicit user
--   intent); auto paths must respect the existing lock.
function FnsSync:_pullRemoteHighlights(manual)
    logger.info("[FNS] event: _pullRemoteHighlights (" .. (manual and "manual" or "scheduled") .. ")")
    if not self.settings.bidirectional_sync_enabled then
        -- Defensive: button is hidden when toggle is off (Day 2b menu), but
        -- pull_on_book_open scheduled task could fire if user toggled off
        -- between schedule and fire. Silent-skip.
        logger.info("[FNS] pull skipped: bidirectional_sync_enabled=false")
        return
    end
    if not self:isConfigured() then
        if manual then
            UIManager:show(InfoMessage:new{ text = _("请先配置服务 URL / Token / Vault") })
        else
            logger.info("[FNS] pull skipped: not configured")
        end
        return
    end
    if self._sync_in_flight then
        if manual then
            -- User-initiated: override guard like onSyncCurrentBook.
            logger.info("[FNS] pull: manual override, clearing in-flight lock")
            self._sync_in_flight = false
        else
            -- Scheduled: don't override. M5 debounce or another sync is running.
            -- Defer to close-document fallback (sync_on_book_close) or next
            -- manual trigger.
            logger.info("[FNS] pull skipped (scheduled): another sync in flight, will retry on close-document")
            return
        end
    end
    -- _triggerSync will route to _doSyncCurrentBookBidirectional via dispatcher
    -- (bidirectional_sync_enabled is true here).
    self:_triggerSync{ silent = false }
end

-- ===========================================================================
-- Auto-sync (M5)
-- ===========================================================================

-- Gate check: enabled AND auto_sync_enabled AND (a book is open).
-- Per-event sub-switches are checked by the callers (this only checks
-- gates shared by both highlight and close paths).
-- M9 (G5): isConfigured check removed — local mode auto-syncs to local
-- files too (same UX; a local write is fast and offline-safe). Users who
-- want no auto-write simply keep auto_sync_enabled off.
function FnsSync:_gateAutoSync()
    if not self.settings.enabled then return false end
    if not self.settings.auto_sync_enabled then return false end
    if not (self.ui and self.ui.annotation) then return false end
    return true
end

--- Reschedule the debounce timer. Unschedules the previous action (if any)
--- using the same closure reference, then schedules a fresh one with the
--- current debounce_seconds. Consecutive highlight edits within the debounce
--- window collapse into a single sync this way.
function FnsSync:_rescheduleAutoSync()
    UIManager:unschedule(self._auto_sync_action)
    -- tonumber: _editString stores user input as string; settings loaded from
    -- sidecar may also be string-typed. tonumber("5")=5, tonumber(nil/abc)=nil→5.
    -- math.max: UIManager:scheduleIn asserts seconds >= 0; clamp negatives
    -- (user could type "-1") to 0 so we don't crash on bad input.
    local delay = tonumber(self.settings.debounce_seconds) or 5
    delay = math.max(0, delay)
    UIManager:scheduleIn(delay, self._auto_sync_action)
end

--- Cancel any pending debounce timer. Called unconditionally on close-document
--- so a scheduled auto-sync can't fire after ReaderUI teardown (the closure
--- would dereference a dead self.ui).
function FnsSync:_cancelAutoSyncTimer()
    UIManager:unschedule(self._auto_sync_action)
end

--- Auto-sync entry: silent + offline-skipping. NetworkMgr:runWhenOnline would
--- pop a "turn on WiFi?" prompt on offline, which is jarring mid-reading and
--- catastrophic on close (the prompt would land on FileManager after the
--- reader has already closed). Silent-skip is safe — KOreader persists
--- highlights to local metadata.lua, so nothing is lost; next open / close /
--- manual sync catches up when online.
function FnsSync:_autoSyncCurrentBook()
    -- M9: 本地模式无需网络，也没有离线队列语义（本地写不产生网络失败）。
    -- 直接走本地同步（silent + skip 网络）。
    if self:_isLocalMode() then
        logger.info("[FNS] M9 local mode: auto-sync writes local files directly")
        self:_triggerSync({ silent = true, skip_run_when_online = true })
        return
    end
    if not NetworkMgr:isOnline() then
        -- M6: enqueue for auto-retry when NetworkConnected fires.
        -- (M5 only logged "will catch up on next trigger"; M6 makes it
        -- automatic — see _enqueueCurrentBook / _processQueue.)
        if self.settings.offline_queue_enabled then
            self:_enqueueCurrentBook()
        else
            logger.info("[FNS] auto-sync skipped: offline (queue disabled)")
        end
        return
    end
    -- skip_run_when_online=true: avoid TOCTOU window between isOnline check
    -- here and NetworkMgr:runWhenOnline's internal recheck. If the network
    -- drops in between, runWhenOnline would pop a WiFi prompt —
    -- catastrophic on close-document path. We've already gated on isOnline,
    -- so the wrapper is redundant for auto paths.
    self:_triggerSync{ silent = true, skip_run_when_online = true }
end

--- Highlight add/edit/delete/note change/color change. Payload structure
--- varies (see readerhighlight.lua / readerbookmark.lua dispatch sites); we
--- only use the event as a sync trigger signal, so we ignore it.
function FnsSync:onAnnotationsModified(payload)
    -- E-step1 review fix (D1 diagnostic): log payload KNOWN FIELDS ONLY.
    -- Do NOT dump the whole payload table — payload[1] is the annotation item
    -- which contains user's highlighted text (privacy risk in crash.log).
    -- Limited fields help diagnose the "mystery second AnnotationsModified"
    -- issue (Kindle 实测 14:25:11 来源未明).
    --
    -- KOreader 已知 dispatch sites（readerbookmark/readerhighlight）:
    --   cause="remote_pull"        本插件 Bidirectional pull（被下方显式跳过）
    --   nb_highlights_added=±1     高亮增/删（readerbookmark:480/490）
    --   nb_notes_added=±1          笔记增/删（readerbookmark:482/490）
    --   index_modified=±N          修改的 annotation 索引（带符号）
    --   modify_datetime=true       updateHighlight 边界修改（readerhighlight:2248）
    -- 无 cause 字段表示来自 saveHighlight / editStyle / editColor 等（readerhighlight.lua）
    local payload_info = "nil"
    if payload then
        local parts = {}
        if payload.cause ~= nil then parts[#parts+1] = "cause=" .. tostring(payload.cause) end
        if payload.nb_highlights_added ~= nil then parts[#parts+1] = "hl_added=" .. tostring(payload.nb_highlights_added) end
        if payload.nb_notes_added ~= nil then parts[#parts+1] = "notes_added=" .. tostring(payload.nb_notes_added) end
        if payload.index_modified ~= nil then parts[#parts+1] = "idx_mod=" .. tostring(payload.index_modified) end
        if payload.modify_datetime ~= nil then parts[#parts+1] = "mod_dt=" .. tostring(payload.modify_datetime) end
        payload_info = #parts > 0 and table.concat(parts, " ") or "(empty table)"
    end
    logger.info("[FNS] event: onAnnotationsModified payload={ " .. payload_info .. " }")
    -- M7: suppress M5 debounce during remote pull to avoid self-loop
    -- (per design v4 H-S2 fix, see progress 2026-08-06). Two suppression
    -- paths cover both phases of a pull round:
    --   1. _pull_in_flight: set true while batch addItem'ing server-fetched
    --      highlights. Each addItem → AnnotationsModified → here. Without
    --      this guard M5 would debounce-push mid-pull.
    --   2. payload.cause == "remote_pull": the single dispatch we fire AFTER
    --      the batch completes (carries nb_highlights_added summary). This
    --      lets other listeners (readerbookmark view refresh etc.) update,
    --      while M5 explicitly skips it.
    if self._pull_in_flight then
        logger.dbg("[FNS] onAnnotationsModified: skip (pull in flight)")
        return
    end
    if payload and payload.cause == "remote_pull" then
        logger.dbg("[FNS] onAnnotationsModified: skip (cause=remote_pull)")
        return
    end
    if not self:_gateAutoSync() then
        logger.dbg("[FNS] onAnnotationsModified: _gateAutoSync false")
        return
    end
    if not self.settings.sync_on_highlight then
        logger.dbg("[FNS] onAnnotationsModified: sync_on_highlight false")
        return
    end
    self:_rescheduleAutoSync()
end

--- Book close. Always cancel any pending highlight debounce first (even if
--- close-sync is off — otherwise the timer would fire post-teardown), then
--- optionally fire an immediate sync.
function FnsSync:onCloseDocument()
    logger.info("[FNS] event: onCloseDocument")
    self:_resetAiSession()  -- M8 Task D fix (reviewer H-2): clear AI session on book close
    self:_cancelAutoSyncTimer()
    if not self:_gateAutoSync() then
        logger.dbg("[FNS] onCloseDocument: _gateAutoSync false")
    elseif self.settings.sync_on_book_close then
        self:_autoSyncCurrentBook()  -- online: sync; offline: enqueue (M6)
    end
    -- M6: drain the queue opportunistically. If onNetworkConnected hasn't
    -- fired or was missed, this is the next-best chance to retry pending
    -- books. Safe to call regardless of online state (short-circuits on
    -- offline or when queue is empty).
    self:_processQueue()
end

-- ===========================================================================
-- Offline queue (M6)
-- ===========================================================================

-- scheduleIn delay after onNetworkConnected fires. Borrowed from KOSync
-- (kosync.koplugin/main.lua:1014) — lets KOreader internals settle before
-- we run HTTP requests (avoid races during startup / WiFi bringup).
local _PROCESS_QUEUE_DELAY = 0.5  -- seconds

--- Add the current book to the persistent queue (keyed by book path).
-- Dedup: if the path already has an entry, only refresh ts in memory
-- (avoids hammering saveSettings on rapid highlight edits — M-2/M-4 fix).
-- First creation writes through to disk immediately so a crash before next
-- flush doesn't lose the entry (M-2 fix). attempts is preserved on
-- re-enqueue (a failing book stays failing until user retries manually).
function FnsSync:_enqueueCurrentBook()
    local path = self:_getCurrentBookPath()
    if not path then
        logger.warn("[FNS] enqueue skipped: no current book path")
        return
    end
    local meta = self:_getBookMetadata()
    local entry = self.queue[path]
    if entry == nil then
        self.queue[path] = {
            ts = os.time(),
            attempts = 0,
            title = meta.title or "",
        }
        self:_saveQueue()
        logger.info(string.format("[FNS] enqueued (new): %s", path))
    else
        entry.ts = os.time()
        entry.title = meta.title or ""
        logger.info(string.format("[FNS] enqueued (refresh ts): %s", path))
    end
end

--- Load a book's annotations from its metadata.lua sidecar by path.
-- Used by _processQueueItem when draining a book that's no longer open.
--
-- Returns: annotations_table, meta, nil   on success
--          nil, nil, "file_missing"        book file no longer exists
--          nil, nil, "unsupported_format"  path suffix not in whitelist
--          nil, nil, "metadata_missing"    DocSettings can't open
-- (HIGH-F + M-6 fix: validate path before touching the filesystem.)
function FnsSync:_loadBookFromPath(book_path)
    if type(book_path) ~= "string" or book_path == "" then
        return nil, nil, "file_missing"
    end
    -- M-6: validate suffix against a whitelist before reading.
    local suffix = book_path:match("%.([%w]+)$")
    if not suffix then
        return nil, nil, "unsupported_format"
    end
    suffix = suffix:lower()
    local SUPPORTED_SUFFIXES = {
        epub = true, pdf = true, cbz = true, cbr = true, cbt = true,
        cb7 = true, fb2 = true, mobi = true, azw = true, azw3 = true,
        djv = true, djvu = true, doc = true, docx = true,
        txt = true, rtf = true, html = true, htm = true,
        chm = true, nt = true, pdb = true,
    }
    if not SUPPORTED_SUFFIXES[suffix] then
        return nil, nil, "unsupported_format"
    end
    local lfs = require("libs/libkoreader-lfs")
    if not lfs or lfs.attributes(book_path, "mode") ~= "file" then
        return nil, nil, "file_missing"
    end
    -- M6 review fix (queue miss bug): prefer runtime doc_settings if the
    -- current book matches. DocSettings:open(book_path) creates a fresh
    -- instance that reads from the sidecar FILE — but KOreader's runtime
    -- doc_settings (self.ui.doc_settings, held by ReaderUI since
    -- readerui.lua:131) has the LATEST annotations in memory, saved via
    -- readerannotation.lua:251 `self.ui.doc_settings:saveSetting("annotations",
    -- self.annotations)` but only flushed to disk on closeDocument.
    -- Reading from file misses any edits the user made since opening the
    -- book, causing the queue to compute an empty diff and miss the
    -- user's just-made highlights.
    local doc_settings
    if self.ui and self.ui.document and self.ui.document.file == book_path
        and self.ui.doc_settings then
        doc_settings = self.ui.doc_settings
        logger.info("[FNS] _loadBookFromPath: using runtime doc_settings (current book open)")
    else
        local DocSettings = require("docsettings")
        doc_settings = DocSettings:open(book_path)
        logger.info("[FNS] _loadBookFromPath: using sidecar file (book not currently open)")
    end
    local annotations, props
    local ok, err = pcall(function()
        annotations = doc_settings:readSetting("annotations") or {}
        props = doc_settings:readSetting("doc_props") or {}
    end)
    if not ok then
        -- H-3 review fix: readSetting threw → sidecar file is corrupted.
        -- Retry won't help (Lua chunk parse error is permanent until the
        -- file is regenerated). Distinct from "field absent" which returns
        -- nil and goes through annotations={} path. Return corrupted so
        -- caller drops entry instead of attempts++ loop.
        logger.warn("[FNS] readSetting failed (sidecar corrupted) for " .. book_path .. ": " .. tostring(err))
        return nil, nil, "metadata_corrupted"
    end
    local meta = {
        title = props.title or "",
        author = props.authors or "",
        language = props.language or "",
    }
    local overrides = self.settings.book_overrides or {}
    local o = overrides[book_path]
    if o then
        if o.title and o.title ~= "" then meta.title = o.title end
        if o.author and o.author ~= "" then meta.author = o.author end
    end
    return annotations, meta, nil
end

--- Process a single queue entry. Independent of _triggerSync (HIGH-B fix):
-- that path assumes self.ui is valid and reads self.ui.annotation directly.
-- The queue path may run for a book that's no longer open, so we load
-- annotations from the book's metadata.lua sidecar instead.
--
-- on_complete(success, reason) is invoked when done so the caller can
-- chain the next entry (HIGH-1 serial fix). reason values:
--   "synced" / "empty"              success → entry removed
--   "file_missing" / "unsupported_format"  entry dropped (HIGH-F fix)
--   "frozen"                        attempts reached MAX → entry frozen
--   "token_invalid"                 token failed → ALL entries frozen (HIGH-I)
--   "exception" / "api_failed"      failure → attempts++
--   "entry_gone"                    entry vanished mid-iteration
function FnsSync:_processQueueItem(book_path, on_complete)
    local entry = self.queue[book_path]
    if not entry then
        logger.info("[FNS] queue item gone: " .. book_path)
        if on_complete then on_complete(false, "entry_gone") end
        return
    end
    logger.info(string.format("[FNS] _processQueueItem: path=%s attempts=%d ts=%d",
        book_path, entry.attempts or 0, entry.ts or 0))

    -- H-1 review fix: re-check _sync_in_flight for the current book.
    -- _processQueue picked this entry when _sync_in_flight was false, but
    -- M5 realtime sync (via _triggerSync → nextTick) may have started in
    -- the window between pick and process. Defer to avoid concurrent
    -- _doSyncCurrentBook on the same book (data race in Marker.diff).
    local current_path = self:_getCurrentBookPath()
    if book_path == current_path and self._sync_in_flight then
        logger.info("[FNS] _processQueueItem defer (realtime sync in flight): " .. book_path)
        if on_complete then on_complete(false, "deferred") end
        return
    end

    local annotations, meta, load_err = self:_loadBookFromPath(book_path)
    if load_err == "file_missing" or load_err == "unsupported_format" then
        -- HIGH-F fix: book file gone/unreadable → drop entry, don't burn attempts.
        logger.warn(string.format("[FNS] queue drop (%s): %s", load_err, book_path))
        self.queue[book_path] = nil
        self:_saveQueue()
        if on_complete then on_complete(false, load_err) end
        return
    end
    if load_err == "metadata_corrupted" then
        -- H-3 review fix: sidecar file corrupted (readSetting threw).
        -- Retry won't help — drop entry. Distinct from "field absent"
        -- (readSetting returns nil → annotations={}) which goes through
        -- the empty-annotations path in _doSyncCurrentBook.
        logger.warn("[FNS] queue drop (sidecar corrupted): " .. book_path)
        self.queue[book_path] = nil
        self:_saveQueue()
        if on_complete then on_complete(false, "metadata_corrupted") end
        return
    end

    local note_path = Excerpt:resolvePath(self.settings, meta)
    logger.info(string.format("[FNS] queue sync start: title=%s annotations=%d path=%s",
        tostring(meta.title), #annotations, note_path))

    -- H-2 review fix: re-check isOnline before HTTP call.
    -- _processQueue may have scheduled when online, but network could drop
    -- by the time we get here (init scheduleIn(2s) race, or long back-off
    -- retry). Skip without burning attempts — entry stays, will be picked
    -- up by next onNetworkConnected drain.
    if not NetworkMgr:isOnline() then
        logger.info("[FNS] _processQueueItem skip: offline at last mile (no attempt burn)")
        if on_complete then on_complete(false, "offline") end
        return
    end

    -- _doSyncCurrentBookLegacy returns a result table (M6). pcall so any
    -- rendering/marker bug doesn't strand the entry and lock (HIGH-D fix).
    -- Direct call to Legacy (not dispatcher) per user decision #4 — queue
    -- path never does remote pull (offline books have nothing new on server
    -- worth fetching, and pull requires the book to be open for addItem).
    local ok, result_or_err = pcall(function()
        return self:_doSyncCurrentBookLegacy(annotations, meta, note_path, true)
    end)

    if not ok then
        logger.warn("[FNS] queue sync pcall failed: " .. tostring(result_or_err))
        entry.attempts = (entry.attempts or 0) + 1
        self:_saveQueue()
        if on_complete then on_complete(false, "exception") end
        return
    end

    local result = result_or_err or {}

    -- HIGH-I fix: token failure → freeze ALL entries + toast.
    if result.ok == false and result.result
        and Config.TOKEN_INVALID_CODES[result.result.biz_code] then
        logger.warn(string.format("[FNS] token invalid (biz_code=%s), freezing queue",
            tostring(result.result.biz_code)))
        for _, e in pairs(self.queue) do
            e.attempts = Config.MAX_RETRY_ATTEMPTS
        end
        self:_saveQueue()
        UIManager:show(InfoMessage:new{
            text = _("FNS：Token 已失效，请到设置 → 服务连接 → API Token 重填"),
            timeout = 5,
        })
        if on_complete then on_complete(false, "token_invalid") end
        return
    end

    if result.ok then
        logger.info("[FNS] queue sync success: " .. book_path)
        self.queue[book_path] = nil
        self:_saveQueue()
        if on_complete then on_complete(true, "synced") end
        return
    end

    -- H-2 fix (review): race condition (another client created the note
    -- between our getNote and createNote) is NOT a real failure — the note
    -- exists on server, our highlights are in metadata.lua, next sync will
    -- diff and apply. Don't burn attempts; treat as success.
    if result.reason == "race" then
        logger.info("[FNS] queue race (another client created note): " .. book_path)
        self.queue[book_path] = nil
        self:_saveQueue()
        if on_complete then on_complete(true, "race") end
        return
    end

    -- M6 review fix (E failure defense): empty annotations is a legitimate
    -- "nothing to sync" state (e.g. user deleted all highlights after
    -- enqueueing). Drop the entry without calling API — guards against
    -- _doSyncCurrentBook wiping the server-side note.
    if result.reason == "no_annotations" then
        logger.info("[FNS] queue drop (no annotations): " .. book_path)
        self.queue[book_path] = nil
        self:_saveQueue()
        if on_complete then on_complete(true, "no_annotations") end
        return
    end

    entry.attempts = (entry.attempts or 0) + 1
    local frozen = entry.attempts >= Config.MAX_RETRY_ATTEMPTS
    logger.warn(string.format("[FNS] queue sync fail (attempts=%d%s): %s",
        entry.attempts, frozen and " FROZEN" or "", book_path))
    self:_saveQueue()
    if on_complete then on_complete(false, frozen and "frozen" or "api_failed") end
end

--- Drain the queue: pick the next pending entry and process it serially.
-- Re-entry guard via _queue_processing (HIGH-2 fix). Serial chain
-- (HIGH-1 fix): each item's on_complete triggers the next via nextTick.
-- Skips the currently-open book if it's in the queue (M-5 fix): the
-- realtime _triggerSync path handles that book, queue should not race.
function FnsSync:_processQueue()
    if not self.settings.offline_queue_enabled then
        logger.dbg("[FNS] _processQueue skip: offline_queue_enabled=false")
        return
    end
    if not self.settings.enabled then
        logger.dbg("[FNS] _processQueue skip: enabled=false")
        return
    end
    if not self:isConfigured() then
        logger.dbg("[FNS] _processQueue skip: not configured")
        return
    end

    if self._queue_processing then
        logger.dbg("[FNS] _processQueue skip: already processing")
        return
    end

    -- Find next entry: lowest ts among non-frozen entries.
    -- M-5 fix refined (review A/B failure): only skip the current book
    -- when realtime sync is actually running (_sync_in_flight=true). If
    -- realtime path is idle (offline → online transition, queue-only
    -- flow), we MUST process the current book — otherwise a book enqueued
    -- while reading it never drains (M5 realtime path is offline-gated).
    local next_path = nil
    local next_ts = nil
    local current_path = self:_getCurrentBookPath()
    local total, frozen_count, skip_current = 0, 0, 0
    for path, entry in pairs(self.queue) do
        total = total + 1
        if (entry.attempts or 0) >= Config.MAX_RETRY_ATTEMPTS then
            frozen_count = frozen_count + 1
        else
            local skip = (path == current_path and self._sync_in_flight)
            if skip then
                skip_current = skip_current + 1
            elseif next_ts == nil or entry.ts < next_ts then
                next_ts = entry.ts
                next_path = path
            end
        end
    end
    if next_path == nil then
        logger.info(string.format(
            "[FNS] _processQueue: nothing to pick (total=%d frozen=%d skip_current=%d)",
            total, frozen_count, skip_current))
        return
    end
    logger.info(string.format(
        "[FNS] _processQueue: picked next (total=%d frozen=%d skip_current=%d) path=%s",
        total, frozen_count, skip_current, next_path))

    self._queue_processing = true

    -- Outer pcall (HIGH-D): if _processQueueItem itself throws before
    -- reaching its own pcall, release the lock to avoid permanent stall.
    local ok, err = pcall(function()
        self:_processQueueItem(next_path, function(success, reason)
            logger.info(string.format("[FNS] _processQueue callback: success=%s reason=%s",
                tostring(success), tostring(reason)))
            self._queue_processing = false
            if reason == "offline" then
                -- H-2 review fix: don't back-off retry. Wait for
                -- onNetworkConnected to trigger next drain (avoid loop).
                logger.info("[FNS] _processQueue stop: offline, waiting for NetworkConnected")
                return
            end
            if success or reason == "frozen" or reason == "token_invalid"
                or reason == "entry_gone" or reason == "file_missing"
                or reason == "unsupported_format" or reason == "metadata_corrupted"
                or reason == "empty" or reason == "no_annotations" then
                -- Continue draining remaining entries on next tick.
                -- H-3 fix: use stable _queue_drain_action so onCloseWidget
                -- can unschedule.
                UIManager:nextTick(self._queue_drain_action)
            else
                -- deferred / exception / api_failed: back-off before
                -- retrying to avoid hammering a failing API in a tight
                -- loop, or to let realtime sync finish first.
                logger.info("[FNS] _processQueue: back-off 2s before retry")
                UIManager:scheduleIn(2, self._queue_drain_action)
            end
        end)
    end)

    if not ok then
        self._queue_processing = false
        logger.warn("[FNS] _processQueue outer pcall failed: " .. tostring(err))
    end
end

--- NetworkConnected event handler (M6).
-- KOreader broadcasts this when WiFi connects (also at startup if already
-- online — see networkmanager.lua:154). 1s debounce via os.time() filters
-- jitter (M-7 fix; os.time granularity makes 100ms target 1s in practice,
-- which is fine — network events are typically >= 1s apart on Kindle).
-- scheduleIn(0.5s) lets KOreader internals settle (borrowed from KOSync).
function FnsSync:onNetworkConnected()
    logger.info("[FNS] event: onNetworkConnected")
    local now_s = os.time()
    if now_s - (self._last_network_event_ts or 0) < 1 then
        logger.info("[FNS] onNetworkConnected debounced (skip)")
        return
    end
    self._last_network_event_ts = now_s
    logger.info(string.format("[FNS] onNetworkConnected: scheduleIn(%ss) → _processQueue",
        tostring(_PROCESS_QUEUE_DELAY)))
    UIManager:scheduleIn(_PROCESS_QUEUE_DELAY, self._queue_drain_action)
end

--- NetworkDisconnected event handler (M6 review M-1). Mainly for logging
-- visibility — no functional action needed (queue stays, will retry on
-- next onNetworkConnected). Reset _last_network_event_ts so the next
-- connected event fires immediately (not debounced).
function FnsSync:onNetworkDisconnected()
    logger.info("[FNS] event: onNetworkDisconnected")
    self._last_network_event_ts = 0
end

--- Document open event (M6 review H-1). Design lists onOpenDocument as one
-- of the 3 fallback paths to drain the queue, but initial implementation
-- missed it. Cheap to add — just calls _processQueue.
-- M7: also schedules a delayed bidirectional pull when both
-- bidirectional_sync_enabled AND pull_on_book_open are on. The 2s delay
-- lets ReaderUI finish coming up (esp. crengine document load) before we
-- fire HTTP + addItem batch. _pull_action is a stable closure assigned
-- once in init, so onCloseWidget can unschedule cleanly if user closes
-- the book before the 2s timer fires.
function FnsSync:onOpenDocument()
    logger.info("[FNS] event: onOpenDocument")
    self:_processQueue()
    if self.settings.bidirectional_sync_enabled and self.settings.pull_on_book_open then
        logger.info("[FNS] onOpenDocument: scheduleIn(2s) → _pull_action (bidirectional pull)")
        UIManager:scheduleIn(2, self._pull_action)
    end
end

--- Widget teardown (M6 review H-3). Cancel any pending queue drain
-- scheduled via _queue_drain_action; otherwise the closure fires after
-- ReaderUI teardown, operating on a half-destroyed self. Also cancels
-- M5's auto-sync timer for symmetry.
-- NOTE (M6 review M-3): _queue_drain_action must only ever be assigned
-- once in init — never rebind elsewhere, or unschedule here would fail
-- (UIManager:unschedule matches by reference).
function FnsSync:onCloseWidget()
    logger.info("[FNS] event: onCloseWidget (unschedule timers)")
    if self._queue_drain_action then
        UIManager:unschedule(self._queue_drain_action)
    end
    if self._auto_sync_action then
        UIManager:unschedule(self._auto_sync_action)
    end
    -- M7: cancel any pending pull scheduled by onOpenDocument's scheduleIn(2s).
    -- Without this, _pull_action fires after ReaderUI teardown and dereferences
    -- a dead self.ui (same failure mode as M6's _queue_drain_action fix).
    if self._pull_action then
        UIManager:unschedule(self._pull_action)
    end
    -- M7 Day 3 review (code-reviewer M-4 + architect H-3 composite):
    -- defensively reset _pull_in_flight. If a pull was mid-flight when the
    -- user closed the book, the in-progress closure will be pcall-caught
    -- by _triggerSync's finally block — but if some path bypasses that
    -- (rare race), this defensive reset ensures M5 debounce isn't
    -- permanently silenced after teardown.
    self._pull_in_flight = false
end

function FnsSync:onSyncAllHistory()
    -- TODO M7: walk history dir, batch sync per book, show progress.
    -- (M6 work is the offline queue above; this is a separate user-triggered
    -- batch-sync feature for previously-read books.)
end

-- ===========================================================================
-- Menu
-- ===========================================================================

function FnsSync:addToMainMenu(menu_items)
    -- NOTE: do NOT cache self.settings into a local here.
    -- onResetConfig replaces self.settings with a fresh table; closures
    -- capturing a local would keep pointing at the stale one.
    menu_items.fns_sync = {
        text = _("FNS 同步"),
        -- Without sorting_hint, KOreader's MenuSorter treats this item as
        -- orphaned, prepends "NEW: " and dumps it in the first tab — so the
        -- user can't find it under Tools where they expect it.
        sorting_hint = "tools",
        sub_item_table = {
            -- Master switch
            {
                text = _("启用 FNS 同步"),
                checked_func = function() return self.settings.enabled end,
                callback = function() self:_toggleBool("enabled") end,
                separator = true,
            },

            -- Auto-sync (M5)
            {
                text = _("自动同步"),
                checked_func = function() return self.settings.auto_sync_enabled end,
                sub_item_table = {
                    {
                        text = _("启用自动同步"),
                        checked_func = function() return self.settings.auto_sync_enabled end,
                        callback = function() self:_toggleBool("auto_sync_enabled") end,
                        separator = true,
                    },
                    {
                        text = _("高亮修改时同步"),
                        checked_func = function() return self.settings.sync_on_highlight end,
                        -- M9 G5: local mode auto-syncs too — no isConfigured gate
                        enabled_func = function()
                            return self.settings.enabled
                               and self.settings.auto_sync_enabled
                        end,
                        callback = function() self:_toggleBool("sync_on_highlight") end,
                    },
                    {
                        text = _("关闭书籍时同步"),
                        checked_func = function() return self.settings.sync_on_book_close end,
                        enabled_func = function()
                            return self.settings.enabled
                               and self.settings.auto_sync_enabled
                        end,
                        callback = function() self:_toggleBool("sync_on_book_close") end,
                    },
                    {
                        text = _("同步延迟（秒）"),
                        keep_menu_open = true,
                        callback = function()
                            self:_editString("debounce_seconds",
                                _("同步延迟（秒）"),
                                _("数字，默认 5"))
                        end,
                    },
                    -- M7: Bidirectional sync (experimental, off by default)
                    {
                        text = _("双向同步（实验性）"),
                        checked_func = function() return self.settings.bidirectional_sync_enabled end,
                        enabled_func = function()
                            return self.settings.enabled
                               and self.settings.auto_sync_enabled
                               and self:isConfigured()
                        end,
                        sub_item_table = {
                            {
                                text = _("启用双向同步"),
                                checked_func = function() return self.settings.bidirectional_sync_enabled end,
                                enabled_func = function()
                                    return self.settings.enabled
                                       and self.settings.auto_sync_enabled
                                       and self:isConfigured()
                                end,
                                callback = function() self:_toggleBidirectionalSync() end,
                            },
                            {
                                text = _("开书时自动拉取"),
                                checked_func = function() return self.settings.pull_on_book_open end,
                                enabled_func = function()
                                    return self.settings.enabled
                                       and self.settings.auto_sync_enabled
                                       and self:isConfigured()
                                       and self.settings.bidirectional_sync_enabled
                                end,
                                callback = function() self:_toggleBool("pull_on_book_open") end,
                            },
                            {
                                text = _("说明"),
                                keep_menu_open = true,
                                callback = function()
                                    UIManager:show(InfoMessage:new{
                                        text = _("双向同步（实验性）：\n\n开启后，本设备的 KOreader 高亮会与 Obsidian 笔记双向同步。\n\n- 在 Obsidian 删除 HL@ 块 = 跨设备删除本地高亮\n- 其他设备新增的高亮会自动拉到本设备\n- 每条高亮会额外记录 XPointer 坐标到 Obsidian 笔记\n\n仅支持 EPUB/MOBI/AZW3/FB2/TXT/HTML（crengine 格式），PDF 不支持拉取。"),
                                        timeout = 10,
                                    })
                                end,
                            },
                        },
                    },
                },
                separator = true,
            },

            -- Offline queue (M6)
            {
                -- H-4 fix (review): dynamic text reflects token-failure state.
                -- If any entry is frozen, prefix [!] so user knows to check.
                text_func = function()
                    if not self.queue then return _("离线队列") end
                    local frozen = 0
                    for _, e in pairs(self.queue) do
                        if (e.attempts or 0) >= Config.MAX_RETRY_ATTEMPTS then
                            frozen = frozen + 1
                        end
                    end
                    if frozen > 0 then
                        return string.format(_("[!] 离线队列（%d 条已冻结）"), frozen)
                    end
                    return _("离线队列")
                end,
                checked_func = function() return self.settings.offline_queue_enabled end,
                enabled_func = function()
                    return self.settings.enabled and self:isConfigured()
                end,
                sub_item_table = {
                    {
                        text = _("启用离线队列"),
                        checked_func = function() return self.settings.offline_queue_enabled end,
                        callback = function() self:_toggleBool("offline_queue_enabled") end,
                        separator = true,
                    },
                    {
                        text_func = function()
                            local n = 0
                            if self.queue then
                                for _ in pairs(self.queue) do n = n + 1 end
                            end
                            return string.format(_("待同步队列（%d 本）"), n)
                        end,
                        enabled_func = function()
                            if not self.queue then return false end
                            for _ in pairs(self.queue) do return true end
                            return false
                        end,
                        callback = function()
                            local lines = {}
                            for path, entry in pairs(self.queue) do
                                local title = entry.title or path:match("[^/\\]+$") or path
                                local status = (entry.attempts or 0) >= Config.MAX_RETRY_ATTEMPTS
                                    and _("  [已冻结]")
                                    or string.format(_("  [失败 %d 次]"), entry.attempts or 0)
                                table.insert(lines, "📖 " .. title .. status)
                            end
                            UIManager:show(InfoMessage:new{
                                text = table.concat(lines, "\n"),
                                timeout = 5,
                            })
                        end,
                    },
                    {
                        text = _("重试冻结条目"),
                        enabled_func = function()
                            if not self.queue then return false end
                            for _, e in pairs(self.queue) do
                                if (e.attempts or 0) >= Config.MAX_RETRY_ATTEMPTS then
                                    return true
                                end
                            end
                            return false
                        end,
                        callback = function()
                            local reset_count = 0
                            for _, entry in pairs(self.queue) do
                                if (entry.attempts or 0) >= Config.MAX_RETRY_ATTEMPTS then
                                    entry.attempts = 0
                                    reset_count = reset_count + 1
                                end
                            end
                            if reset_count > 0 then
                                self:_saveQueue()
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("已重置 %d 条冻结条目，将开始重试"), reset_count),
                                    timeout = 2,
                                })
                                -- HIGH-G fix: process via the protected
                                -- entry so reset + drain is serialized.
                                UIManager:scheduleIn(_PROCESS_QUEUE_DELAY, self._queue_drain_action)
                            end
                        end,
                    },
                    {
                        text = _("清空队列"),
                        keep_menu_open = true,
                        enabled_func = function()
                            if not self.queue then return false end
                            for _ in pairs(self.queue) do return true end
                            return false
                        end,
                        callback = function()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            local n = 0
                            for _ in pairs(self.queue) do n = n + 1 end
                            UIManager:show(ConfirmBox:new{
                                text = string.format(_("将放弃 %d 本书的待同步状态。\n\n高亮仍保留在书中（metadata.lua），但不会自动同步到 Obsidian。"), n),
                                ok_text = _("清空"),
                                cancel_text = _("取消"),
                                ok_callback = function()
                                    self.queue = {}
                                    self:_saveQueue()
                                    UIManager:show(InfoMessage:new{
                                        text = _("队列已清空"),
                                        timeout = 2,
                                    })
                                end,
                            })
                        end,
                    },
                },
                separator = true,
            },

            -- Actions
            {
                -- M9: 本地模式（未配置 FNS）按钮照样可用，文案切换提示
                -- 笔记去向（G1：尊重 enabled 总开关）。
                text_func = function()
                    if self:_isLocalMode() then
                        return _("同步到本地笔记")
                    end
                    return _("立即同步当前书")
                end,
                enabled_func = function()
                    return self.settings.enabled
                end,
                callback = function() self:onSyncCurrentBook() end,
            },
            -- M9 (D3): view the local note file for the current book
            {
                text = _("查看本地笔记"),
                enabled_func = function()
                    return self.settings.enabled
                end,
                callback = function() self:onViewLocalNote() end,
            },
            -- M7: manual pull button. Visible always, enabled only when
            -- bidirectional_sync_enabled is on (greyed out otherwise as a
            -- discoverability hint that the feature exists).
            {
                text = _("立即拉取远端高亮"),
                enabled_func = function()
                    return self.settings.enabled
                       and self:isConfigured()
                       and self.settings.bidirectional_sync_enabled
                end,
                callback = function() self:_pullRemoteHighlights(true) end,
            },
            {
                text = _("立即同步全部历史"),
                enabled_func = function()
                    return false  -- TODO M6
                end,
                callback = function() self:onSyncAllHistory() end,
            },
            -- M8: AI assistant menu subtree (independent of FNS enabled)
            {
                text = _("AI 助手"),
                enabled_func = function() return self.settings.ai_enabled == true end,
                sub_item_table = {
                    {
                        text = _("启用 AI 对话"),
                        checked_func = function() return self.settings.ai_enabled end,
                        callback = function() self:_toggleBool("ai_enabled") end,
                        separator = true,
                    },
                    {
                        text = _("API 设置"),
                        sub_item_table = {
                            {
                                text = _("API 服务 URL"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_api_base",
                                        _("AI API 服务 URL"),
                                        "https://api.deepseek.com/v1")
                                end,
                            },
                            {
                                text = _("API Key"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_api_key",
                                        _("AI API Key"),
                                        _("sk-...（DeepSeek 或 OpenAI 兼容服务）"))
                                end,
                            },
                            {
                                text = _("模型名"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_model",
                                        _("AI 模型名"),
                                        "deepseek-chat / gpt-4o-mini / 等")
                                end,
                            },
                        },
                        separator = true,
                    },
                    {
                        text = _("提示词模板"),
                        sub_item_table = {
                            {
                                text = _("系统提示词"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_system_prompt",
                                        _("系统提示词（送给 AI 的角色设定）"),
                                        _("例如：你是一个阅读助手…"),
                                        true)
                                end,
                            },
                            {
                                text = _("翻译模板"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_quick_prompts.translate",
                                        _("翻译快捷模板"),
                                        _("可用 {text} 占位符"))
                                end,
                            },
                            {
                                text = _("解释模板"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_quick_prompts.explain",
                                        _("解释快捷模板"),
                                        _("可用 {text} 占位符"))
                                end,
                            },
                            {
                                text = _("评论模板"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_quick_prompts.comment",
                                        _("评论快捷模板"),
                                        _("可用 {text} 占位符"))
                                end,
                            },
                            {
                                text = _("总结模板"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_quick_prompts.summarize",
                                        _("总结快捷模板（让 AI 总结按钮使用）"),
                                        _("例如：请总结以上对话"))
                                end,
                            },
                        },
                        separator = true,
                    },
                    {
                        text = _("高级参数"),
                        sub_item_table = {
                            {
                                text = _("max_tokens"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_max_tokens",
                                        _("max_tokens"),
                                        "4096")
                                end,
                            },
                            {
                                text = _("temperature"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_temperature",
                                        _("temperature"),
                                        "0.7")
                                end,
                            },
                            {
                                text = _("超时（秒）"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("ai_timeout_sec",
                                        _("AI 调用超时（秒）"),
                                        "30")
                                end,
                            },
                        },
                    },
                    {
                        text = _("说明"),
                        keep_menu_open = true,
                        callback = function()
                            UIManager:show(InfoMessage:new{
                                text = _("AI 助手（M8）：\n\n1. 在 API 设置里填 base URL + Key + 模型名（DeepSeek 默认）\n2. 长按高亮 → 菜单 → 问 AI\n3. 多轮对话 → 让 AI 总结 → 加到笔记（同步到 Obsidian）\n\nAPI Key 明文存在 Kindle（跟 FNS Token 同级别），不加密。Kindle 丢失请到 DeepSeek 后台撤销 Key。"),
                                timeout = 10,
                            })
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("测试连接"),
                enabled_func = function() return self:isConfigured() end,
                callback = function() self:onTestConnection() end,
            },

            -- Per-book title/author override
            {
                text = _("当前书信息"),
                enabled_func = function() return self:_getCurrentBookPath() ~= nil end,
                sub_item_table = {
                    -- Informational: current file name (greyed out, not clickable)
                    {
                        text_func = function()
                            local path = self:_getCurrentBookPath() or ""
                            local name = path:match("[^/]+$") or path
                            if name == "" then name = _("(无打开的书)") end
                            return "📁 " .. name
                        end,
                        enabled_func = function() return false end,
                    },
                    -- Edit title override
                    {
                        text_func = function()
                            local title = self:_getBookMetadata().title
                            if title == "" then title = _("(未设置)") end
                            return "📖 " .. _("书名") .. ": " .. title
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:_editBookOverride("title", _("自定义书名"))
                        end,
                    },
                    -- Edit author override
                    {
                        text_func = function()
                            local author = self:_getBookMetadata().author
                            if author == "" then author = _("(未设置)") end
                            return "✍️ " .. _("作者") .. ": " .. author
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:_editBookOverride("author", _("自定义作者"))
                        end,
                    },
                    -- Reset to doc_props
                    {
                        text = _("🔄 重置为文件元数据"),
                        callback = function() self:_clearBookOverride() end,
                    },
                },
                separator = true,
            },

            -- Settings root
            {
                text = _("设置"),
                sub_item_table = {
                    -- Service connection
                    {
                        text = _("服务连接"),
                        sub_item_table = {
                            {
                                text = _("FNS 服务 URL"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("server_url",
                                        _("FNS 服务 URL"),
                                        "https://fns.example.com")
                                end,
                            },
                            {
                                text = _("API Token"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("api_token",
                                        _("API Token"),
                                        _("粘贴 FNS 服务生成的 Token"))
                                end,
                            },
                            {
                                text = _("Vault 名"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("vault",
                                        _("Vault 名"),
                                        _("Obsidian Vault 名称"))
                                end,
                            },
                        },
                        separator = true,
                    },

                    -- Note organization
                    {
                        text = _("笔记组织"),
                        sub_item_table = {
                            {
                                text = _("笔记路径前缀"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("note_path_prefix",
                                        _("笔记路径前缀"),
                                        _("只需文件夹名，例如 KOReader/刘慈欣（无需 / 或 \\ 结尾）"))
                                end,
                            },
                            {
                                text = _("笔记文件名模板"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("note_filename_template",
                                        _("笔记文件名模板"),
                                        _("可用 {title} {author} {language} {year} {date}；/ 表示子文件夹（\\ 会自动转为 /）"))
                                end,
                            },
                            {
                                text = _("笔记模板"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("note_template",
                                        _("笔记模板（创建新笔记时使用）"),
                                        _("完整模板文本，可用 {{VALUE:字段}} 占位符"),
                                        true)  -- multiline
                                end,
                            },
                        },
                        separator = true,
                    },

                    -- Excerpt rendering
                    {
                        text = _("摘录渲染"),
                        sub_item_table = {
                            {
                                text = _("显示页码"),
                                checked_func = function() return self.settings.show_page_number end,
                                callback = function() self:_toggleBool("show_page_number") end,
                            },
                            {
                                text = _("显示笔记标记"),
                                checked_func = function() return self.settings.show_note_marker end,
                                callback = function() self:_toggleBool("show_note_marker") end,
                            },
                            {
                                text = _("章节二级标题"),
                                checked_func = function() return self.settings.show_chapter_subtitle end,
                                callback = function() self:_toggleBool("show_chapter_subtitle") end,
                            },
                            {
                                text = _("颜色转 emoji"),
                                checked_func = function() return self.settings.color_to_emoji end,
                                callback = function() self:_toggleBool("color_to_emoji") end,
                            },
                            {
                                text = _("自定义摘录模板"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("excerpt_template",
                                        _("摘录模板"),
                                        _("可用 {page} {text} {note} {chapter} {datetime} {color}"),
                                        true)  -- multiline
                                end,
                                separator = true,
                            },
                        },
                        separator = true,
                    },

                    -- Trigger mode
                    {
                        text = _("触发模式"),
                        sub_item_table = {
                            {
                                text = _("高亮即同步"),
                                checked_func = function() return self.settings.sync_on_highlight end,
                                callback = function() self:_toggleBool("sync_on_highlight") end,
                            },
                            -- "开书同步" toggle removed in v4: was M5 placeholder
                            -- referencing sync_on_book_open, which is now
                            -- pull_on_book_open and lives under
                            -- 自动同步 → 双向同步（实验性） → 开书时自动拉取.
                            {
                                text = _("关书同步"),
                                checked_func = function() return self.settings.sync_on_book_close end,
                                callback = function() self:_toggleBool("sync_on_book_close") end,
                            },
                            {
                                text = _("防抖延迟（秒）"),
                                keep_menu_open = true,
                                callback = function()
                                    self:_editString("debounce_seconds",
                                        _("防抖延迟（秒）"),
                                        tostring(Config.DEFAULTS.debounce_seconds))
                                end,
                                separator = true,
                            },
                        },
                        separator = true,
                    },

                    -- Advanced
                    {
                        text = _("高级"),
                        sub_item_table = {
                            {
                                text = _("重置配置"),
                                keep_menu_open = true,
                                callback = function() self:onResetConfig() end,
                            },
                            {
                                text = _("关于"),
                                keep_menu_open = true,
                                callback = function()
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("FNS Sync\n\nKOreader 高亮/笔记同步到 Obsidian（通过 Fast Note Sync 服务）\n\n状态：%1"),
                                            self.settings.enabled and _("已启用") or _("未启用")),
                                    })
                                end,
                            },
                        },
                    },
                },
            },
        },
    }
end

return FnsSync
