'use strict';

const TOKEN = document.querySelector('meta[name="mlx-token"]').content;
const PANELS = [
  'models', 'duplicates', 'scout', 'doctor', 'serve', 'jobs', 'advanced', 'settings',
];
const state = {
  scan: null,
  config: null,
  pending: null,
  pendingKind: null,
  selectedLog: null,
  jobTimer: null,
};

function $(id) { return document.getElementById(id); }

async function api(path, options) {
  const request = Object.assign({ headers: {} }, options || {});
  request.headers['X-MLX-Workbench-Token'] = TOKEN;
  if (request.body !== undefined) {
    request.headers['Content-Type'] = 'application/json';
    request.body = JSON.stringify(request.body);
    request.method = request.method || 'POST';
  }
  const response = await fetch(path, request);
  const payload = await response.json().catch(() => null);
  if (!payload || payload.status !== 'ok') {
    const error = (payload && payload.error) || {};
    throw new Error([error.message, error.remediation].filter(Boolean).join('\n') ||
      'Request failed (' + response.status + ').');
  }
  return payload.data;
}

function notify(message) {
  const notice = $('notice');
  notice.textContent = message || '';
  notice.hidden = !message;
}

function bytes(count) {
  let value = Number(count) || 0;
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let index = 0;
  while (value >= 1024 && index < units.length - 1) { value /= 1024; index += 1; }
  return value.toFixed(value >= 10 || index === 0 ? 0 : 1) + units[index];
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function pill(status) {
  return element('span', 'pill pill-' + status, status);
}

function showJson(node, data) {
  node.hidden = false;
  node.textContent = JSON.stringify(data, null, 2);
}

function tokenize(value) {
  return value.trim().split(/\s+/).filter(Boolean);
}

function renderModels() {
  const body = $('models');
  body.textContent = '';
  if (!state.scan) return;
  const pendingOnly = $('pending-only').checked;
  const totals = state.scan.totals;
  $('summary').textContent =
    totals.gguf + ' GGUF files · ' + totals.pending + ' pending · ' +
    totals.converted + ' converted · ' + bytes(totals.bytes) + ' on disk' +
    (totals.unreadable ? ' · ' + totals.unreadable + ' unreadable' : '');

  const rows = state.scan.models.filter(function (item) {
    if (item.status === 'shard') return false;
    return !pendingOnly || item.status === 'pending';
  });
  if (!rows.length) {
    const empty = element('tr');
    empty.appendChild(element('td', 'empty', 'Nothing to show.')).colSpan = 7;
    body.appendChild(empty);
    return;
  }
  rows.forEach(function (item) {
    const row = element('tr');
    row.appendChild(element('td')).appendChild(pill(item.status));

    const name = element('td');
    name.appendChild(element('div', null, item.name));
    name.appendChild(element('span', 'path', item.path));
    row.appendChild(name);

    row.appendChild(element('td', 'mono', item.architecture || '—'));
    row.appendChild(element('td', 'mono', item.quantization || '—'));
    row.appendChild(element('td', 'num', bytes(item.bytes)));

    const output = element('td', 'path');
    if (item.outputs && item.outputs.length) {
      output.textContent = item.outputs.join('\n');
      output.title = 'matched by ' + (item.evidence || 'name');
    } else {
      output.textContent = '—';
    }
    row.appendChild(output);

    const actions = element('td');
    if (item.status === 'pending' || item.status === 'converted') {
      const convert = element('button', null, item.status === 'converted' ? 'Reconvert' : 'Convert');
      convert.addEventListener('click', function () { openConvertPlan(item.path); });
      actions.appendChild(convert);
    }
    row.appendChild(actions);
    body.appendChild(row);
  });
}

function renderDuplicates() {
  const container = $('duplicates');
  container.textContent = '';
  if (!state.scan) return;
  const groups = state.scan.duplicates || [];
  $('dupe-summary').textContent = groups.length
    ? groups.length + ' group(s) · ' + bytes(state.scan.totals.reclaimable_bytes) + ' reclaimable'
    : 'No duplicate models found.';

  groups.forEach(function (group) {
    const card = element('div', 'group');
    const head = element('div', 'group-head');
    head.appendChild(element('strong', null, group.model_key));
    if (group.kind === 'exact') {
      head.appendChild(element('span', 'hint',
        'same model at ' + group.quantization + ' · ' + bytes(group.reclaimable_bytes) + ' reclaimable'));
    } else {
      head.appendChild(element('span', 'hint',
        'same model at ' + group.quantizations.join(', ') + ' — different quality, keep what you use'));
    }
    card.appendChild(head);

    if (group.kind === 'exact') {
      const keep = element('div', 'file-row');
      keep.appendChild(element('span', 'pill pill-converted', 'keep'));
      keep.appendChild(element('span', 'path', group.keep));
      card.appendChild(keep);
      group.redundant.forEach(function (path) {
        const row = element('div', 'file-row');
        row.appendChild(element('span', 'pill pill-pending', 'redundant'));
        row.appendChild(element('span', 'path', path));
        const move = element('button', null, 'Move to quarantine');
        move.addEventListener('click', function () { quarantine(path, move); });
        row.appendChild(move);
        card.appendChild(row);
      });
    } else {
      group.members.forEach(function (path) {
        const row = element('div', 'file-row');
        row.appendChild(element('span', 'path', path));
        card.appendChild(row);
      });
    }
    container.appendChild(card);
  });
}

async function renderQuarantined() {
  const container = $('quarantined');
  container.textContent = '';
  let records = [];
  try {
    records = (await api('/api/quarantine')).records || [];
  } catch (error) {
    container.appendChild(element('div', 'empty', error.message));
    return;
  }
  if (!records.length) {
    container.appendChild(element('div', 'empty', 'Nothing has been moved aside.'));
    return;
  }
  records.forEach(function (record) {
    const row = element('div', 'file-row');
    row.appendChild(element('span', 'hint', record.moved_at));
    row.appendChild(element('span', 'path', record.to));
    row.appendChild(element('span', 'hint', bytes(record.bytes)));
    container.appendChild(row);
  });
}

async function quarantine(path, button) {
  button.disabled = true;
  try {
    await api('/api/quarantine', { body: { path: path } });
    notify('');
    await rescan();
    await renderQuarantined();
  } catch (error) {
    notify(error.message);
    button.disabled = false;
  }
}

function renderJobs(data) {
  const body = $('jobs');
  body.textContent = '';
  const jobs = data.jobs || [];
  const servers = data.servers || [];
  if (!jobs.length && !servers.length) {
    const empty = element('tr');
    empty.appendChild(element('td', 'empty', 'No receipts yet.')).colSpan = 5;
    body.appendChild(empty);
    return;
  }
  jobs.forEach(function (job) {
    body.appendChild(jobRow('convert', job.state, job.repo, job.out, job.started_at, job.log_path));
  });
  servers.forEach(function (job) {
    const target = job.port != null ? 'port ' + job.port : (job.out || '—');
    const logPath = job.log_path || (job.receipt && job.receipt.log_path) || '';
    body.appendChild(jobRow('serve', job.state, job.repo || '—', target, job.started_at, logPath));
  });
}

function jobRow(kind, status, source, target, started, logPath) {
  const row = element('tr');
  if (logPath) {
    row.className = 'clickable';
    row.title = 'Show log';
    row.addEventListener('click', function () {
      state.selectedLog = logPath;
      refreshLog();
    });
  }
  row.appendChild(element('td', 'mono', kind));
  row.appendChild(element('td')).appendChild(pill(status));
  row.appendChild(element('td', 'path', source));
  row.appendChild(element('td', 'path', target));
  row.appendChild(element('td', 'hint', started || '—'));
  return row;
}

async function refreshLog() {
  const node = $('job-log');
  if (!state.selectedLog) {
    node.textContent = 'Select a job with a log path.';
    return;
  }
  try {
    const data = await api('/api/jobs/log?path=' + encodeURIComponent(state.selectedLog));
    node.textContent = data.text || '(empty)';
  } catch (error) {
    node.textContent = error.message;
  }
}

async function openConvertPlan(path) {
  notify('');
  try {
    const data = await api('/api/convert/preview', { body: { path: path, q_bits: quantBits() } });
    state.pending = data.plan;
    state.pendingKind = 'convert';
    fillPlanDialog('Review this conversion', [
      ['Source', data.plan.source.path || data.plan.repo],
      ['Output', data.plan.out],
      ['Quantization', data.plan.q_bits + '-bit'],
      ['Command', (data.plan.argv || []).join(' ')],
      ['Preview hash', data.plan.preview_hash],
    ], 'Runs detached. The intermediate checkpoint is full precision — free disk should be roughly twice the source model\'s fp16 size.');
  } catch (error) {
    notify(error.message);
  }
}

function fillPlanDialog(title, pairs, warn) {
  $('dialog-title').textContent = title;
  $('dialog-warn').textContent = warn || '';
  const list = $('plan');
  list.textContent = '';
  pairs.forEach(function (pair) {
    list.appendChild(element('dt', null, pair[0]));
    list.appendChild(element('dd', null, pair[1]));
  });
  $('dialog').hidden = false;
}

function quantBits() {
  return Number($('q_bits').value) || 4;
}

async function confirmPlan() {
  if (!state.pending || !state.pendingKind) return;
  const button = $('confirm');
  button.disabled = true;
  try {
    if (state.pendingKind === 'convert') {
      await api('/api/convert/start', {
        body: {
          path: state.pending.source.path,
          q_bits: state.pending.q_bits,
          out: state.pending.out,
          preview_hash: state.pending.preview_hash,
        },
      });
    } else if (state.pendingKind === 'serve') {
      await api('/api/serve/start', {
        body: {
          repo: state.pending.repo || state.pending.source && state.pending.source.repo,
          runtime: state.pending.runtime,
          port: state.pending.port,
          preview_hash: state.pending.preview_hash,
        },
      });
    }
    closeDialog();
    selectPanel('jobs');
    await refreshJobs();
  } catch (error) {
    notify(error.message);
  } finally {
    button.disabled = false;
  }
}

function closeDialog() {
  $('dialog').hidden = true;
  state.pending = null;
  state.pendingKind = null;
}

async function rescan() {
  const button = $('rescan');
  button.disabled = true;
  button.textContent = 'Scanning…';
  try {
    state.scan = await api('/api/scan');
    notify('');
    renderModels();
    renderDuplicates();
  } catch (error) {
    notify(error.message);
  } finally {
    button.disabled = false;
    button.textContent = 'Rescan';
  }
}

async function refreshJobs() {
  try {
    const data = await api('/api/jobs');
    renderJobs(data);
    renderServers(data.servers || []);
    if (state.selectedLog) await refreshLog();
  } catch (error) {
    notify(error.message);
  }
}

function renderServers(servers) {
  const container = $('serve-servers');
  if (!container) return;
  container.textContent = '';
  if (!servers.length) {
    container.appendChild(element('div', 'empty', 'No serve receipts yet.'));
    return;
  }
  servers.forEach(function (server) {
    const row = element('div', 'file-row');
    row.appendChild(pill(server.state));
    row.appendChild(element('span', 'path', (server.repo || '—') + ' · port ' + (server.port || '—')));
    if (server.state === 'running' && server.port != null) {
      const stop = element('button', null, 'Stop');
      stop.addEventListener('click', async function () {
        try {
          await api('/api/serve/stop', { body: { port: server.port } });
          await refreshJobs();
        } catch (error) {
          notify(error.message);
        }
      });
      row.appendChild(stop);
    }
    container.appendChild(row);
  });
}

async function runScout(event) {
  event.preventDefault();
  notify('');
  try {
    const data = await api('/api/scout', {
      body: {
        role: $('scout-role').value || null,
        limit: Number($('scout-limit').value) || null,
        fast: $('scout-fast').checked,
        new: $('scout-new').checked,
      },
    });
    showJson($('scout-out'), data);
  } catch (error) {
    notify(error.message);
  }
}

async function runDoctor(event) {
  event.preventDefault();
  notify('');
  try {
    const data = await api('/api/doctor', {
      body: {
        wired_roots: lines($('doctor-wired').value),
        hf_cache: $('doctor-hf').value.trim() || null,
      },
    });
    showJson($('doctor-out'), data);
  } catch (error) {
    notify(error.message);
  }
}

async function previewServe(event) {
  event.preventDefault();
  notify('');
  const repo = $('serve-repo').value.trim();
  const runtime = $('serve-runtime').value;
  const portValue = $('serve-port').value.trim();
  const port = portValue ? Number(portValue) : null;
  try {
    const data = await api('/api/serve/preview', {
      body: { repo: repo, runtime: runtime, port: port },
    });
    const plan = data.plan || data;
    state.pending = plan;
    state.pendingKind = 'serve';
    fillPlanDialog('Review this serve plan', [
      ['Repo', plan.repo || repo],
      ['Runtime', plan.runtime || runtime],
      ['Port', String(plan.port || port || 'default')],
      ['Command', (plan.argv || []).join(' ')],
      ['Preview hash', plan.preview_hash],
    ], 'Loopback only. The model must already be in the Hugging Face cache; serve never downloads.');
  } catch (error) {
    notify(error.message);
  }
}

async function runCli(event) {
  event.preventDefault();
  notify('');
  const argv = tokenize($('cli-argv').value);
  if (!argv.length) {
    notify('Enter argv tokens, for example: convert status');
    return;
  }
  try {
    const data = await api('/api/cli', { body: { argv: argv } });
    showJson($('cli-out'), data);
  } catch (error) {
    notify(error.message);
  }
}

function fillSettings(data) {
  const config = data.config;
  state.config = config;
  $('gguf_roots').value = (config.gguf_roots || []).join('\n');
  $('mlx_roots').value = (config.mlx_roots || []).join('\n');
  $('output_dir').value = config.output_dir || '';
  $('mlx_agent_path').value = config.mlx_agent_path || '';
  $('quarantine_dir').value = config.quarantine_dir || '';
  $('q_bits').value = String(config.q_bits || 4);
  $('signatures').checked = Boolean(config.signatures);
  $('config-path').textContent = data.config_path;
  const health = data.agent || {};
  $('agent-health').textContent = health.ok
    ? 'Agent ready: ' + health.path
    : (health.message || 'Agent not configured.') +
      (data.vendor_agent_path ? ' Vendor path: ' + data.vendor_agent_path : '');
}

function lines(value) {
  return value.split('\n').map(function (item) { return item.trim(); })
    .filter(function (item) { return item.length > 0; });
}

async function saveSettings(event) {
  event.preventDefault();
  try {
    const data = await api('/api/config', {
      body: {
        gguf_roots: lines($('gguf_roots').value),
        mlx_roots: lines($('mlx_roots').value),
        output_dir: $('output_dir').value.trim(),
        mlx_agent_path: $('mlx_agent_path').value.trim(),
        quarantine_dir: $('quarantine_dir').value.trim(),
        q_bits: Number($('q_bits').value),
        signatures: $('signatures').checked,
      },
    });
    fillSettings({
      config: data.config,
      config_path: $('config-path').textContent,
      agent: data.agent,
      vendor_agent_path: state.config && state.config.mlx_agent_path,
    });
    notify('');
    await rescan();
  } catch (error) {
    notify(error.message);
  }
}

function selectPanel(name) {
  PANELS.forEach(function (panel) {
    $('panel-' + panel).hidden = panel !== name;
  });
  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (tab) {
    tab.classList.toggle('is-active', tab.dataset.panel === name);
  });
  if (name === 'jobs') {
    refreshJobs();
    if (state.jobTimer) clearInterval(state.jobTimer);
    state.jobTimer = setInterval(refreshJobs, 2500);
  } else if (state.jobTimer) {
    clearInterval(state.jobTimer);
    state.jobTimer = null;
  }
  if (name === 'duplicates') renderQuarantined();
  if (name === 'serve') refreshJobs();
}

function init() {
  $('tabs').addEventListener('click', function (event) {
    if (event.target.dataset.panel) selectPanel(event.target.dataset.panel);
  });
  $('rescan').addEventListener('click', rescan);
  $('pending-only').addEventListener('change', renderModels);
  $('settings').addEventListener('submit', saveSettings);
  $('scout-form').addEventListener('submit', runScout);
  $('doctor-form').addEventListener('submit', runDoctor);
  $('serve-form').addEventListener('submit', previewServe);
  $('cli-form').addEventListener('submit', runCli);
  $('confirm').addEventListener('click', confirmPlan);
  $('cancel').addEventListener('click', closeDialog);

  api('/api/config').then(function (data) {
    fillSettings(data);
    if (!data.agent || !data.agent.ok) {
      notify((data.agent && data.agent.message) ||
        'No mlx-agent checkout configured. Init the vendor submodule or set it under Settings.');
      selectPanel('settings');
      return;
    }
    return rescan();
  }).catch(function (error) { notify(error.message); });
}

init();
