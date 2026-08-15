import { createHash } from 'node:crypto';
import { readFile, rename, writeFile, mkdir } from 'node:fs/promises';
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

export async function deliverAlert({ message, env = process.env, fetchImpl = globalThis.fetch }) {
  if (env.GBRAIN_TELEGRAM_ALERTS === 'false') return 'disabled';
  if (!message?.trim()) throw new Error('alert message is empty');

  const rootDir = env.ALPHACLAW_ROOT_DIR || '/data';
  const gbrainParent = env.GBRAIN_HOME || rootDir;
  const stateDir = env.GBRAIN_MAINTENANCE_STATE_DIR
    || path.join(gbrainParent, '.gbrain', 'maintenance');
  const configPath = env.OPENCLAW_CONFIG_PATH
    || path.join(rootDir, '.openclaw', 'openclaw.json');
  const allowFromPath = env.TELEGRAM_ALLOW_FROM_PATH
    || path.join(rootDir, '.openclaw', 'credentials', 'telegram-default-allowFrom.json');
  const cooldownSeconds = Number(env.GBRAIN_ALERT_COOLDOWN_SECONDS || 86_400);
  const telegramApiBaseUrl = env.TELEGRAM_API_BASE_URL || 'https://api.telegram.org';

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

async function main() {
  const result = await deliverAlert({ message: await readStdin() });
  if (result === 'suppressed') {
    console.log('[telegram-alert] duplicate alert suppressed by cooldown');
  } else if (result === 'delivered') {
    console.log('[telegram-alert] alert delivered');
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

