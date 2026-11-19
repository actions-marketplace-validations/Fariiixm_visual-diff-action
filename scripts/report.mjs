// Last step: decides the status, writes the Markdown summary and sets the outputs.
// Statuses: OK, CHANGED, BROKEN, UNAVAILABLE (see the README).
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const tmp = process.env.VUG_TMP || '';
const read = (name) => {
  try { return fs.readFileSync(path.join(tmp, name), 'utf8').trim(); } catch { return ''; }
};
const strip = (s) => String(s ?? '').replace(/\u001b\[[0-9;]*m/g, '');
const firstLine = (s) => strip(s).split('\n').map((l) => l.trim()).find(Boolean) ?? '';
const cell = (s) => strip(s).replace(/\|/g, '\\|').replace(/\s+/g, ' ').trim().slice(0, 160);
const code = (s) => '`' + String(s).replace(/`/g, "'") + '`';
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const MAX_ROWS = 50;

const baseRef = process.env.INPUT_BASE_REF || '';
const baseSha = read('base.sha');
const base = baseSha ? `${code(baseRef)} (${code(baseSha.slice(0, 7))})` : code(baseRef);
const reportUrl = process.env.ARTIFACT_URL || '';
const referenceDir = path.join(tmp, 'reference');

const changed = [];
const added = [];
const broken = [];
let flaky = 0;
let status;
let reason = '';

// Walks the JSON report and sorts every failed test into changed, added (no reference) or broken
function classify(report) {
  for (const e of report.errors ?? []) broken.push({ title: 'Test run', error: firstLine(e.message ?? e.value) });
  const visit = (suites) => {
    for (const suite of suites ?? []) {
      visit(suite.suites);
      for (const spec of suite.specs ?? []) {
        for (const test of spec.tests ?? []) {
          if (test.status === 'flaky') flaky++;
          if (test.status !== 'unexpected') continue;
          const title = [spec.file, spec.title].filter(Boolean).join(' › ') + (test.projectName ? ` [${test.projectName}]` : '');
          const result = (test.results ?? []).at(-1) ?? {};
          const errors = result.errors?.length ? result.errors : result.error ? [result.error] : [];
          const messages = errors.map((e) => strip(e.message ?? e.value ?? ''));
          let visual = false;

          for (const a of result.attachments ?? []) {
            const name = a.name || path.basename(a.path || '');
            if (/-diff\.[a-z0-9]+$/i.test(name)) {
              changed.push({ name: name.replace(/-diff(\.[a-z0-9]+)$/i, '$1'), title });
              visual = true;
            }
          }
          for (const m of messages) {
            const missing = m.match(/A snapshot doesn't exist at (.+)$/m);
            if (!missing) continue;
            const file = missing[1].replace(/, (writing actual|matchers using).*$/, '').replace(/\.$/, '').trim();
            const rel = path.relative(referenceDir, file);
            added.push({ name: rel && !rel.startsWith('..') ? path.basename(rel) : path.basename(file), title });
            visual = true;
          }
          if (!visual && messages.some((m) => /toHaveScreenshot|toMatchSnapshot|Screenshot comparison failed/.test(m))) {
            changed.push({ name: '(see the report)', title });
            visual = true;
          }
          if (!visual) broken.push({ title, error: firstLine(messages[0]) || `test ${result.status ?? 'failed'}` });
        }
      }
    }
  };
  visit(report.suites);
}

if (!tmp || !fs.existsSync(tmp)) {
  status = 'UNAVAILABLE';
  reason = 'the action could not prepare its working folder (see the log).';
} else if (read('before.status') !== 'READY') {
  status = 'UNAVAILABLE';
  reason = read('before.reason') || 'the reference screenshots were not taken (see the log).';
} else if (read('after.status') !== 'RAN') {
  status = 'BROKEN';
  reason = read('after.reason') || 'the comparison did not run (see the log).';
} else {
  const rc = Number(read('after.test-rc') || '1');
  try {
    classify(JSON.parse(fs.readFileSync(path.join(tmp, 'results.json'), 'utf8')));
  } catch {
    if (rc !== 0) reason = 'Playwright did not write its JSON report (see the log).';
  }
  if (broken.length) status = 'BROKEN';
  else if (changed.length || added.length) status = 'CHANGED';
  else if (rc === 0) status = 'OK';
  else {
    status = 'BROKEN';
    reason ||= `Playwright exited with code ${rc} (see the log).`;
  }
}

// Markdown summary, ready for a PR comment or the job summary
const icons = { OK: '✅', CHANGED: '⚠️', BROKEN: '❌', UNAVAILABLE: '❔' };
const lines = [`### ${icons[status]} Visual Update Guard: ${status}`, ''];
const table = (header, rows, toRow) => {
  lines.push(header, '|---|---|');
  for (const r of rows.slice(0, MAX_ROWS)) lines.push(toRow(r));
  if (rows.length > MAX_ROWS) lines.push(`| …and ${rows.length - MAX_ROWS} more | |`);
  lines.push('');
};
const count = Number(read('reference.count') || '0');

if (status === 'OK') {
  lines.push(`All ${plural(count, 'reference snapshot')} from ${base} match the current code pixel by pixel.`, '');
} else if (status === 'CHANGED') {
  if (changed.length) {
    lines.push(`${plural(changed.length, 'snapshot')} ${changed.length === 1 ? 'looks' : 'look'} different from ${base}.`, '');
    table('| Snapshot | Test |', changed, (r) => `| ${code(r.name)} | ${cell(r.title)} |`);
  }
  if (added.length) {
    lines.push(`${plural(added.length, 'new snapshot')} with no reference on ${base}:`, '');
    table('| Snapshot | Test |', added, (r) => `| ${code(r.name)} | ${cell(r.title)} |`);
  }
} else if (status === 'BROKEN') {
  lines.push(`The current code could not be checked against ${base}.`, '');
  if (broken.length) table('| Test | Error |', broken, (r) => `| ${cell(r.title)} | ${cell(r.error)} |`);
  if (reason) lines.push(reason, '');
} else {
  lines.push(`No comparison was made: ${reason}`, '');
}

if (reportUrl && (status === 'CHANGED' || status === 'BROKEN')) {
  lines.push(`[Download the Playwright report](${reportUrl}) to see the expected, actual and diff images.`, '');
}
const pwBefore = read('before.pw-version');
const pwAfter = read('after.pw-version');
if (pwBefore && pwAfter && pwBefore !== pwAfter) {
  lines.push(`> **Note:** Playwright changed between ${base} (${pwBefore}) and the current code (${pwAfter}). A new browser build can change pixels on its own.`, '');
}
if (flaky) lines.push(`> ${plural(flaky, 'test')} passed only after a retry.`, '');

const summary = lines.join('\n').trim();
console.log(summary);

// Outputs
const names = [...changed, ...added].map((r) => r.name).filter((n) => !n.startsWith('('));
if (process.env.GITHUB_OUTPUT) {
  const delimiter = `vug_${crypto.randomUUID()}`;
  fs.appendFileSync(process.env.GITHUB_OUTPUT, [
    `status=${status}`,
    `base-sha=${baseSha}`,
    `changed=${[...new Set(names)].join(',')}`,
    `summary<<${delimiter}`, summary, delimiter, '',
  ].join('\n'));
}
if (process.env.INPUT_JOB_SUMMARY === 'true' && process.env.GITHUB_STEP_SUMMARY) {
  fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${summary}\n`);
}

const failOn = (process.env.INPUT_FAIL_ON || '').split(/[\s,]+/).map((s) => s.trim().toUpperCase()).filter(Boolean);
if (failOn.includes(status)) {
  console.log(`::error title=Visual Update Guard::The result is ${status}, which is listed in fail-on.`);
  process.exitCode = 1;
}
