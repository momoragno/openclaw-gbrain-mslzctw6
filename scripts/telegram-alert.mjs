import { createHash } from 'node:crypto';
import {
  readFile,
  rename,
  writeFile,
  mkdir,
  unlink,
  rmdir,
  stat,
} from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8').trim();
}

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

function runtimePaths(env) {
  const rootDir = env.ALPHACLAW_ROOT_DIR || '/data';
  const gbrainParent = env.GBRAIN_HOME || rootDir;
  const stateDir = env.GBRAIN_MAINTENANCE_STATE_DIR
    || path.join(gbrainParent, '.gbrain', 'maintenance');
  return {
    stateDir,
    pendingPath: path.join(stateDir, 'pending-telegram-alert.json'),
    pendingLockPath: path.join(stateDir, 'pending-telegram-alert.lock'),
    configPath: env.OPENCLAW_CONFIG_PATH
      || path.join(rootDir, '.openclaw', 'openclaw.json'),
    allowFromPath: env.TELEGRAM_ALLOW_FROM_PATH
      || path.join(rootDir, '.openclaw', 'credentials', 'telegram-default-allowFrom.json'),
  };
}

function parseHour(value, fallback) {
  const parsed = Number(value ?? fallback);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 23) {
    throw new Error(`quiet-hours value must be an integer from 0 to 23; got ${value}`);
  }
  return parsed;
}

export function isQuietHours({ env = process.env, now = new Date() } = {}) {
  const start = parseHour(env.GBRAIN_QUIET_HOURS_START, 23);
  const end = parseHour(env.GBRAIN_QUIET_HOURS_END, 8);
  if (start === end) return false;
  const timeZone = env.GBRAIN_MAINTENANCE_TZ || 'Europe/Rome';
  const hour = Number(new Intl.DateTimeFormat('en-GB', {
    hour: '2-digit',
    hourCycle: 'h23',
    timeZone,
  }).format(now));
  return start < end
    ? hour >= start && hour < end
    : hour >= start || hour < end;
}

async function writeJsonAtomic(filePath, value) {
  await mkdir(path.dirname(filePath), { recursive: true });
  const temporaryPath = `${filePath}.${process.pid}.tmp`;
  await writeFile(temporaryPath, JSON.stringify(value));
  await rename(temporaryPath, filePath);
}

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function withPendingLock({ stateDir, pendingLockPath }, action) {
  await mkdir(stateDir, { recursive: true });
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      await mkdir(pendingLockPath);
      try {
        return await action();
      } finally {
        await rmdir(pendingLockPath).catch(() => {});
      }
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
      try {
        const lockAge = Date.now() - (await stat(pendingLockPath)).mtimeMs;
        if (lockAge > 300_000) {
          await rmdir(pendingLockPath);
          continue;
        }
      } catch (lockError) {
        if (lockError?.code !== 'ENOENT') throw lockError;
      }
      await delay(25);
    }
  }
  throw new Error('pending alert queue is locked');
}

function normalizePendingAlerts(value) {
  const items = Array.isArray(value) ? value : value?.message ? [value] : [];
  return items
    .filter((item) => typeof item?.message === 'string' && item.message.trim())
    .map((item) => ({
      ...item,
      fingerprint: item.fingerprint
        || createHash('sha256').update(item.message).digest('hex'),
    }));
}

async function queuePendingAlert(paths, message, now) {
  return withPendingLock(paths, async () => {
    let queue = [];
    try {
      queue = normalizePendingAlerts(await readJson(paths.pendingPath));
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    const fingerprint = createHash('sha256').update(message).digest('hex');
    if (!queue.some((item) => item.fingerprint === fingerprint)) {
      queue.push({ message, fingerprint, queuedAt: now.toISOString() });
      await writeJsonAtomic(paths.pendingPath, queue);
    }
  });
}

function resolveTarget(allowFrom, env) {
  if (env.GBRAIN_TELEGRAM_TARGET) return env.GBRAIN_TELEGRAM_TARGET;
  return (allowFrom || []).map(String).find((value) => /^-?\d+$/.test(value));
}

async function alertState(message, stateDir, cooldownSeconds) {
  const statePath = path.join(stateDir, 'telegram-alert-state.json');
  const fingerprint = createHash('sha256').update(message).digest('hex');
  try {
    const previous = await readJson(statePath);
    const ageSeconds = (Date.now() - Number(previous.sentAt || 0)) / 1000;
    if (previous.fingerprint === fingerprint && ageSeconds < cooldownSeconds) {
      return { fingerprint, statePath, suppressed: true };
    }
  } catch {
    // First alert or unreadable state: send it.
  }
  return { fingerprint, statePath, suppressed: false };
}

async function recordDelivered({ fingerprint, statePath }, stateDir) {
  await mkdir(stateDir, { recursive: true });
  const temporaryPath = `${statePath}.tmp`;
  await writeFile(temporaryPath, JSON.stringify({ fingerprint, sentAt: Date.now() }));
  await rename(temporaryPath, statePath);
}

export async function deliverAlert({
  message,
  env = process.env,
  fetchImpl = globalThis.fetch,
  now = new Date(),
  bypassQuietHours = false,
}) {
  if (env.GBRAIN_TELEGRAM_ALERTS === 'false') return 'disabled';
  if (!message?.trim()) throw new Error('alert message is empty');

  const paths = runtimePaths(env);
  const { stateDir, configPath, allowFromPath } = paths;
  const cooldownSeconds = Number(env.GBRAIN_ALERT_COOLDOWN_SECONDS || 86_400);
  const telegramApiBaseUrl = env.TELEGRAM_API_BASE_URL || 'https://api.telegram.org';

  if (!bypassQuietHours && isQuietHours({ env, now })) {
    await queuePendingAlert(paths, message.trim(), now);
    return 'queued';
  }

  const state = await alertState(message, stateDir, cooldownSeconds);
  if (state.suppressed) return 'suppressed';

  const [config, allowFromConfig] = await Promise.all([
    readJson(configPath),
    readJson(allowFromPath),
  ]);
  const token = config?.channels?.telegram?.botToken;
  const target = resolveTarget(allowFromConfig?.allowFrom, env);
  if (!token) throw new Error('Telegram bot token is not configured');
  if (!target) throw new Error('no numeric Telegram recipient is configured');

  const response = await fetchImpl(`${telegramApiBaseUrl}/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      chat_id: target,
      text: message.slice(0, 4000),
      disable_web_page_preview: true,
    }),
  });
  if (!response.ok) {
    throw new Error(`Telegram API returned HTTP ${response.status}`);
  }
  await recordDelivered(state, stateDir);
  return 'delivered';
}

export async function drainPendingAlerts({
  env = process.env,
  fetchImpl = globalThis.fetch,
  now = new Date(),
} = {}) {
  if (env.GBRAIN_TELEGRAM_ALERTS === 'false') return 'disabled';
  const paths = runtimePaths(env);
  return withPendingLock(paths, async () => {
    let queue;
    try {
      queue = normalizePendingAlerts(await readJson(paths.pendingPath));
    } catch (error) {
      if (error?.code === 'ENOENT') return 'empty';
      throw error;
    }
    if (queue.length === 0) return 'empty';
    if (isQuietHours({ env, now })) return 'quiet';

    let delivered = false;
    while (queue.length > 0) {
      const result = await deliverAlert({
        message: queue[0].message,
        env,
        fetchImpl,
        now,
        bypassQuietHours: true,
      });
      if (!['delivered', 'suppressed', 'disabled'].includes(result)) return result;
      delivered ||= result === 'delivered';
      queue.shift();
      if (queue.length > 0) {
        await writeJsonAtomic(paths.pendingPath, queue);
      } else {
        await unlink(paths.pendingPath).catch((error) => {
          if (error?.code !== 'ENOENT') throw error;
        });
      }
    }
    return delivered ? 'delivered' : 'suppressed';
  });
}

async function main() {
  const result = process.argv.includes('--drain')
    ? await drainPendingAlerts()
    : await deliverAlert({ message: await readStdin() });
  if (result === 'suppressed') {
    console.log('[telegram-alert] duplicate alert suppressed by cooldown');
  } else if (result === 'delivered') {
    console.log('[telegram-alert] alert delivered');
  } else if (result === 'queued') {
    console.log('[telegram-alert] alert held until quiet hours end');
  }
}

const isMain = process.argv[1]
  && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  main().catch((error) => {
    console.error(`[telegram-alert] ${error.message}`);
    process.exitCode = 1;
  });
}
