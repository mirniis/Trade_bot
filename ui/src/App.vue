<script setup>
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue';

const API_TIMEOUT_MS = 10000;

const fetchJson = async (url, options = {}) => {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), API_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      ...options,
      signal: controller.signal
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(text || `HTTP ${res.status}`);
    }

    return await res.json();
  } catch (error) {
    if (error?.name === 'AbortError') {
      throw new Error(`request timeout (${API_TIMEOUT_MS}ms): ${url}`);
    }
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }
};

const fetchNoContent = async (url, options = {}) => {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), API_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      ...options,
      signal: controller.signal
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(text || `HTTP ${res.status}`);
    }
  } catch (error) {
    if (error?.name === 'AbortError') {
      throw new Error(`request timeout (${API_TIMEOUT_MS}ms): ${url}`);
    }
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }
};

const api = {
  async getDashboard() {
    return fetchJson('/api/dashboard');
  },
  async getSettings() {
    return fetchJson('/api/settings');
  },
  async saveSettings(payload) {
    await fetchNoContent('/api/settings', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
  },
  async getApiKeys() {
    return fetchJson('/api/api-keys');
  },
  async saveApiKeys(payload) {
    await fetchNoContent('/api/api-keys', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
  },
  async startBot() {
    await fetchNoContent('/api/bot/start', { method: 'POST' });
  },
  async stopBot() {
    await fetchNoContent('/api/bot/stop', { method: 'POST' });
  },
  async restartBot() {
    await fetchNoContent('/api/bot/restart', { method: 'POST' });
  }
};

const dashboard = ref(null);
const dashboardCacheByMode = reactive({
  demo: null,
  real: null
});
const settings = reactive({
  mode: 'demo',
  tp_percent: 12,
  sl_percent: 4,
  close_on_safe_pnl: 25,
  close_on_pnl_mode: 'safe',
  max_open_orders: 5,
  leverage: 10,
  risk_percent_per_order: 1,
  adverse_move_trigger_percent: 70,
  top_pairs_limit: 30,
  trading_schedule: 'mon-fri:06:00-19:00;sat:09:00-16:00;sun:off',
  auto_start: false,
});
const apiKeys = reactive({ api_key: '', api_secret: '' });
const loading = ref(true);
const modeSwitchLoading = ref(false);
const message = ref('');
const showSavedAlert = ref(false);
const signalsViewport = ref(null);
const showSettingsPreview = ref(false);
const showScheduleSettingsModal = ref(false);
const showStatsModal = ref(false);
const showOrderRejectModal = ref(false);
const showRestartConfirmModal = ref(false);
const orderRejectMessage = ref('');
const lastOrderRejectMessage = ref('');
const activeTimeDropdown = ref('');
const activeTimeDropdownInfo = ref(null);
const selectedStatsMonth = ref(new Date().getMonth() + 1);
const selectedStatsYear = ref(new Date().getFullYear());
const selectedStatsWeek = ref(1);

let saveTimer = null;
let keySaveTimer = null;
let stream = null;
let reconnectTimer = null;
let alertTimer = null;

const normalizeMode = (value) => (String(value || 'demo').toLowerCase() === 'real' ? 'real' : 'demo');

const cloneDashboard = (value) => {
  if (!value || typeof value !== 'object') {
    return null;
  }
  try {
    return JSON.parse(JSON.stringify(value));
  } catch (_) {
    return null;
  }
};

const cacheDashboardForMode = (mode, value) => {
  const normalizedMode = normalizeMode(mode);
  const snapshot = cloneDashboard(value);
  if (!snapshot) {
    return;
  }
  dashboardCacheByMode[normalizedMode] = snapshot;
};

const getCachedDashboardForMode = (mode) => {
  const normalizedMode = normalizeMode(mode);
  const snapshot = cloneDashboard(dashboardCacheByMode[normalizedMode]);
  return snapshot;
};

const uptime = computed(() => {
  if (!dashboard.value) return '0s';
  const sec = dashboard.value.status.uptime_seconds;
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  return `${h}h ${m}m ${s}s`;
});

const tokenCards = computed(() => {
  if (!dashboard.value || !dashboard.value.scanner) {
    return [];
  }
  return dashboard.value.scanner.slice(0, 4).map((row) => ({
    symbol: row.symbol,
    confidence: row.confidence,
    verdict: row.verdict,
    long: row.total_long,
    short: row.total_short
  }));
});

const scannerRows = computed(() => {
  if (!dashboard.value || !dashboard.value.scanner) {
    return [];
  }
  return dashboard.value.scanner.slice(0, 18);
});

const stableOrders = computed(() => {
  const orders = dashboard.value?.orders || [];
  return [...orders].sort((a, b) => {
    const symbolCmp = String(a.symbol || '').localeCompare(String(b.symbol || ''));
    if (symbolCmp !== 0) {
      return symbolCmp;
    }
    return String(a.side || '').localeCompare(String(b.side || ''));
  });
});

const recentClosedHistory = computed(() => {
  const list = dashboard.value?.trade_history || [];
  return [...list]
    .sort((a, b) => new Date(b.closed_at).getTime() - new Date(a.closed_at).getTime())
    .slice(0, 32);
});

const signalCards = computed(() => {
  if (!dashboard.value || !dashboard.value.scanner) {
    return [];
  }
  return dashboard.value.scanner.slice(0, 12).map((row) => ({
    symbol: row.symbol,
    verdict: row.verdict,
    long: row.total_long,
    short: row.total_short
  }));
});

const lastOpenedSignal = computed(() => {
  const orders = dashboard.value?.orders || [];
  if (!orders.length) {
    return null;
  }

  const latestOrder = [...orders].sort(
    (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
  )[0];

  if (!latestOrder) {
    return null;
  }

  const direction = (latestOrder.side === 'Buy' || latestOrder.side === 'Long') ? 'LONG' : 'SHORT';
  const scannerRow = (dashboard.value?.scanner || []).find((row) => row.symbol === latestOrder.symbol);
  let score = 0;

  if (scannerRow) {
    score = direction === 'LONG'
      ? Number(scannerRow.total_long || 0) - Number(scannerRow.total_short || 0)
      : Number(scannerRow.total_short || 0) - Number(scannerRow.total_long || 0);
  }

  return {
    instrument: latestOrder.symbol,
    lev: Number(latestOrder.leverage || 0),
    direction,
    score
  };
});

const statsMonthOptions = [
  { value: 1, label: 'January' },
  { value: 2, label: 'February' },
  { value: 3, label: 'March' },
  { value: 4, label: 'April' },
  { value: 5, label: 'May' },
  { value: 6, label: 'June' },
  { value: 7, label: 'July' },
  { value: 8, label: 'August' },
  { value: 9, label: 'September' },
  { value: 10, label: 'October' },
  { value: 11, label: 'November' },
  { value: 12, label: 'December' }
];
const statsNow = new Date();
const statsCurrentYear = statsNow.getFullYear();
const statsCurrentMonth = statsNow.getMonth() + 1;

const statsYearOptions = computed(() => {
  const years = new Set([statsCurrentYear]);
  for (const t of dashboard.value?.pnl_stat_history || []) {
    const dt = new Date(t.date);
    if (!Number.isNaN(dt.getTime())) {
      years.add(dt.getUTCFullYear());
    }
  }
  return [...years].sort((a, b) => b - a);
});

const availableStatsMonthOptions = computed(() => {
  const selectedYear = Number(selectedStatsYear.value);
  if (selectedYear === statsCurrentYear) {
    return statsMonthOptions.filter((m) => m.value <= statsCurrentMonth);
  }
  return statsMonthOptions;
});

const normalizeSelectedStatsMonth = () => {
  const selectedYear = Number(selectedStatsYear.value);
  const maxMonth = selectedYear === statsCurrentYear ? statsCurrentMonth : 12;
  if (Number(selectedStatsMonth.value) > maxMonth) {
    selectedStatsMonth.value = maxMonth;
  }
};

const daysInSelectedStatsMonth = computed(() =>
  new Date(Number(selectedStatsYear.value), Number(selectedStatsMonth.value), 0).getDate()
);

const todayUtcKey = computed(() => {
  const now = new Date();
  const y = now.getUTCFullYear();
  const m = String(now.getUTCMonth() + 1).padStart(2, '0');
  const d = String(now.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
});

const pnlStatSourceRows = computed(() => {
  const activeMode = String(settings.mode || 'demo').toLowerCase();
  return (dashboard.value?.pnl_stat_history || [])
    .filter((x) => !x.mode || String(x.mode).toLowerCase() === activeMode)
    .map((x) => ({
    date: x.date,
    pnl: Number(x.pnl || 0),
    mode: String(x.mode || 'demo').toLowerCase()
  }));
});

const walletDailyPnlFromTrades = computed(() => {
  let total = 0;
  for (const t of dashboard.value?.trade_history || []) {
    const dt = new Date(t.closed_at);
    if (Number.isNaN(dt.getTime())) {
      continue;
    }
    const y = dt.getUTCFullYear();
    const m = String(dt.getUTCMonth() + 1).padStart(2, '0');
    const d = String(dt.getUTCDate()).padStart(2, '0');
    if (`${y}-${m}-${d}` === todayUtcKey.value) {
      total += Number(t.pnl || 0);
    }
  }
  return total;
});

const statsDailyRows = computed(() => {
  const dayCount = daysInSelectedStatsMonth.value;
  const rows = Array.from({ length: dayCount }, (_, i) => ({
    day: i + 1,
    pnl: 0,
    tradesCount: 0
  }));

  for (const t of pnlStatSourceRows.value) {
    const dt = new Date(t.date);
    if (Number.isNaN(dt.getTime())) {
      continue;
    }
    const y = dt.getUTCFullYear();
    const m = dt.getUTCMonth() + 1;
    const d = dt.getUTCDate();
    if (y !== Number(selectedStatsYear.value) || m !== Number(selectedStatsMonth.value)) {
      continue;
    }
    if (d >= 1 && d <= dayCount) {
      rows[d - 1].pnl += Number(t.pnl || 0);
      rows[d - 1].tradesCount += 1;
    }
  }

  const maxAbs = rows.reduce((acc, row) => Math.max(acc, Math.abs(row.pnl)), 0);
  return rows.map((row) => ({
    ...row,
    heightPct: maxAbs > 0 ? Math.max(4, Math.round((Math.abs(row.pnl) / maxAbs) * 100)) : 4
  }));
});

const statsWeekTabs = computed(() => {
  const dayCount = daysInSelectedStatsMonth.value;
  return [
    { week: 1, startDay: 1, endDay: Math.min(7, dayCount) },
    { week: 2, startDay: 8, endDay: Math.min(14, dayCount) },
    { week: 3, startDay: 15, endDay: Math.min(21, dayCount) },
    { week: 4, startDay: 22, endDay: dayCount }
  ].map((tab) => ({
    ...tab,
    label: `${String(tab.startDay).padStart(2, '0')}-${String(tab.endDay).padStart(2, '0')}`
  }));
});

const selectedStatsWeekRange = computed(() => {
  const found = statsWeekTabs.value.find((tab) => tab.week === Number(selectedStatsWeek.value));
  return found || statsWeekTabs.value[0];
});

const statsVisibleDailyRows = computed(() => {
  const range = selectedStatsWeekRange.value;
  const visible = statsDailyRows.value.filter((row) => row.day >= range.startDay && row.day <= range.endDay);
  const maxAbs = visible.reduce((acc, row) => Math.max(acc, Math.abs(row.pnl)), 0);
  return visible.map((row) => ({
    ...row,
    widthPct: maxAbs > 0 ? Math.max(8, Math.round((Math.abs(row.pnl) / maxAbs) * 100)) : 8
  }));
});

const statsVisibleMaxAbs = computed(() =>
  statsVisibleDailyRows.value.reduce((acc, row) => Math.max(acc, Math.abs(row.pnl)), 0)
);

const statsAxisTicks = computed(() => {
  const max = statsVisibleMaxAbs.value;
  if (max <= 0) {
    return [0];
  }
  return [1, 0.5, 0.25]
    .map((ratio) => max * ratio)
    .map((value) => Number(value.toFixed(value >= 100 ? 0 : 2)));
});

const statsAveragePnlPerDay = computed(() => {
  const dayPnlMap = new Map();
  for (const t of pnlStatSourceRows.value) {
    const dt = new Date(t.date);
    if (Number.isNaN(dt.getTime())) {
      continue;
    }
    const d = dt.getUTCDate();
    const y = dt.getUTCFullYear();
    const m = dt.getUTCMonth() + 1;
    const key = `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    dayPnlMap.set(key, (dayPnlMap.get(key) || 0) + Number(t.pnl || 0));
  }

  const activeDays = dayPnlMap.size;
  if (!activeDays) {
    return 0;
  }

  const total = Array.from(dayPnlMap.values()).reduce((acc, value) => acc + value, 0);
  return total / activeDays;
});

const openStatsModal = () => {
  normalizeSelectedStatsMonth();
  selectedStatsWeek.value = 1;
  showStatsModal.value = true;
};

const onStatsYearChange = () => {
  normalizeSelectedStatsMonth();
  selectedStatsWeek.value = 1;
};

const onStatsMonthChange = () => {
  selectedStatsWeek.value = 1;
};

const closeStatsModal = () => {
  showStatsModal.value = false;
};

const isRunning = computed(() => {
  return !!dashboard.value?.status?.running;
});

const statusMode = computed(() => {
  if (!dashboard.value) {
    return 'stoped';
  }
  if (!dashboard.value.status.running) {
    return 'stoped';
  }
  const rawState = String(dashboard.value.status.state || '').toLowerCase();
  if (rawState === 'paused') {
    return 'paused';
  }
  return 'scaning';
});

const dayKeyFromUtc = (date) => {
  const idx = date.getUTCDay();
  return ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'][idx] || 'sun';
};

const isWithinTradingSessionUtc = (scheduleText, date) => {
  const map = parseScheduleToMap(scheduleText);
  const dayKey = dayKeyFromUtc(date);
  const dayCfg = map[dayKey];
  if (!dayCfg || !dayCfg.enabled) {
    return false;
  }

  const nowMinutes = date.getUTCHours() * 60 + date.getUTCMinutes();
  const start = parseHmToMinutes(dayCfg.start);
  const end = parseHmToMinutes(dayCfg.end);
  return end > start && nowMinutes >= start && nowMinutes < end;
};

const showTradingDayEnded = computed(() => {
  if (!dashboard.value?.status?.running) {
    return false;
  }
  return !isWithinTradingSessionUtc(settings.trading_schedule, new Date());
});

const topPairsOptions = [30, 50, 100, 150, 550];
const topPairsSetting = computed({
  get() {
    return Number(settings.top_pairs_limit);
  },
  set(value) {
    settings.top_pairs_limit = Number(value);
  }
});

const weekdayOrder = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const weekdayLabels = {
  mon: 'Mon',
  tue: 'Tue',
  wed: 'Wed',
  thu: 'Thu',
  fri: 'Fri',
  sat: 'Sat',
  sun: 'Sun'
};
const hourOptions = Array.from({ length: 24 }, (_, h) => String(h).padStart(2, '0'));
const minuteOptions = Array.from({ length: 12 }, (_, i) => String(i * 5).padStart(2, '0'));

const scheduleEditorMode = ref('group');

const groupedSchedule = reactive({
  monFriEnabled: true,
  monFriStart: '06:00',
  monFriEnd: '19:00',
  satEnabled: true,
  satStart: '09:00',
  satEnd: '16:00',
  sunEnabled: false,
  sunStart: '09:00',
  sunEnd: '16:00'
});

const dailySchedule = reactive({
  mon: { enabled: true, start: '06:00', end: '19:00' },
  tue: { enabled: true, start: '06:00', end: '19:00' },
  wed: { enabled: true, start: '06:00', end: '19:00' },
  thu: { enabled: true, start: '06:00', end: '19:00' },
  fri: { enabled: true, start: '06:00', end: '19:00' },
  sat: { enabled: true, start: '09:00', end: '16:00' },
  sun: { enabled: false, start: '09:00', end: '16:00' }
});

const normalizeHm = (value, fallback) => {
  const raw = String(value || '').trim();
  const parts = raw.split(':');
  if (parts.length !== 2) {
    return fallback;
  }
  const h = Number(parts[0]);
  const m = Number(parts[1]);
  if (!Number.isInteger(h) || !Number.isInteger(m) || h < 0 || h > 23 || m < 0 || m > 59) {
    return fallback;
  }
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
};

const parseHmToMinutes = (value) => {
  const [h, m] = normalizeHm(value, '00:00').split(':').map(Number);
  return h * 60 + m;
};

const parseDayToken = (token) => {
  const key = token.trim().toLowerCase();
  if (weekdayOrder.includes(key)) {
    return [key];
  }
  const [left, right] = key.split('-');
  if (!left || !right) {
    return [];
  }
  const from = weekdayOrder.indexOf(left);
  const to = weekdayOrder.indexOf(right);
  if (from < 0 || to < 0 || from > to) {
    return [];
  }
  return weekdayOrder.slice(from, to + 1);
};

const parseScheduleToMap = (scheduleText) => {
  const parsed = {
    mon: { enabled: false, start: '06:00', end: '19:00' },
    tue: { enabled: false, start: '06:00', end: '19:00' },
    wed: { enabled: false, start: '06:00', end: '19:00' },
    thu: { enabled: false, start: '06:00', end: '19:00' },
    fri: { enabled: false, start: '06:00', end: '19:00' },
    sat: { enabled: false, start: '09:00', end: '16:00' },
    sun: { enabled: false, start: '09:00', end: '16:00' }
  };

  const segments = String(scheduleText || '')
    .split(';')
    .map((s) => s.trim())
    .filter(Boolean);

  for (const segment of segments) {
    const splitAt = segment.indexOf(':');
    if (splitAt <= 0) {
      continue;
    }
    const dayExpr = segment.slice(0, splitAt).trim();
    const timeExpr = segment.slice(splitAt + 1).trim();

    const days = dayExpr
      .split(',')
      .flatMap((part) => parseDayToken(part))
      .filter(Boolean);
    if (!days.length) {
      continue;
    }

    if (timeExpr.toLowerCase() === 'off') {
      for (const day of days) {
        parsed[day].enabled = false;
      }
      continue;
    }

    const [fromRaw, toRaw] = timeExpr.split('-').map((s) => s.trim());
    if (!fromRaw || !toRaw) {
      continue;
    }
    const from = normalizeHm(fromRaw, '06:00');
    const to = normalizeHm(toRaw, '19:00');

    for (const day of days) {
      parsed[day].enabled = true;
      parsed[day].start = from;
      parsed[day].end = to;
    }
  }

  return parsed;
};

const scheduleEntryToText = (dayKey, entry) => {
  if (!entry.enabled) {
    return `${dayKey}:off`;
  }
  const from = normalizeHm(entry.start, '06:00');
  const to = normalizeHm(entry.end, '19:00');
  return `${dayKey}:${from}-${to}`;
};

const buildScheduleFromGroup = () => {
  const monFri = groupedSchedule.monFriEnabled
    ? `mon-fri:${normalizeHm(groupedSchedule.monFriStart, '06:00')}-${normalizeHm(groupedSchedule.monFriEnd, '19:00')}`
    : 'mon-fri:off';
  const sat = groupedSchedule.satEnabled
    ? `sat:${normalizeHm(groupedSchedule.satStart, '09:00')}-${normalizeHm(groupedSchedule.satEnd, '16:00')}`
    : 'sat:off';
  const sun = groupedSchedule.sunEnabled
    ? `sun:${normalizeHm(groupedSchedule.sunStart, '09:00')}-${normalizeHm(groupedSchedule.sunEnd, '16:00')}`
    : 'sun:off';
  return `${monFri};${sat};${sun}`;
};

const buildScheduleFromDaily = () => {
  return weekdayOrder
    .map((day) => scheduleEntryToText(day, dailySchedule[day]))
    .join(';');
};

const applyScheduleToEditors = (scheduleText) => {
  const parsed = parseScheduleToMap(scheduleText);
  for (const day of weekdayOrder) {
    dailySchedule[day].enabled = parsed[day].enabled;
    dailySchedule[day].start = parsed[day].start;
    dailySchedule[day].end = parsed[day].end;
  }

  const monRef = parsed.mon;
  const weekdaysUniform = ['tue', 'wed', 'thu', 'fri'].every(
    (d) => parsed[d].enabled === monRef.enabled
      && parsed[d].start === monRef.start
      && parsed[d].end === monRef.end
  );

  scheduleEditorMode.value = weekdaysUniform ? 'group' : 'daily';
  groupedSchedule.monFriEnabled = monRef.enabled;
  groupedSchedule.monFriStart = monRef.start;
  groupedSchedule.monFriEnd = monRef.end;
  groupedSchedule.satEnabled = parsed.sat.enabled;
  groupedSchedule.satStart = parsed.sat.start;
  groupedSchedule.satEnd = parsed.sat.end;
  groupedSchedule.sunEnabled = parsed.sun.enabled;
  groupedSchedule.sunStart = parsed.sun.start;
  groupedSchedule.sunEnd = parsed.sun.end;
};

const syncScheduleToSettings = () => {
  settings.trading_schedule = scheduleEditorMode.value === 'group'
    ? buildScheduleFromGroup()
    : buildScheduleFromDaily();
};

const onScheduleEditorModeChange = () => {
  if (scheduleEditorMode.value === 'group') {
    groupedSchedule.monFriEnabled = dailySchedule.mon.enabled;
    groupedSchedule.monFriStart = dailySchedule.mon.start;
    groupedSchedule.monFriEnd = dailySchedule.mon.end;
    groupedSchedule.satEnabled = dailySchedule.sat.enabled;
    groupedSchedule.satStart = dailySchedule.sat.start;
    groupedSchedule.satEnd = dailySchedule.sat.end;
    groupedSchedule.sunEnabled = dailySchedule.sun.enabled;
    groupedSchedule.sunStart = dailySchedule.sun.start;
    groupedSchedule.sunEnd = dailySchedule.sun.end;
  }
  syncScheduleToSettings();
  scheduleAutosaveSettings();
};

const onScheduleEditorChange = () => {
  syncScheduleToSettings();
  scheduleAutosaveSettings();
};

const previewScheduleMap = computed(() => parseScheduleToMap(settings.trading_schedule));

const scheduleCalendarRows = computed(() => {
  return weekdayOrder.map((day) => {
    const entry = previewScheduleMap.value[day];
    const start = normalizeHm(entry.start, '06:00');
    const end = normalizeHm(entry.end, '19:00');
    const enabled = !!entry.enabled;
    const validRange = !enabled || parseHmToMinutes(end) > parseHmToMinutes(start);
    return {
      key: day,
      label: weekdayLabels[day],
      enabled,
      validRange,
      rangeText: enabled ? `${start} - ${end}` : 'OFF'
    };
  });
});

const scheduleEditorCalendarRows = computed(() => {
  return weekdayOrder.map((day) => {
    const entry = dailySchedule[day];
    const start = normalizeHm(entry.start, '06:00');
    const end = normalizeHm(entry.end, '19:00');
    const enabled = !!entry.enabled;
    const validRange = !enabled || parseHmToMinutes(end) > parseHmToMinutes(start);
    return {
      key: day,
      label: weekdayLabels[day],
      enabled,
      validRange
    };
  });
});

const closeSettingsPreview = () => {
  showSettingsPreview.value = false;
};

const openScheduleSettings = () => {
  scheduleEditorMode.value = 'daily';
  applyScheduleToEditors(settings.trading_schedule);
  scheduleEditorMode.value = 'daily';
  showScheduleSettingsModal.value = true;
};

const closeScheduleSettings = () => {
  showScheduleSettingsModal.value = false;
};

const applySchedulePreset = (preset) => {
  if (preset === 'workweek') {
    for (const day of ['mon', 'tue', 'wed', 'thu', 'fri']) {
      dailySchedule[day].enabled = true;
      dailySchedule[day].start = '06:00';
      dailySchedule[day].end = '19:00';
    }
    dailySchedule.sat.enabled = true;
    dailySchedule.sat.start = '09:00';
    dailySchedule.sat.end = '16:00';
    dailySchedule.sun.enabled = false;
    dailySchedule.sun.start = '09:00';
    dailySchedule.sun.end = '16:00';
  } else if (preset === 'everyday') {
    for (const day of weekdayOrder) {
      dailySchedule[day].enabled = true;
      dailySchedule[day].start = '06:00';
      dailySchedule[day].end = '19:00';
    }
  } else if (preset === 'alloff') {
    for (const day of weekdayOrder) {
      dailySchedule[day].enabled = false;
    }
  }
  scheduleEditorMode.value = 'daily';
  onScheduleEditorChange();
};

const getTimePart = (value, part) => {
  const normalized = normalizeHm(value, '06:00');
  const [h, m] = normalized.split(':');
  return part === 'hour' ? h : m;
};

const updateDayTimePart = (dayKey, field, part, value) => {
  const fallback = field === 'start' ? '06:00' : '19:00';
  const normalized = normalizeHm(dailySchedule[dayKey][field], fallback);
  const [h, m] = normalized.split(':');
  const nextHour = part === 'hour' ? String(value).padStart(2, '0') : h;
  const nextMinute = part === 'minute' ? String(value).padStart(2, '0') : m;
  dailySchedule[dayKey][field] = `${nextHour}:${nextMinute}`;
  onScheduleEditorChange();
};

const shiftDayTime = (dayKey, field, deltaMinutes) => {
  const fallback = field === 'start' ? '06:00' : '19:00';
  const current = normalizeHm(dailySchedule[dayKey][field], fallback);
  const total = parseHmToMinutes(current);
  const shifted = Math.min(1439, Math.max(0, total + deltaMinutes));
  const hh = String(Math.floor(shifted / 60)).padStart(2, '0');
  const mm = String(shifted % 60).padStart(2, '0');
  dailySchedule[dayKey][field] = `${hh}:${mm}`;
  onScheduleEditorChange();
};

const timeDropdownKey = (dayKey, field, part) => `${dayKey}:${field}:${part}`;

const getTimeOptions = (part) => (part === 'hour' ? hourOptions : minuteOptions);

const isTimeDropdownOpen = (dayKey, field, part) =>
  activeTimeDropdown.value === timeDropdownKey(dayKey, field, part);

const activeTimeDropdownOptions = computed(() => {
  if (!activeTimeDropdownInfo.value) {
    return [];
  }
  return getTimeOptions(activeTimeDropdownInfo.value.part);
});

const activeTimeDropdownValue = computed(() => {
  if (!activeTimeDropdownInfo.value) {
    return '';
  }
  const { dayKey, field, part } = activeTimeDropdownInfo.value;
  return getTimePart(dailySchedule[dayKey][field], part);
});

const activeTimeDropdownStyle = computed(() => {
  if (!activeTimeDropdownInfo.value) {
    return {};
  }
  return {
    left: `${activeTimeDropdownInfo.value.left}px`,
    top: `${activeTimeDropdownInfo.value.top}px`,
    width: `${activeTimeDropdownInfo.value.width}px`
  };
});

const closeTimeDropdown = () => {
  activeTimeDropdown.value = '';
  activeTimeDropdownInfo.value = null;
};

const toggleTimeDropdown = (dayKey, field, part, disabled, event) => {
  if (disabled) {
    return;
  }
  const key = timeDropdownKey(dayKey, field, part);
  if (activeTimeDropdown.value === key) {
    closeTimeDropdown();
    return;
  }

  const rect = event.currentTarget.getBoundingClientRect();
  activeTimeDropdown.value = key;
  activeTimeDropdownInfo.value = {
    dayKey,
    field,
    part,
    left: Math.round(rect.left),
    top: Math.round(rect.bottom + 4),
    width: Math.max(64, Math.round(rect.width))
  };
};

const selectTimeDropdownValue = (dayKey, field, part, value) => {
  updateDayTimePart(dayKey, field, part, value);
  closeTimeDropdown();
};

const handleWindowKeydown = (event) => {
  if (event.key === 'Escape') {
    closeTimeDropdown();
    closeStatsModal();
    closeSettingsPreview();
    closeScheduleSettings();
  }
};

const handleWindowPointerDown = (event) => {
  if (!event.target.closest('.schedule-time-dropdown') && !event.target.closest('.schedule-time-menu-portal')) {
    closeTimeDropdown();
  }
};

const setCloseOnPnlMode = (mode) => {
  settings.close_on_pnl_mode = mode === 'total' ? 'total' : 'safe';
  scheduleAutosaveSettings();
};

const settingsPayload = () => ({
  mode: settings.mode,
  tp_percent: Number(settings.tp_percent),
  sl_percent: Number(settings.sl_percent),
  close_on_safe_pnl: Number(settings.close_on_safe_pnl),
  close_on_pnl_mode: String(settings.close_on_pnl_mode || 'safe'),
  max_open_orders: Number(settings.max_open_orders),
  leverage: Number(settings.leverage),
  risk_percent_per_order: Number(settings.risk_percent_per_order),
  adverse_move_trigger_percent: Number(settings.adverse_move_trigger_percent),
  top_pairs_limit: Number(settings.top_pairs_limit),
  trading_schedule: String(settings.trading_schedule || '').trim(),
  auto_start: Boolean(settings.auto_start),
});

const showSavedToast = (text) => {
  message.value = text;
  showSavedAlert.value = true;
  clearTimeout(alertTimer);
  alertTimer = setTimeout(() => {
    showSavedAlert.value = false;
  }, 1100);
};

const maybeWarnMissingModeKeys = () => {
  const missing = !String(apiKeys.api_key || '').trim() || !String(apiKeys.api_secret || '').trim();
  if (settings.mode === 'real' && missing) {
    message.value = 'Real mode selected: add API key and secret from REAL Bybit account';
  }
};

const saveSettingsNow = async () => {
  clearTimeout(saveTimer);
  await api.saveSettings(settingsPayload());
};

const scheduleAutosaveSettings = () => {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    try {
      await saveSettingsNow();
      showSavedToast('Настройки сохранены автоматически');
    } catch (e) {
      message.value = `Ошибка сохранения настроек: ${e.message}`;
    }
  }, 600);
};

const onModeChange = async () => {
  const targetMode = normalizeMode(settings.mode);
  const cached = getCachedDashboardForMode(targetMode);
  if (cached) {
    dashboard.value = cached;
    modeSwitchLoading.value = false;
  } else {
    modeSwitchLoading.value = true;
  }

  try {
    await saveSettingsNow();
    showSavedToast(`Режим переключен: ${String(settings.mode).toUpperCase()}`);

    const [dash, keys] = await Promise.all([
      api.getDashboard(),
      api.getApiKeys()
    ]);

    dashboard.value = dash;
  cacheDashboardForMode(targetMode, dash);
    apiKeys.api_key = keys.api_key;
    apiKeys.api_secret = keys.api_secret;
    maybeWarnMissingModeKeys();
  } catch (e) {
    message.value = `Ошибка переключения режима: ${e.message}`;
    await loadAll();
  } finally {
    modeSwitchLoading.value = false;
  }
};

const scheduleAutosaveApi = () => {
  clearTimeout(keySaveTimer);
  if (!apiKeys.api_key.trim() || !apiKeys.api_secret.trim()) {
    return;
  }
  if (apiKeys.api_key.includes('*') || apiKeys.api_secret.includes('*')) {
    return;
  }
  keySaveTimer = setTimeout(async () => {
    try {
      await api.saveApiKeys({
        api_key: apiKeys.api_key,
        api_secret: apiKeys.api_secret
      });
      message.value = 'API ключи сохранены автоматически';
      showSavedAlert.value = true;
      clearTimeout(alertTimer);
      alertTimer = setTimeout(() => {
        showSavedAlert.value = false;
      }, 1100);
    } catch (e) {
      message.value = `Ошибка сохранения API: ${e.message}`;
    }
  }, 700);
};

const refreshDashboard = async () => {
  dashboard.value = await api.getDashboard();
};

const closeOrderRejectModal = () => {
  showOrderRejectModal.value = false;
};

const maybeShowOrderRejectModal = () => {
  const raw = String(dashboard.value?.metrics?.order_last_error || '').trim();
  if (!raw) {
    return;
  }
  if (raw === lastOrderRejectMessage.value) {
    return;
  }
  lastOrderRejectMessage.value = raw;
  orderRejectMessage.value = raw;
  showOrderRejectModal.value = true;
};

const applyDashboardEnvelope = (payload) => {
  if (!payload || typeof payload !== 'object') {
    return;
  }

  const kind = payload.kind;
  const data = payload.data;
  if (!data || typeof data !== 'object') {
    return;
  }

  if (kind === 'snapshot' || !dashboard.value) {
    dashboard.value = data;
    maybeShowOrderRejectModal();
    return;
  }

  if (kind === 'delta') {
    dashboard.value = {
      ...dashboard.value,
      ...data
    };
    maybeShowOrderRejectModal();
  }
};

const applyIncomingPayload = (raw) => {
  const payload = JSON.parse(raw);
  applyDashboardEnvelope(payload);
  loading.value = false;
};

const scheduleReconnect = () => {
  clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(connectDashboardStream, 1000);
};

const connectDashboardSse = () => {
  const es = new EventSource('/api/dashboard/stream');
  stream = es;

  es.onmessage = (evt) => {
    try {
      applyIncomingPayload(evt.data);
    } catch (_) {
      // Ignore malformed chunk and keep stream alive.
    }
  };

  es.onerror = () => {
    if (stream === es) {
      stream = null;
    }
    es.close();
    scheduleReconnect();
  };
};

const connectDashboardStream = () => {
  if (stream) {
    stream.close();
  }
  clearTimeout(reconnectTimer);

  const wsProtocol = window.location.protocol === 'https:' ? 'wss' : 'ws';
  const wsUrl = `${wsProtocol}://${window.location.host}/api/dashboard/ws`;
  const ws = new WebSocket(wsUrl);
  stream = ws;

  let fallbackActivated = false;

  ws.onmessage = (evt) => {
    try {
      applyIncomingPayload(evt.data);
    } catch (_) {
      // Ignore malformed chunk and keep stream alive.
    }
  };

  ws.onerror = () => {
    if (fallbackActivated) {
      return;
    }
    fallbackActivated = true;
    ws.onclose = null;
    try {
      ws.close();
    } catch (_) {
      // Ignore close errors.
    }
    connectDashboardSse();
  };

  ws.onclose = () => {
    if (fallbackActivated) {
      return;
    }
    if (stream === ws) {
      stream = null;
    }
    scheduleReconnect();
  };
};

const loadAll = async (withGlobalLoading = true) => {
  if (withGlobalLoading) {
    loading.value = true;
  }

  try {
    const [dash, cfg, keys] = await Promise.all([
      api.getDashboard(),
      api.getSettings(),
      api.getApiKeys()
    ]);

    dashboard.value = dash;
  cacheDashboardForMode(cfg.mode, dash);
    settings.mode = cfg.mode;
    settings.tp_percent = cfg.trading.tp_percent;
    settings.sl_percent = cfg.trading.sl_percent;
    settings.close_on_safe_pnl = Math.min(100, Math.max(10, Number(cfg.trading.close_on_safe_pnl ?? 25)));
    settings.close_on_pnl_mode = cfg.trading.close_on_pnl_mode === 'total' ? 'total' : 'safe';
    settings.max_open_orders = cfg.trading.max_open_orders;
    settings.leverage = cfg.trading.leverage;
    settings.risk_percent_per_order = cfg.trading.risk_percent_per_order;
    settings.adverse_move_trigger_percent = cfg.trading.adverse_move_trigger_percent ?? 70;
    settings.top_pairs_limit = cfg.trading.top_pairs_limit ?? 30;
    settings.trading_schedule = cfg.trading.trading_schedule || 'mon-fri:06:00-19:00;sat:09:00-16:00;sun:off';
    applyScheduleToEditors(settings.trading_schedule);
    settings.auto_start = cfg.auto_start;
    apiKeys.api_key = keys.api_key;
    apiKeys.api_secret = keys.api_secret;

    maybeWarnMissingModeKeys();
  } catch (e) {
    message.value = `Ошибка загрузки данных: ${e.message}`;
  } finally {
    if (withGlobalLoading) {
      loading.value = false;
    }
  }
};

const start = async () => {
  try {
    await saveSettingsNow();
    await api.startBot();
    message.value = 'Бот запущен';
    await refreshDashboard();
  } catch (e) {
    message.value = `Ошибка запуска: ${e.message}`;
  }
};

const stop = async () => {
  await api.stopBot();
  message.value = 'Бот остановлен';
  await refreshDashboard();
};

const openRestartConfirm = () => {
  showRestartConfirmModal.value = true;
};

const closeRestartConfirm = () => {
  showRestartConfirmModal.value = false;
};

const restartSystem = async () => {
  try {
    showRestartConfirmModal.value = false;
    message.value = 'Перезапуск системы бота...';
    await api.restartBot();
    await refreshDashboard();
    message.value = 'Система бота перезапущена';
  } catch (e) {
    message.value = `Ошибка перезапуска: ${e.message}`;
  }
};

const scrollSignals = (direction) => {
  if (!signalsViewport.value) {
    return;
  }
  const firstCard = signalsViewport.value.querySelector('.signal-card');
  const styles = getComputedStyle(signalsViewport.value);
  const gap = Number.parseFloat(styles.columnGap || styles.gap || '0');
  const step = firstCard ? firstCard.getBoundingClientRect().width + gap : 220;
  signalsViewport.value.scrollBy({
    left: direction * step,
    behavior: 'smooth'
  });
};

onMounted(async () => {
  await loadAll();
  if (dashboard.value && !dashboard.value.status.running) {
    try {
      await start();
    } catch (_) {
      // Start errors are already reflected in `message`.
    }
  }
  const previewOnceKey = 'settingsPreviewShownOnce';
  if (!window.localStorage.getItem(previewOnceKey)) {
    showSettingsPreview.value = true;
    window.localStorage.setItem(previewOnceKey, '1');
  }
  connectDashboardStream();
  window.addEventListener('keydown', handleWindowKeydown);
  window.addEventListener('pointerdown', handleWindowPointerDown);
});

onBeforeUnmount(() => {
  if (stream) {
    try {
      stream.close();
    } catch (_) {
      // Ignore close errors.
    }
  }
  clearTimeout(saveTimer);
  clearTimeout(keySaveTimer);
  clearTimeout(reconnectTimer);
  clearTimeout(alertTimer);
  window.removeEventListener('keydown', handleWindowKeydown);
  window.removeEventListener('pointerdown', handleWindowPointerDown);
});
</script>

<template>
  <div class="app-body">
    <main class="container-fluid px-0" v-if="!loading && dashboard">
      <div v-if="modeSwitchLoading" class="mode-switch-overlay" aria-live="polite" aria-busy="true">
        <div class="skeleton-mode-card"></div>
        <div class="skeleton-mode-card"></div>
        <div class="skeleton-mode-card"></div>
      </div>
      <div class="app-layout d-flex flex-column flex-lg-row min-vh-100">
        <section class="left-column p-4 p-md-5 d-flex flex-column justify-content-between">
          <div>
            <div class="wallet-block mb-4" aria-label="Wallet brand">

        <Teleport to="body">
          <div v-if="showOrderRejectModal" class="settings-preview-backdrop" @click.self="closeOrderRejectModal">
            <section class="settings-preview-modal" aria-label="Order reject dialog">
              <header class="settings-preview-head">
                <h3 class="settings-preview-title">Order Rejected</h3>
                <button type="button" class="settings-preview-close" @click="closeOrderRejectModal">Close</button>
              </header>
              <p class="schedule-editor-subtitle">{{ orderRejectMessage }}</p>
            </section>
          </div>
        </Teleport>
              <div class="wallet-title">
                <span class="wallet-mark">W</span><span class="wallet-text">allet</span>
              </div>
              <div class="wallet-columns">
                <div class="wallet-col">
                  <div class="wallet-col-name">Total equity</div>
                  <div class="wallet-col-value">${{ dashboard.metrics.total_equity.toFixed(2) }}</div>
                </div>
                <div class="wallet-col">
                  <div class="wallet-col-name">Unrealized PnL</div>
                  <div class="wallet-col-value">${{ dashboard.metrics.unrealized_pnl.toFixed(2) }}</div>
                </div>
                <div class="wallet-col">
                  <div class="wallet-col-name">Daily PnL</div>
                  <div class="wallet-col-value">${{ walletDailyPnlFromTrades.toFixed(2) }}</div>
                </div>
              </div>
            </div>

            <div class="api-mode-block" aria-label="API and mode settings">
              <div class="wallet-title">
                <span class="wallet-mark">A</span><span class="wallet-text">PI &amp; </span><span class="wallet-mark">M</span><span class="wallet-text">ode</span>
              </div>
              <div class="structure-list">
                <div class="mode-block structure-item" aria-label="Mode options">
                  <div class="mode-title">Mode</div>
                  <div class="mode-options">
                    <label class="mode-option" for="modeDemo">
                      <input id="modeDemo" type="radio" value="demo" class="mode-radio" v-model="settings.mode" @change="onModeChange" />
                      <span>Demo</span>
                    </label>
                    <label class="mode-option" for="modeReal">
                      <input id="modeReal" type="radio" value="real" class="mode-radio" v-model="settings.mode" @change="onModeChange" />
                      <span>Real</span>
                    </label>
                  </div>
                </div>

                <div class="settings-row structure-item" aria-label="API key setting">
                  <label class="settings-label" for="apiKeyInput">API Key</label>
                  <input id="apiKeyInput" type="text" class="settings-input" v-model="apiKeys.api_key" @input="scheduleAutosaveApi" />
                </div>

                <div class="settings-row structure-item" aria-label="API secret setting">
                  <label class="settings-label" for="apiSecretInput">API Secret</label>
                  <input id="apiSecretInput" type="text" class="settings-input" v-model="apiKeys.api_secret" @input="scheduleAutosaveApi" />
                </div>
              </div>
            </div>

            <div class="trading-settings-block" aria-label="Trading settings section">
              <div class="wallet-title settings-title-row">
                <span><span class="wallet-mark">T</span><span class="wallet-text">rading settings</span></span>
                <div class="left-title-actions">
                  <button type="button" class="settings-preview-btn stats-open-btn" @click.stop="openStatsModal">
                    <span class="stats-open-icon" aria-hidden="true"></span>
                    <span>Statistics</span>
                  </button>
                  <button type="button" class="settings-preview-btn" @click.stop="showSettingsPreview = true">Preview</button>
                </div>
              </div>
              <div class="trading-params structure-list">
                <div class="tp-row structure-item" aria-label="Take profit setting">
                  <label class="settings-label" for="tpRange">TP%</label>
                  <div class="tp-control-wrap">
                    <div class="tp-range-wrap">
                      <input id="tpRange" type="range" class="tp-range" min="1" max="15" step="0.1" v-model.number="settings.tp_percent" @input="scheduleAutosaveSettings" />
                      <div class="tp-range-limits" aria-hidden="true"><span>1</span><span>15</span></div>
                    </div>
                    <span class="tp-value">{{ Number(settings.tp_percent).toFixed(1) }}</span>
                  </div>
                </div>

                <div class="tp-row structure-item" aria-label="Stop loss setting">
                  <label class="settings-label" for="slRange">SL%</label>
                  <div class="tp-control-wrap">
                    <div class="tp-range-wrap">
                      <input id="slRange" type="range" class="tp-range" min="1" max="10" step="0.1" v-model.number="settings.sl_percent" @input="scheduleAutosaveSettings" />
                      <div class="tp-range-limits" aria-hidden="true"><span>1</span><span>10</span></div>
                    </div>
                    <span class="tp-value">{{ Number(settings.sl_percent).toFixed(1) }}</span>
                  </div>
                </div>

                <div class="tp-row tp-row-auto-close structure-item" aria-label="Close on safe pnl setting">
                  <label class="settings-label" for="closeOnSafePnlRange">Auto close on:</label>
                  <div class="tp-row-auto-close-body">
                    <div class="tp-control-wrap">
                      <div class="tp-range-wrap">
                        <input id="closeOnSafePnlRange" type="range" class="tp-range" min="10" max="100" step="5" v-model.number="settings.close_on_safe_pnl" @input="scheduleAutosaveSettings" />
                        <div class="tp-range-limits" aria-hidden="true"><span>10</span><span>100</span></div>
                      </div>
                      <span class="tp-value">{{ Number(settings.close_on_safe_pnl).toFixed(0) }}</span>
                    </div>
                    <div class="auto-close-mode-options">
                      <label class="mode-option" for="closeOnSafeMode">
                        <input
                          id="closeOnSafeMode"
                          type="checkbox"
                          class="mode-radio"
                          :checked="settings.close_on_pnl_mode === 'safe'"
                          @change="setCloseOnPnlMode('safe')"
                        />
                        <span>Safe PnL</span>
                      </label>
                      <label class="mode-option" for="closeOnTotalMode">
                        <input
                          id="closeOnTotalMode"
                          type="checkbox"
                          class="mode-radio"
                          :checked="settings.close_on_pnl_mode === 'total'"
                          @change="setCloseOnPnlMode('total')"
                        />
                        <span>Total PnL</span>
                      </label>
                    </div>
                  </div>
                </div>

                <div class="tp-row structure-item" aria-label="RPO setting">
                  <label class="settings-label" for="rpoRange">RPO%</label>
                  <div class="tp-control-wrap">
                    <div class="tp-range-wrap">
                      <input id="rpoRange" type="range" class="tp-range" min="0.5" max="10" step="0.1" v-model.number="settings.risk_percent_per_order" @input="scheduleAutosaveSettings" />
                      <div class="tp-range-limits" aria-hidden="true"><span>0.5</span><span>10</span></div>
                    </div>
                    <span class="tp-value">{{ Number(settings.risk_percent_per_order).toFixed(1) }}</span>
                  </div>
                </div>

                <div class="tp-row structure-item" aria-label="Adverse move trigger setting">
                  <label class="settings-label" for="adverseMoveRange">Adverse move%</label>
                  <div class="tp-control-wrap">
                    <div class="tp-range-wrap">
                      <input id="adverseMoveRange" type="range" class="tp-range" min="10" max="90" step="5" v-model.number="settings.adverse_move_trigger_percent" @input="scheduleAutosaveSettings" />
                      <div class="tp-range-limits" aria-hidden="true"><span>10</span><span>90</span></div>
                    </div>
                    <span class="tp-value">{{ Number(settings.adverse_move_trigger_percent).toFixed(0) }}</span>
                  </div>
                </div>

                <div class="tp-row structure-item" aria-label="Leverage setting">
                  <label class="settings-label" for="leverageRange">Leverage</label>
                  <div class="tp-control-wrap">
                    <div class="tp-range-wrap">
                      <input id="leverageRange" type="range" class="tp-range" min="1" max="20" step="1" v-model.number="settings.leverage" @input="scheduleAutosaveSettings" />
                      <div class="tp-range-limits" aria-hidden="true"><span>1</span><span>20</span></div>
                    </div>
                    <span class="tp-value">{{ Number(settings.leverage).toFixed(0) }}</span>
                  </div>
                </div>

                <div class="tp-row structure-item" aria-label="Max orders setting">
                  <label class="settings-label" for="maxOrdersRange">Max orders</label>
                  <div class="tp-control-wrap">
                    <div class="tp-range-wrap">
                      <input id="maxOrdersRange" type="range" class="tp-range" min="1" max="10" step="1" v-model.number="settings.max_open_orders" @input="scheduleAutosaveSettings" />
                      <div class="tp-range-limits" aria-hidden="true"><span>1</span><span>10</span></div>
                    </div>
                    <span class="tp-value">{{ settings.max_open_orders }}</span>
                  </div>
                </div>

                <div class="top-pairs-row structure-item" aria-label="Top pairs trade setting">
                  <div class="settings-label">TOP Pairs trade</div>
                  <div class="top-pairs-options">
                    <label class="mode-option" v-for="value in topPairsOptions" :key="value" :for="`topPairs${value}`">
                      <input :id="`topPairs${value}`" type="radio" class="mode-radio" :value="value" v-model.number="topPairsSetting" @change="scheduleAutosaveSettings" />
                      <span>{{ value }}</span>
                    </label>
                  </div>
                </div>

                <div class="settings-row structure-item" aria-label="Trading schedule setting">
                  <div class="settings-label">Trading schedule</div>
                  <div class="schedule-settings-inline">
                    <button type="button" class="settings-preview-btn" @click="openScheduleSettings">Scheldule settings</button>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div :class="['global-save-alert', showSavedAlert ? 'is-visible' : '']" role="status" aria-live="polite">
            {{ message || 'Settings setting changed name and value, saved' }}
          </div>
        </section>

        <section class="right-column">
          <header class="bot-header">
            <h2 class="wallet-title mb-0">
              <span class="wallet-mark">B</span><span class="wallet-text">YBIT</span><span class="bot-title-suffix"> trading bot</span>
            </h2>
            <div class="bot-actions" aria-label="Bot controls">
              <button type="button" class="bot-action-btn" @click="openRestartConfirm">Restart Sys</button>
              <button type="button" class="bot-action-btn" @click="start">Start BOT</button>
              <button type="button" class="bot-action-btn" @click="stop">Stop BOT</button>
            </div>
            <div class="bot-status" aria-label="Bot status list">
              <span :class="['bot-status-item', statusMode === 'scaning' ? 'bot-status-item-active' : '']">scaning</span>
              <span :class="['bot-status-item', statusMode === 'paused' ? 'bot-status-item-active' : '']">paused</span>
              <span :class="['bot-status-item', statusMode === 'stoped' ? 'bot-status-item-active' : '']">stoped</span>
              <span v-if="showTradingDayEnded" class="bot-status-note">Trading day ended</span>
            </div>
          </header>

          <section class="signals-carousel" aria-label="Signals carousel">
            <div class="signals-carousel-head">
              <div class="signals-carousel-title">
                Signals
                <span class="signals-title-meta" v-if="lastOpenedSignal">
                  | last opened signal: {{ lastOpenedSignal.instrument }} {{ lastOpenedSignal.lev.toFixed(1) }}x {{ lastOpenedSignal.direction }} {{ lastOpenedSignal.score }}
                </span>
                <span class="signals-title-meta" v-else>
                  | last opened signal: n/a
                </span>
              </div>
              <div class="signals-carousel-controls">
                <button type="button" class="signals-nav-btn" aria-label="Previous signals" @click="scrollSignals(-1)">&#8249;</button>
                <button type="button" class="signals-nav-btn" aria-label="Next signals" @click="scrollSignals(1)">&#8250;</button>
              </div>
            </div>

            <div class="signals-viewport" ref="signalsViewport">
              <article class="signal-card" v-for="card in signalCards" :key="card.symbol">
                <div class="signal-card-top">
                  <div class="signal-card-pair">{{ card.symbol }}</div>
                </div>
                <div class="signal-card-center">
                  <span :class="['signal-direction', card.verdict === 'LONG' ? 'signal-direction-long' : card.verdict === 'SHORT' ? 'signal-direction-short' : '']">{{ card.verdict }}</span>
                  <span class="signal-stats">L{{ card.long }} | S{{ card.short }}</span>
                </div>
              </article>
            </div>
          </section>

          <section class="orders-block" aria-label="Orders table">
            <div class="orders-title">
              <span class="orders-title-main">Orders</span>
              <span class="orders-title-sep">|</span>
              <span class="orders-title-settings-label">Trading settings:</span>
              <span class="orders-title-settings">TP {{ Number(settings.tp_percent).toFixed(1) }}% - SL {{ Number(settings.sl_percent).toFixed(1) }}% - Auto close on: {{ settings.close_on_pnl_mode === 'total' ? 'Total PnL' : 'Safe PnL' }} {{ Number(settings.close_on_safe_pnl).toFixed(0) }} - RPO {{ Number(settings.risk_percent_per_order).toFixed(1) }}% - Leverage {{ Number(settings.leverage).toFixed(1) }}x - {{ settings.max_open_orders }} Max orders - TOP {{ settings.top_pairs_limit }} trade - Schedule {{ settings.trading_schedule }}</span>
            </div>
            <div class="orders-table-wrap">
              <table class="orders-table">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Pair</th>
                    <th>Direction</th>
                    <th>Lev</th>
                    <th>Entry</th>
                    <th>Mark</th>
                    <th>TP / SL</th>
                    <th>Safe PnL</th>
                    <th>PnL</th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-if="stableOrders.length === 0">
                    <td colspan="9">Нет открытых позиций</td>
                  </tr>
                  <tr v-for="(o, idx) in stableOrders" :key="o.id" :class="o.sl_net_pnl_after_fees > 0 ? 'safe-pnl-positive-row' : ''">
                    <td class="orders-id-cell"><span class="orders-id-diamond">{{ idx + 1 }}</span></td>
                    <td>
                      <span>{{ o.symbol }}</span>
                      <span v-if="o.reverse_source" :class="['reverse-badge', o.reverse_source === 'adverse_move' ? 'rev-adv' : 'rev-sl', (o.side === 'Buy' || o.side === 'Long') ? 'rev-from-buy' : 'rev-from-sell']">{{ o.reverse_source === 'adverse_move' ? 'ADV' : 'SL' }}</span>
                    </td>
                    <td :class="['orders-dir', (o.side === 'Buy' || o.side === 'Long') ? 'orders-dir-long' : 'orders-dir-short']">{{ (o.side === 'Buy' || o.side === 'Long') ? 'BUY' : 'SEL' }}</td>
                    <td>{{ o.leverage.toFixed(1) }}x</td>
                    <td>{{ o.price.toFixed(4) }}</td>
                    <td>{{ o.mark_price.toFixed(4) }}</td>
                    <td>
                      <span class="orders-tp">{{ o.take_profit.toFixed(4) }}</span>
                      <span class="orders-sep"> / </span>
                      <span class="orders-sl">{{ o.stop_loss.toFixed(4) }}</span>
                    </td>
                    <td :class="o.sl_net_pnl_after_fees < 0 ? 'safe-pnl-negative' : ''">{{ o.sl_net_pnl_after_fees > 0 ? o.sl_net_pnl_after_fees.toFixed(2) : '--' }}</td>
                    <td :class="o.pnl >= 0 ? 'orders-pnl-positive' : 'orders-pnl-negative'">{{ o.pnl.toFixed(2) }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section class="history-block" aria-label="History">
            <div class="history-title">History</div>
            <div class="history-list">
              <div class="history-item" v-for="(t, idx) in recentClosedHistory" :key="idx">
                <span class="history-pair">{{ t.symbol }}</span>
                <span class="history-lev">{{ t.leverage.toFixed(1) }}x</span>
                <span :class="['history-pnl', t.pnl >= 0 ? 'history-pnl-positive' : 'history-pnl-negative']">{{ t.pnl.toFixed(2) }}</span>
              </div>
            </div>
          </section>
        </section>
      </div>

      <Teleport to="body">
        <div v-if="showRestartConfirmModal" class="settings-preview-backdrop" @click.self="closeRestartConfirm">
          <section class="settings-preview-modal" aria-label="Restart system dialog">
            <header class="settings-preview-head">
              <h3 class="settings-preview-title">Restart System</h3>
              <button type="button" class="settings-preview-close" @click="closeRestartConfirm">Close</button>
            </header>
            <p class="schedule-editor-subtitle">
              Warning: this will fully restart bot runtime (stop + start), reinitialize scanning loop and reconnect runtime streams.
            </p>
            <div class="settings-preview-actions">
              <button type="button" class="settings-preview-btn" @click="closeRestartConfirm">Cancel</button>
              <button type="button" class="settings-preview-btn" @click="restartSystem">Confirm Restart</button>
            </div>
          </section>
        </div>
      </Teleport>

      <Teleport to="body">
        <div v-if="showSettingsPreview" class="settings-preview-backdrop" @click.self="closeSettingsPreview">
          <section class="settings-preview-modal" aria-label="Settings preview dialog">
            <header class="settings-preview-head">
              <h3 class="settings-preview-title">Trading Settings Calendar</h3>
              <button type="button" class="settings-preview-close" @click="closeSettingsPreview">Close</button>
            </header>

            <div class="settings-preview-cards">
              <article class="settings-preview-card">
                <div class="settings-preview-label">Take Profit</div>
                <div class="settings-preview-value">{{ Number(settings.tp_percent).toFixed(1) }}%</div>
              </article>
              <article class="settings-preview-card">
                <div class="settings-preview-label">Stop Loss</div>
                <div class="settings-preview-value">{{ Number(settings.sl_percent).toFixed(1) }}%</div>
              </article>
              <article class="settings-preview-card">
                <div class="settings-preview-label">Risk / Order</div>
                <div class="settings-preview-value">{{ Number(settings.risk_percent_per_order).toFixed(1) }}%</div>
              </article>
              <article class="settings-preview-card">
                <div class="settings-preview-label">Leverage</div>
                <div class="settings-preview-value">{{ Number(settings.leverage).toFixed(1) }}x</div>
              </article>
              <article class="settings-preview-card">
                <div class="settings-preview-label">Max Orders</div>
                <div class="settings-preview-value">{{ settings.max_open_orders }}</div>
              </article>
              <article class="settings-preview-card">
                <div class="settings-preview-label">Top Pairs</div>
                <div class="settings-preview-value">{{ settings.top_pairs_limit }}</div>
              </article>
            </div>

            <div class="settings-calendar-grid">
              <article
                v-for="row in scheduleCalendarRows"
                :key="row.key"
                :class="['settings-calendar-day', row.enabled ? 'settings-calendar-on' : 'settings-calendar-off', row.validRange ? '' : 'settings-calendar-invalid']"
              >
                <div class="settings-calendar-name">{{ row.label }}</div>
                <div class="settings-calendar-state">{{ row.enabled ? 'Trading ON' : 'Trading OFF' }}</div>
                <div class="settings-calendar-time">{{ row.rangeText }}</div>
              </article>
            </div>

            <div class="settings-calendar-raw">{{ settings.trading_schedule }}</div>
          </section>
        </div>
      </Teleport>

      <Teleport to="body">
        <div v-if="showScheduleSettingsModal" class="settings-preview-backdrop" @click.self="closeScheduleSettings">
          <section class="settings-preview-modal schedule-editor-modal" aria-label="Schedule settings dialog">
            <header class="settings-preview-head">
              <h3 class="settings-preview-title">Scheldule settings</h3>
              <button type="button" class="settings-preview-close" @click="closeScheduleSettings">Close</button>
            </header>

            <p class="schedule-editor-subtitle">Changes are autosaved. Toggle days and set time ranges directly on calendar cards.</p>

            <div class="schedule-editor-presets">
              <button type="button" class="schedule-preset-btn" @click="applySchedulePreset('workweek')">Mon-Sat</button>
              <button type="button" class="schedule-preset-btn" @click="applySchedulePreset('everyday')">Every day</button>
              <button type="button" class="schedule-preset-btn" @click="applySchedulePreset('alloff')">All OFF</button>
            </div>

            <div class="schedule-editor-calendar">
              <article
                v-for="row in scheduleEditorCalendarRows"
                :key="`schedule-editor-${row.key}`"
                :class="['schedule-editor-day', row.enabled ? 'schedule-editor-day-on' : 'schedule-editor-day-off', row.validRange ? '' : 'schedule-editor-day-invalid']"
              >
                <div class="schedule-editor-day-head">
                  <h4 class="schedule-editor-day-name">{{ row.label }}</h4>
                  <label class="mode-option schedule-editor-toggle" :for="`dayEnabledModal${row.key}`">
                    <input :id="`dayEnabledModal${row.key}`" type="checkbox" class="schedule-editor-toggle-input" v-model="dailySchedule[row.key].enabled" @change="onScheduleEditorChange" />
                    <span>{{ row.enabled ? 'ON' : 'OFF' }}</span>
                  </label>
                </div>

                <div class="schedule-editor-time-grid">
                  <div class="schedule-editor-time-item">
                    <span class="schedule-editor-time-label">From</span>
                    <div class="schedule-time-control">
                      <button
                        type="button"
                        class="schedule-time-btn"
                        :disabled="!dailySchedule[row.key].enabled"
                        @click="shiftDayTime(row.key, 'start', -15)"
                      >
                        -15m
                      </button>
                      <div class="schedule-time-dropdown" @click.stop>
                        <button
                          type="button"
                          class="settings-input schedule-time-select schedule-time-select-btn"
                          :disabled="!dailySchedule[row.key].enabled"
                          @click="toggleTimeDropdown(row.key, 'start', 'hour', !dailySchedule[row.key].enabled, $event)"
                        >
                          {{ getTimePart(dailySchedule[row.key].start, 'hour') }}
                        </button>
                      </div>
                      <span class="schedule-time-sep">:</span>
                      <div class="schedule-time-dropdown" @click.stop>
                        <button
                          type="button"
                          class="settings-input schedule-time-select schedule-time-select-btn"
                          :disabled="!dailySchedule[row.key].enabled"
                          @click="toggleTimeDropdown(row.key, 'start', 'minute', !dailySchedule[row.key].enabled, $event)"
                        >
                          {{ getTimePart(dailySchedule[row.key].start, 'minute') }}
                        </button>
                      </div>
                      <button
                        type="button"
                        class="schedule-time-btn"
                        :disabled="!dailySchedule[row.key].enabled"
                        @click="shiftDayTime(row.key, 'start', 15)"
                      >
                        +15m
                      </button>
                    </div>
                  </div>

                  <div class="schedule-editor-time-item">
                    <span class="schedule-editor-time-label">To</span>
                    <div class="schedule-time-control">
                      <button
                        type="button"
                        class="schedule-time-btn"
                        :disabled="!dailySchedule[row.key].enabled"
                        @click="shiftDayTime(row.key, 'end', -15)"
                      >
                        -15m
                      </button>
                      <div class="schedule-time-dropdown" @click.stop>
                        <button
                          type="button"
                          class="settings-input schedule-time-select schedule-time-select-btn"
                          :disabled="!dailySchedule[row.key].enabled"
                          @click="toggleTimeDropdown(row.key, 'end', 'hour', !dailySchedule[row.key].enabled, $event)"
                        >
                          {{ getTimePart(dailySchedule[row.key].end, 'hour') }}
                        </button>
                      </div>
                      <span class="schedule-time-sep">:</span>
                      <div class="schedule-time-dropdown" @click.stop>
                        <button
                          type="button"
                          class="settings-input schedule-time-select schedule-time-select-btn"
                          :disabled="!dailySchedule[row.key].enabled"
                          @click="toggleTimeDropdown(row.key, 'end', 'minute', !dailySchedule[row.key].enabled, $event)"
                        >
                          {{ getTimePart(dailySchedule[row.key].end, 'minute') }}
                        </button>
                      </div>
                      <button
                        type="button"
                        class="schedule-time-btn"
                        :disabled="!dailySchedule[row.key].enabled"
                        @click="shiftDayTime(row.key, 'end', 15)"
                      >
                        +15m
                      </button>
                    </div>
                  </div>
                </div>

                <div class="schedule-editor-day-status">
                  {{ row.enabled ? (row.validRange ? `${dailySchedule[row.key].start} - ${dailySchedule[row.key].end}` : 'Invalid range') : 'No trading this day' }}
                </div>
              </article>
            </div>

            <div class="settings-calendar-raw">{{ settings.trading_schedule }}</div>
          </section>
        </div>
      </Teleport>

      <Teleport to="body">
        <div v-if="activeTimeDropdownInfo" class="schedule-time-menu-portal" :style="activeTimeDropdownStyle" @click.stop>
          <button
            v-for="opt in activeTimeDropdownOptions"
            :key="`active-time-opt-${opt}`"
            type="button"
            class="schedule-time-menu-item"
            :class="activeTimeDropdownValue === opt ? 'is-active' : ''"
            @click="selectTimeDropdownValue(activeTimeDropdownInfo.dayKey, activeTimeDropdownInfo.field, activeTimeDropdownInfo.part, opt)"
          >
            {{ opt }}
          </button>
        </div>
      </Teleport>

      <Teleport to="body">
        <div v-if="showStatsModal" class="settings-preview-backdrop" @click.self="closeStatsModal">
          <section class="settings-preview-modal stats-modal" aria-label="PNL stats dialog">
            <header class="settings-preview-head">
              <h3 class="settings-preview-title">PNL by Days</h3>
              <button type="button" class="settings-preview-close" @click="closeStatsModal">Close</button>
            </header>

            <div class="stats-filters">
              <label class="stats-filter-label">
                <span>Month</span>
                <select class="settings-input stats-filter-select" v-model.number="selectedStatsMonth" @change="onStatsMonthChange">
                  <option v-for="m in availableStatsMonthOptions" :key="`stats-m-${m.value}`" :value="m.value">{{ m.label }}</option>
                </select>
              </label>
              <label class="stats-filter-label">
                <span>Year</span>
                <select class="settings-input stats-filter-select" v-model.number="selectedStatsYear" @change="onStatsYearChange">
                  <option v-for="y in statsYearOptions" :key="`stats-y-${y}`" :value="y">{{ y }}</option>
                </select>
              </label>
              <div class="stats-avg-box">
                <span class="stats-avg-label">Avg PnL/day</span>
                <span class="stats-avg-value" :class="statsAveragePnlPerDay >= 0 ? 'is-positive' : 'is-negative'">
                  {{ statsAveragePnlPerDay.toFixed(2) }}
                </span>
              </div>
            </div>

            <div class="stats-week-tabs">
              <button
                v-for="tab in statsWeekTabs"
                :key="`stats-tab-${tab.week}`"
                type="button"
                class="stats-week-tab"
                :class="selectedStatsWeek === tab.week ? 'is-active' : ''"
                @click="selectedStatsWeek = tab.week"
              >
                W{{ tab.week }}
              </button>
            </div>

            <div class="stats-chart-wrap">
              <div class="stats-chart-grid" aria-hidden="true"></div>
              <div class="stats-axis-head" aria-hidden="true">
                <div class="stats-axis-side stats-axis-side-left">
                  <span v-for="tick in statsAxisTicks" :key="`axis-left-${tick}`">-{{ tick }}</span>
                </div>
                <div class="stats-axis-zero">0</div>
                <div class="stats-axis-side stats-axis-side-right">
                  <span v-for="tick in statsAxisTicks" :key="`axis-right-${tick}`">+{{ tick }}</span>
                </div>
              </div>

              <div class="stats-rows">
                <div class="stats-row" v-for="row in statsVisibleDailyRows" :key="`stats-day-${row.day}`" :title="`Day ${row.day}: ${row.pnl.toFixed(2)}`">
                  <div class="stats-half stats-half-left">
                    <div v-if="row.pnl < 0" class="stats-hbar stats-hbar-negative" :style="{ width: `${row.widthPct}%` }">
                      <span class="stats-hbar-value">{{ row.pnl.toFixed(2) }}</span>
                    </div>
                  </div>
                  <div class="stats-row-axis"></div>
                  <div class="stats-half stats-half-right">
                    <div v-if="row.pnl >= 0" class="stats-hbar stats-hbar-positive" :style="{ width: `${row.widthPct}%` }">
                      <span class="stats-hbar-value">+{{ row.pnl.toFixed(2) }}</span>
                    </div>
                  </div>
                  <div class="stats-day-label">{{ String(row.day).padStart(2, '0') }}</div>
                </div>
              </div>
            </div>
          </section>
        </div>
      </Teleport>
    </main>

    <main v-else class="container-fluid px-0 skeleton-shell" aria-live="polite" aria-busy="true">
      <div class="app-layout d-flex flex-column flex-lg-row min-vh-100">
        <section class="left-column p-4 p-md-5 d-flex flex-column justify-content-between">
          <div class="skeleton-block skeleton-wallet"></div>
          <div class="skeleton-block skeleton-api"></div>
          <div class="skeleton-block skeleton-settings"></div>
        </section>
        <section class="right-column p-4 p-md-5">
          <div class="skeleton-block skeleton-header"></div>
          <div class="skeleton-block skeleton-signals"></div>
          <div class="skeleton-block skeleton-orders"></div>
          <div class="skeleton-block skeleton-history"></div>
        </section>
      </div>
    </main>
  </div>
</template>
