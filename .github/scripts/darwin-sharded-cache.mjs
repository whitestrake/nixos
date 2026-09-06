#!/usr/bin/env node

import { chmod, copyFile, lstat, link, mkdir, readFile, readdir, readlink, symlink, unlink, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';

const fail = message => { throw new Error(message); };
const mode = stat => stat.mode & 0o7777;
const cacheRoles = ['metadata', 'band-1', 'band-2', 'band-3'];

function inside(root, path) {
  const rel = relative(resolve(root), resolve(path));
  return rel === '' || (!rel.startsWith(`..${sep}`) && rel !== '..');
}

async function entries(root, prefix = '') {
  const result = [];
  for (const name of (await readdir(join(root, prefix))).sort()) {
    const rel = join(prefix, name);
    const stat = await lstat(join(root, rel));
    if (stat.isDirectory()) {
      result.push({ path: rel, type: 'directory', mode: mode(stat) });
      result.push(...await entries(root, rel));
    } else if (stat.isFile()) {
      result.push({ path: rel, type: 'file', size: stat.size, mode: mode(stat) });
    } else if (stat.isSymbolicLink()) {
      result.push({ path: rel, type: 'symlink', target: await readlink(join(root, rel)), mode: mode(stat) });
    } else {
      fail(`unsupported sparsebundle entry: ${rel}`);
    }
  }
  return result;
}

async function cloneEntry(sourceRoot, destinationRoot, entry) {
  const source = join(sourceRoot, entry.path);
  const destination = join(destinationRoot, entry.path);
  if (entry.type === 'directory') {
    await mkdir(destination, { recursive: true, mode: entry.mode });
    await chmod(destination, entry.mode);
  } else if (entry.type === 'symlink') {
    await mkdir(dirname(destination), { recursive: true });
    await symlink(entry.target, destination);
  } else {
    await mkdir(dirname(destination), { recursive: true });
    try {
      await link(source, destination);
    } catch (error) {
      if (error.code !== 'EXDEV') throw error;
      await copyFile(source, destination);
    }
    await chmod(destination, entry.mode);
  }
}

function allocateBands(bands) {
  if (bands.length < 3) fail('the sparsebundle needs at least three allocated bands');
  const total = bands.reduce((sum, entry) => sum + entry.size, 0);
  const limits = [total / 6, total / 2];
  const groups = [[], [], []];
  let bytes = 0;
  for (const band of bands) {
    const index = bytes < limits[0] ? 0 : bytes < limits[1] ? 1 : 2;
    groups[index].push(band);
    bytes += band.size;
  }
  if (groups.some(group => group.length === 0)) fail('could not create three non-empty band groups');
  return groups;
}

function cachePath(payloadRoot, role) {
  return join(payloadRoot, role);
}

async function split([source, payloadRoot, manifestPath, generation, sourceKey, sourceId, sourceVersion, sourceBytes]) {
  if (!source || !payloadRoot || !manifestPath || !generation || !sourceKey || !sourceId || !sourceVersion || !sourceBytes) {
    fail('split requires source, payload root, manifest, generation, source key, source ID, source version and source bytes');
  }
  if ((await lstat(source)).isDirectory() === false) fail(`sparsebundle is not a directory: ${source}`);
  try { await lstat(payloadRoot); fail(`payload root already exists: ${payloadRoot}`); } catch (error) { if (error.code !== 'ENOENT') throw error; }

  const all = await entries(source);
  const bands = all.filter(entry => entry.type === 'file' && dirname(entry.path) === 'bands');
  if (bands.length !== all.filter(entry => entry.path.startsWith(`bands${sep}`) && entry.type !== 'directory').length) {
    fail('bands must contain only regular files');
  }
  const metadata = all.filter(entry => entry.path !== 'bands' && !entry.path.startsWith(`bands${sep}`));
  const groups = allocateBands(bands);
  const roleEntries = { metadata };
  groups.forEach((group, index) => {
    roleEntries[`band-${index + 1}`] = [
      { path: 'bands', type: 'directory', mode: all.find(entry => entry.path === 'bands')?.mode ?? 0o755 },
      ...group,
    ];
  });

  for (const role of cacheRoles) {
    const bundleRoot = join(cachePath(payloadRoot, role), 'nix-root.sparsebundle');
    await mkdir(bundleRoot, { recursive: true });
    for (const entry of roleEntries[role]) await cloneEntry(source, bundleRoot, entry);
  }

  const keyPrefix = `darwin-shards-v1-${generation}`;
  const caches = cacheRoles.map(role => ({
    role,
    key: `${keyPrefix}-${role}`,
    path: cachePath(payloadRoot, role),
    entries: roleEntries[role],
    payloadBytes: roleEntries[role].reduce((sum, entry) => sum + (entry.size ?? 0), 0),
  }));
  const manifest = {
    schema: 'darwin-sharded-sparsebundle-v1',
    generation,
    sourceCache: { key: sourceKey, id: Number(sourceId), version: sourceVersion, archiveBytes: Number(sourceBytes) },
    cacheContract: { toolkit: '@actions/cache', version: '6.1.0', bandDownloadConcurrency: [2, 3, 3] },
    manifestCache: { key: `${keyPrefix}-manifest`, path: dirname(manifestPath) },
    caches,
  };
  await mkdir(dirname(manifestPath), { recursive: true });
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

async function loadManifest(path) {
  const manifest = JSON.parse(await readFile(path, 'utf8'));
  if (manifest.schema !== 'darwin-sharded-sparsebundle-v1') fail('unexpected manifest schema');
  if (!/^[1-9][0-9]*-[1-9][0-9]*$/.test(manifest.generation)) fail('unsafe manifest generation');
  if (JSON.stringify(manifest.caches?.map(cache => cache.role)) !== JSON.stringify(cacheRoles)) fail('unexpected cache roles');
  if (manifest.cacheContract?.toolkit !== '@actions/cache' || manifest.cacheContract?.version !== '6.1.0') {
    fail('unexpected cache toolkit contract');
  }
  if (JSON.stringify(manifest.cacheContract.bandDownloadConcurrency) !== JSON.stringify([2, 3, 3])) {
    fail('unexpected cache download concurrency');
  }
  const keyPrefix = `darwin-shards-v1-${manifest.generation}`;
  if (manifest.manifestCache?.key !== `${keyPrefix}-manifest`) fail('manifest cache key is not bound to its generation');
  for (const cache of manifest.caches) {
    if (cache.key !== `${keyPrefix}-${cache.role}`) fail(`cache key is not bound to generation: ${cache.role}`);
    if (!Number.isSafeInteger(cache.id) && cache.id !== undefined) fail(`invalid cache ID for ${cache.role}`);
    const paths = new Set();
    for (const entry of cache.entries ?? []) {
      if (!entry.path || isAbsolute(entry.path) || entry.path.split(sep).includes('..')) {
        fail(`unsafe manifest entry for ${cache.role}`);
      }
      if (paths.has(entry.path)) fail(`duplicate manifest entry for ${cache.role}: ${entry.path}`);
      paths.add(entry.path);
    }
  }
  if (process.env.RUNNER_TEMP) {
    const expectedRoot = join(process.env.RUNNER_TEMP, 'darwin-shards', 'payloads');
    for (const cache of manifest.caches) {
      if (!inside(expectedRoot, cache.path) || cache.path !== cachePath(expectedRoot, cache.role)) {
        fail(`unsafe cache path for ${cache.role}`);
      }
    }
  }
  const expectedSource = [
    ['SOURCE_CACHE_KEY', 'key'],
    ['SOURCE_CACHE_ID', 'id'],
    ['SOURCE_CACHE_VERSION', 'version'],
    ['SOURCE_CACHE_SIZE', 'archiveBytes'],
  ];
  for (const [variable, field] of expectedSource) {
    if (process.env[variable] !== undefined && String(manifest.sourceCache?.[field]) !== process.env[variable]) {
      fail(`source cache ${field} does not match ${variable}`);
    }
  }
  return manifest;
}

async function finalise([manifestPath, inventoryPath]) {
  const manifest = await loadManifest(manifestPath);
  const inventory = JSON.parse(await readFile(inventoryPath, 'utf8'));
  for (const cache of manifest.caches) {
    const matches = inventory.filter(entry => entry.key === cache.key);
    if (matches.length !== 1) fail(`expected one saved cache for ${cache.key}, found ${matches.length}`);
    const saved = matches[0];
    if (!saved.id || !saved.version || !saved.sizeInBytes) fail(`saved cache metadata is incomplete for ${cache.key}`);
    cache.id = Number(saved.id);
    cache.version = saved.version;
    cache.archiveBytes = Number(saved.sizeInBytes);
  }
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

async function preflight([manifestPath, inventoryPath]) {
  const manifest = await loadManifest(manifestPath);
  const inventory = JSON.parse(await readFile(inventoryPath, 'utf8'));
  for (const cache of manifest.caches) {
    const matches = inventory.filter(entry => entry.key === cache.key);
    if (matches.length !== 1) fail(`expected one live cache for ${cache.key}, found ${matches.length}`);
    const live = matches[0];
    if (Number(live.id) !== cache.id || live.version !== cache.version || Number(live.sizeInBytes) !== cache.archiveBytes) {
      fail(`live cache identity changed for ${cache.key}`);
    }
  }
}

async function restore([manifestPath, telemetryPath]) {
  const manifest = await loadManifest(manifestPath);
  const modulePath = process.env.ACTIONS_CACHE_MODULE;
  if (!modulePath) fail('ACTIONS_CACHE_MODULE is required');
  const { restoreCache } = await import(modulePath);
  const attempts = [];
  const restoreOne = async (cache, downloadConcurrency) => {
    for (let attempt = 1; attempt <= 2; attempt++) {
      const startedAt = Date.now();
      try {
        const matchedKey = await restoreCache(
          [cache.path],
          cache.key,
          [],
          { downloadConcurrency, concurrentBlobDownloads: true },
        );
        attempts.push({ role: cache.role, attempt, startedAt, endedAt: Date.now(), matchedKey });
        if (matchedKey !== cache.key) fail(`cache ${cache.role} returned ${matchedKey ?? 'no key'}`);
        return;
      } catch (error) {
        attempts.push({ role: cache.role, attempt, startedAt, endedAt: Date.now(), error: String(error.message ?? error) });
        if (attempt === 2) throw error;
      }
    }
  };
  const metadata = manifest.caches[0];
  const metadataResult = await Promise.allSettled([restoreOne(metadata, 1)]);
  const results = metadataResult[0].status === 'fulfilled'
    ? await Promise.allSettled(manifest.caches.slice(1).map((cache, index) =>
      restoreOne(cache, manifest.cacheContract.bandDownloadConcurrency[index])))
    : metadataResult;
  await writeFile(telemetryPath, `${JSON.stringify({ attempts }, null, 2)}\n`);
  const failures = results.filter(result => result.status === 'rejected');
  if (failures.length) fail(`${failures.length} shard restore(s) failed after two attempts`);
}

async function validateTree(root, expected) {
  const byPath = (left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0;
  const actual = (await entries(root)).sort(byPath);
  if (JSON.stringify(actual) !== JSON.stringify([...expected].sort(byPath))) fail(`restored entry coverage differs under ${root}`);
}

async function assemble([manifestPath, destination]) {
  const manifest = await loadManifest(manifestPath);
  try { await lstat(destination); fail(`assembly destination already exists: ${destination}`); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  await mkdir(destination, { recursive: true });
  const seen = new Set();
  for (const cache of manifest.caches) {
    const bundleRoot = join(cache.path, 'nix-root.sparsebundle');
    await validateTree(bundleRoot, cache.entries);
    for (const entry of cache.entries) {
      if (entry.path === 'bands' && entry.type === 'directory') continue;
      if (seen.has(entry.path)) fail(`overlapping manifest entry: ${entry.path}`);
      seen.add(entry.path);
      await cloneEntry(bundleRoot, destination, entry);
    }
  }
  const expected = manifest.caches.flatMap(cache => cache.entries)
    .filter((entry, index, all) => all.findIndex(candidate => candidate.path === entry.path) === index);
  await validateTree(destination, expected);
}

async function selfTest() {
  const { mkdtemp } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const root = await mkdtemp(join(tmpdir(), 'darwin-shards-'));
  const source = join(root, 'source.sparsebundle');
  await mkdir(join(source, 'bands'), { recursive: true });
  await writeFile(join(source, 'Info.plist'), 'metadata');
  for (let index = 0; index < 12; index++) await writeFile(join(source, 'bands', index.toString(16)), 'x'.repeat(index + 1));
  const payload = join(root, 'payloads');
  const manifest = join(root, 'manifest', 'manifest.json');
  await split([source, payload, manifest, '1-1', 'source', '1', 'version', '10']);
  const draft = await loadManifest(manifest);
  const inventory = join(root, 'inventory.json');
  await writeFile(inventory, JSON.stringify(draft.caches.map((cache, index) => ({
    id: index + 1,
    key: cache.key,
    sizeInBytes: index + 10,
    version: `version-${index}`,
  }))));
  await finalise([manifest, inventory]);
  await preflight([manifest, inventory]);
  const parsed = await loadManifest(manifest);
  if (new Set(parsed.caches.flatMap(cache => cache.entries.filter(entry => entry.type === 'file').map(entry => entry.path))).size !== 13) {
    fail('self-test lost or duplicated files');
  }
  const bandBytes = parsed.caches.slice(1).map(cache => cache.payloadBytes);
  if (!(bandBytes[0] < bandBytes[1] && bandBytes[1] < bandBytes[2])) fail('self-test band groups are not unequal');
  await assemble([manifest, join(root, 'assembled.sparsebundle')]);
  const missingBand = parsed.caches[1].entries.find(entry => entry.type === 'file').path;
  await unlink(join(parsed.caches[1].path, 'nix-root.sparsebundle', missingBand));
  let rejectedMissingBand = false;
  try {
    await assemble([manifest, join(root, 'incomplete.sparsebundle')]);
  } catch {
    rejectedMissingBand = true;
  }
  if (!rejectedMissingBand) fail('self-test accepted a missing allocated band');
}

const [command, ...args] = process.argv.slice(2);
const commands = { assemble, finalise, preflight, restore, 'self-test': selfTest, split };
if (!commands[command]) fail(`unknown command: ${command ?? ''}`);
await commands[command](args);
