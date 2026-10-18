#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const arguments_ = process.argv.slice(2);
const offline = arguments_.includes('--offline');
const expectedVersionArguments = arguments_.filter(argument => argument.startsWith('--expected-version='));
const positionalArguments = arguments_.filter(argument => argument !== '--offline' && !argument.startsWith('--expected-version='));
if (positionalArguments.length > 1 || positionalArguments.some(argument => argument.startsWith('-'))) {
    process.stderr.write('Usage: validate-packaged-release.js [--offline] [--expected-version=VERSION] [release-directory]\n');
    process.exit(2);
}
if (expectedVersionArguments.length > 1 || expectedVersionArguments[0] === '--expected-version=') {
    process.stderr.write('Usage: validate-packaged-release.js [--offline] [--expected-version=VERSION] [release-directory]\n');
    process.exit(2);
}
const root = path.resolve(positionalArguments[0] || 'build/install/oscar');
const sourceBuild = fs.readFileSync(path.resolve(__dirname, '..', 'build.gradle'), 'utf8');
const sourceVersion = sourceBuild.match(/^\s*version\s*=\s*"([^"]+)"\s*$/m)?.[1];
const requestedVersion = expectedVersionArguments[0]?.slice('--expected-version='.length);
const expectedVersion = requestedVersion || sourceVersion;
const fail = message => {
    process.stderr.write(`Packaged release validation failed: ${message}\n`);
    process.exitCode = 1;
};

if (requestedVersion && sourceVersion !== requestedVersion) {
    fail(`expected build.gradle version ${requestedVersion}, received ${sourceVersion || '<unresolved>'}`);
}

if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    fail(`release directory does not exist: ${root}`);
    process.exit();
}

const envPath = path.join(root, '.env.example');
if (!fs.existsSync(envPath)) {
    fail('missing .env.example');
    process.exit();
}
const env = Object.fromEntries(fs.readFileSync(envPath, 'utf8').split(/\r?\n/)
    .filter(line => line && !line.startsWith('#') && line.includes('='))
    .map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
const version = env.OSCAR_VERSION;
if (!expectedVersion || version !== expectedVersion) fail(`expected OSCAR_VERSION=${expectedVersion || '<unresolved>'}, received ${version || '<missing>'}`);
if (Object.hasOwn(env, 'OSCAR_POSTGIS_VERSION')) fail('OSCAR_POSTGIS_VERSION must not diverge from OSCAR_VERSION');
if (env.OSCAR_DEPLOYMENT_ID !== '') fail('OSCAR_DEPLOYMENT_ID must be empty in the packaged template');

const expected = [
    'oscar-storage.sh', 'oscar-storage.ps1', 'validate-storage-archive.sh',
    'postgis/archive-wal.sh', 'postgis/merge-wal-restore.sh', 'postgis/prepare-restore.sh',
    'docker/oscar/archive-object-helper.sh',
    'docker/oscar/atomic-publish.c',
    'documentation/QUICKSTART.md', 'documentation/DEPLOYMENT.md',
    'documentation/LIVE_VIDEO.md', 'documentation/OPERATIONAL_VIEWS.md',
    'documentation/STATUS_OF_HEALTH.md', 'documentation/TRANSLATION_SYSTEM.md',
    'documentation/STORAGE_ARCHITECTURE.md', 'documentation/DATA_LIFECYCLE.md',
    'documentation/ARCHIVE_FORMAT.md', 'documentation/BACKUP_RESTORE.md',
    'documentation/STORAGE_OPERATIONS.md', 'documentation/daily-file-journal-v1.md',
    'documentation/retained-media-v1.md',
];
for (const relative of expected) {
    if (!fs.existsSync(path.join(root, relative))) fail(`missing required file: ${relative}`);
}

for (const relative of ['oscar-storage.sh', 'oscar-storage.ps1']) {
    const source = fs.readFileSync(path.join(root, relative), 'utf8');
    if (!source.includes('archive-generation-ids.txt')) {
        fail(`${relative} does not require the authenticated backup-time archive-generation inventory`);
    }
    if (!source.includes('archive_generation_ids IS NOT DISTINCT FROM EXCLUDED.archive_generation_ids')) {
        fail(`${relative} does not collision-check the exact authenticated archive-generation set`);
    }
}

const compose = fs.readFileSync(path.join(root, 'compose.yaml'), 'utf8');
for (const [modelName, externalName] of [
    ['oscar_state', 'oscar_oscar_state'],
    ['postgres_data', 'oscar_postgres_data'],
]) {
    const definition = new RegExp(`^  ${modelName}:\\r?\\n    external: true\\r?\\n    name: ${externalName}$`, 'm');
    if (!definition.test(compose)) {
        fail(`compose.yaml must attach ${externalName} as an exact external volume`);
    }
}
if (compose.includes('com.botts.oscar.deployment-id')) {
    fail('compose.yaml must not reconcile immutable deployment labels on named volumes');
}

const expectedStorageDefaults = {
    OSCAR_ARCHIVE_DIR: '../oscar-storage/archive',
    OSCAR_WAL_ARCHIVE_DIR: '../oscar-storage/wal-archive',
    OSCAR_BACKUP_DIR: '../oscar-storage/backups',
};
for (const [name, value] of Object.entries(expectedStorageDefaults)) {
    if (env[name] !== value) fail(`${name} must be ${value} in the packaged template`);
}

const files = [];
function walk(directory) {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
        const absolute = path.join(directory, entry.name);
        if (entry.isDirectory()) walk(absolute);
        else if (entry.isFile()) files.push(path.relative(root, absolute).split(path.sep).join('/'));
    }
}
walk(root);

const forbidden = [
    /(^|\/)\.env$/,
    /(^|\/)(?:secrets|tls|data|backups|pgdata)(?:\/|$)/,
    /(^|\/)pre-restore-[^/]+(?:\/|$)/,
    /(^|\/)\.restore-secrets[^/]*(?:\/|$)/,
    /(^|\/)\.bundle-verified[^/]*$/,
    /(^|\/)\.oscar-init-state[^/]*$/,
    /(^|\/)\.oscar-volume-adoption[^/]*$/,
    /(^|\/)\.oscar-storage\.lock$/,
    /(^|\/)offline-images\.tar$/,
    /(^|\/)SHA256SUMS(?:\.hmac)?$/,
];
const allowedOfflineFiles = new Set(['offline-images.tar', 'SHA256SUMS']);
for (const relative of files) {
    if ((!offline || !allowedOfflineFiles.has(relative)) && forbidden.some(pattern => pattern.test(relative))) {
        fail(`runtime/generated material leaked into release: ${relative}`);
    }
}

const markdownFiles = files.filter(relative => relative.endsWith('.md'));
const linkPattern = /!?\[[^\]]*\]\(([^)]+)\)/g;
for (const relative of markdownFiles) {
    const source = fs.readFileSync(path.join(root, relative), 'utf8');
    for (const match of source.matchAll(linkPattern)) {
        let target = match[1].trim();
        if (target.startsWith('<') && target.endsWith('>')) target = target.slice(1, -1);
        target = target.split(/\s+["']/u, 1)[0];
        if (!target || target.startsWith('#') || /^(?:https?:|mailto:|data:|codex:)/i.test(target)) continue;
        const withoutFragment = target.split('#', 1)[0].split('?', 1)[0];
        if (!withoutFragment) continue;
        let decoded;
        try { decoded = decodeURIComponent(withoutFragment); }
        catch { fail(`${relative} has a malformed local link: ${target}`); continue; }
        const resolved = path.resolve(path.dirname(path.join(root, relative)), decoded);
        if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
            fail(`${relative} links outside the release: ${target}`);
        } else if (!fs.existsSync(resolved)) {
            fail(`${relative} has a broken local link: ${target}`);
        }
    }
}

if (!process.exitCode) {
    process.stdout.write(`Validated OSCAR ${version} package: ${files.length} files, ${markdownFiles.length} Markdown documents.\n`);
}
