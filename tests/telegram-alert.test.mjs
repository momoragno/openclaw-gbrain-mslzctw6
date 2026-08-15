import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { deliverAlert } from '../scripts/telegram-alert.mjs';

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
    const first = await deliverAlert({ message: 'line one\nline two', env, fetchImpl });
    assert.equal(first, 'delivered');
    assert.equal(received.length, 1);
    assert.equal(received[0].url, 'https://telegram.invalid/bottest-token/sendMessage');
    assert.equal(received[0].body.chat_id, '123456');
    assert.equal(received[0].body.text, 'line one\nline two');

    const second = await deliverAlert({ message: 'line one\nline two', env, fetchImpl });
    assert.equal(second, 'suppressed');
    assert.equal(received.length, 1);
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
        fetchImpl: async () => ({ ok: false, status: 503 }),
      }),
      /HTTP 503/,
    );
    const retry = await deliverAlert({
      message: 'retry me',
      env,
      fetchImpl: async () => ({ ok: true, status: 200 }),
    });
    assert.equal(retry, 'delivered');
  } finally {
    await rm(testRoot, { recursive: true, force: true });
  }
});
