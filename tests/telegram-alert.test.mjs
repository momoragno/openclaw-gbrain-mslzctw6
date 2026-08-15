import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import {
  deliverAlert,
  drainPendingAlerts,
  isQuietHours,
} from '../scripts/telegram-alert.mjs';

const DAYTIME = new Date('2026-08-15T10:00:00.000Z');

test('delivers once and suppresses an identical alert during cooldown', async () => {
  const testRoot = await mkdtemp(path.join(os.tmpdir(), 'gbrain-alert-'));
  const stateDir = path.join(testRoot, 'state');
  const configPath = path.join(testRoot, 'openclaw.json');
  const allowFromPath = path.join(testRoot, 'allowFrom.json');
  await mkdir(stateDir);
  await writeFile(configPath, JSON.stringify({ channels: { telegram: { botToken: 'test-token' } } }));
  await writeFile(allowFromPath, JSON.stringify({ allowFrom: ['123456'] }));

  const received = [];
  const fetchImpl = async (url, options) => {
    received.push({ url, body: JSON.parse(options.body) });
    return { ok: true, status: 200 };
  };

  try {
    const env = {
      GBRAIN_MAINTENANCE_STATE_DIR: stateDir,
      OPENCLAW_CONFIG_PATH: configPath,
      TELEGRAM_ALLOW_FROM_PATH: allowFromPath,
      TELEGRAM_API_BASE_URL: 'https://telegram.invalid',
    };
    const first = await deliverAlert({ message: 'line one\nline two', env, fetchImpl, now: DAYTIME });
    assert.equal(first, 'delivered');
    assert.equal(received.length, 1);
    assert.equal(received[0].url, 'https://telegram.invalid/bottest-token/sendMessage');
    assert.equal(received[0].body.chat_id, '123456');
    assert.equal(received[0].body.text, 'line one\nline two');

    const second = await deliverAlert({ message: 'line one\nline two', env, fetchImpl, now: DAYTIME });
    assert.equal(second, 'suppressed');
    assert.equal(received.length, 1);
  } finally {
    await rm(testRoot, { recursive: true, force: true });
  }
});

test('resolves an OpenClaw environment placeholder before calling Telegram', async () => {
  const testRoot = await mkdtemp(path.join(os.tmpdir(), 'gbrain-alert-env-token-'));
  const stateDir = path.join(testRoot, 'state');
  const configPath = path.join(testRoot, 'openclaw.json');
  const allowFromPath = path.join(testRoot, 'allowFrom.json');
  const envPath = path.join(testRoot, '.env');
  await mkdir(stateDir);
  await writeFile(configPath, JSON.stringify({
    channels: { telegram: { botToken: '${TELEGRAM_BOT_TOKEN}' } },
  }));
  await writeFile(allowFromPath, JSON.stringify({ allowFrom: ['123456'] }));
  await writeFile(envPath, 'TELEGRAM_BOT_TOKEN=resolved-token\n');

  let requestedUrl;
  try {
    const result = await deliverAlert({
      message: 'resolved secret reference',
      env: {
        GBRAIN_MAINTENANCE_STATE_DIR: stateDir,
        OPENCLAW_CONFIG_PATH: configPath,
        TELEGRAM_ALLOW_FROM_PATH: allowFromPath,
        ALPHACLAW_ENV_PATH: envPath,
        TELEGRAM_API_BASE_URL: 'https://telegram.invalid',
      },
      fetchImpl: async (url) => {
        requestedUrl = url;
        return { ok: true, status: 200 };
      },
      now: DAYTIME,
    });
    assert.equal(result, 'delivered');
    assert.equal(requestedUrl, 'https://telegram.invalid/botresolved-token/sendMessage');
  } finally {
    await rm(testRoot, { recursive: true, force: true });
  }
});

test('does not consume cooldown when delivery fails', async () => {
  const testRoot = await mkdtemp(path.join(os.tmpdir(), 'gbrain-alert-failure-'));
  const stateDir = path.join(testRoot, 'state');
  const configPath = path.join(testRoot, 'openclaw.json');
  const allowFromPath = path.join(testRoot, 'allowFrom.json');
  await mkdir(stateDir);
  await writeFile(configPath, JSON.stringify({ channels: { telegram: { botToken: 'test-token' } } }));
  await writeFile(allowFromPath, JSON.stringify({ allowFrom: ['123456'] }));
  const env = {
    GBRAIN_MAINTENANCE_STATE_DIR: stateDir,
    OPENCLAW_CONFIG_PATH: configPath,
    TELEGRAM_ALLOW_FROM_PATH: allowFromPath,
  };

  try {
    await assert.rejects(
      deliverAlert({
        message: 'retry me',
        env,
        now: DAYTIME,
        fetchImpl: async () => ({ ok: false, status: 503 }),
      }),
      /HTTP 503/,
    );
    const retry = await deliverAlert({
      message: 'retry me',
      env,
      now: DAYTIME,
      fetchImpl: async () => ({ ok: true, status: 200 }),
    });
    assert.equal(retry, 'delivered');
  } finally {
    await rm(testRoot, { recursive: true, force: true });
  }
});

test('holds alerts during quiet hours and drains them in the morning', async () => {
  const testRoot = await mkdtemp(path.join(os.tmpdir(), 'gbrain-alert-quiet-'));
  const stateDir = path.join(testRoot, 'state');
  const configPath = path.join(testRoot, 'openclaw.json');
  const allowFromPath = path.join(testRoot, 'allowFrom.json');
  await mkdir(stateDir);
  await writeFile(configPath, JSON.stringify({ channels: { telegram: { botToken: 'test-token' } } }));
  await writeFile(allowFromPath, JSON.stringify({ allowFrom: ['123456'] }));
  const env = {
    GBRAIN_MAINTENANCE_STATE_DIR: stateDir,
    OPENCLAW_CONFIG_PATH: configPath,
    TELEGRAM_ALLOW_FROM_PATH: allowFromPath,
    GBRAIN_MAINTENANCE_TZ: 'Europe/Rome',
    GBRAIN_QUIET_HOURS_START: '23',
    GBRAIN_QUIET_HOURS_END: '8',
  };
  const received = [];
  const fetchImpl = async (_url, options) => {
    received.push(JSON.parse(options.body));
    return { ok: true, status: 200 };
  };

  try {
    const overnight = new Date('2026-08-15T01:15:00.000Z');
    assert.equal(isQuietHours({ env, now: overnight }), true);
    assert.equal(
      await deliverAlert({ message: 'wake me later', env, fetchImpl, now: overnight }),
      'queued',
    );
    assert.equal(
      await deliverAlert({ message: 'second diagnostic', env, fetchImpl, now: overnight }),
      'queued',
    );
    assert.equal(
      await deliverAlert({ message: 'wake me later', env, fetchImpl, now: overnight }),
      'queued',
    );
    assert.equal(received.length, 0);

    const morning = new Date('2026-08-15T06:15:00.000Z');
    assert.equal(isQuietHours({ env, now: morning }), false);
    assert.equal(await drainPendingAlerts({ env, fetchImpl, now: morning }), 'delivered');
    assert.equal(received.length, 2);
    assert.equal(received[0].text, 'wake me later');
    assert.equal(received[1].text, 'second diagnostic');
    assert.equal(await drainPendingAlerts({ env, fetchImpl, now: morning }), 'empty');
  } finally {
    await rm(testRoot, { recursive: true, force: true });
  }
});

test('keeps a held alert queued when morning delivery fails', async () => {
  const testRoot = await mkdtemp(path.join(os.tmpdir(), 'gbrain-alert-quiet-failure-'));
  const stateDir = path.join(testRoot, 'state');
  const configPath = path.join(testRoot, 'openclaw.json');
  const allowFromPath = path.join(testRoot, 'allowFrom.json');
  await mkdir(stateDir);
  await writeFile(configPath, JSON.stringify({ channels: { telegram: { botToken: 'test-token' } } }));
  await writeFile(allowFromPath, JSON.stringify({ allowFrom: ['123456'] }));
  const env = {
    GBRAIN_MAINTENANCE_STATE_DIR: stateDir,
    OPENCLAW_CONFIG_PATH: configPath,
    TELEGRAM_ALLOW_FROM_PATH: allowFromPath,
    GBRAIN_MAINTENANCE_TZ: 'UTC',
    GBRAIN_QUIET_HOURS_START: '23',
    GBRAIN_QUIET_HOURS_END: '8',
  };

  try {
    await deliverAlert({
      message: 'retry after breakfast',
      env,
      now: new Date('2026-08-15T02:00:00.000Z'),
      fetchImpl: async () => ({ ok: true, status: 200 }),
    });
    await assert.rejects(
      drainPendingAlerts({
        env,
        now: new Date('2026-08-15T09:00:00.000Z'),
        fetchImpl: async () => ({ ok: false, status: 503 }),
      }),
      /HTTP 503/,
    );
    assert.equal(
      await drainPendingAlerts({
        env,
        now: new Date('2026-08-15T09:15:00.000Z'),
        fetchImpl: async () => ({ ok: true, status: 200 }),
      }),
      'delivered',
    );
  } finally {
    await rm(testRoot, { recursive: true, force: true });
  }
});
