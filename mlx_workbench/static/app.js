'use strict';

const TOKEN = document.querySelector('meta[name="mlx-token"]').content;

const PANELS = [
  'models', 'duplicates', 'convert', 'serve', 'jobs', 'settings', 'doctor', 'scout',
  'training-studio', 'quant', 'model-arch',
];
const state = {
  scan: null,
  config: null,
  runtime: null,
  pending: null,
  pendingKind: null,
  pendingBatch: null,
  duplicateScan: null,
  selectedLog: null,
  logManual: false,
  jobTimer: null,
  jobBusy: false,
};

function $(id) { return document.getElementById(id); }

function on(id, event, handler) {
  const node = $(id);
  if (node) node.addEventListener(event, handler);
}

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
  return MLXWorkbenchEnvelope.unwrap(payload, response.status);
}

function notify(message) {
  MLXWorkbenchDOM.notify(document, 'notice', message);
}

function bytes(count) {
  return MLXWorkbenchFormatters.bytes(count);
}

function element(tag, className, text) {
  return MLXWorkbenchDOM.element(document, tag, className, text);
}

function pill(status) {
  return MLXWorkbenchDOM.pill(document, status);
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
    empty.appendChild(element('td', 'empty', 'Nothing to show.')).colSpan = 8;
    body.appendChild(empty);
    return;
  }
  rows.forEach(function (item) {
    const row = element('tr', 'clickable');
    row.dataset.modelPath = item.path;
    const checkCell = element('td', 'check-col');
    if (item.status === 'pending' || item.status === 'converted') {
      const box = element('input');
      box.type = 'checkbox';
      box.className = 'model-select';
      box.value = item.path;
      checkCell.appendChild(box);
    }
    row.appendChild(checkCell);
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


function selectedModelPaths() {
  return Array.prototype.map.call(
    document.querySelectorAll('#models .model-select:checked'),
    function (box) { return box.value; }
  );
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
  const live = records.filter(function (record) { return record.exists && !record.deleted; });
  const gone = records.filter(function (record) { return record.deleted; });
  if (!records.length || (!live.length && !gone.length)) {
    container.appendChild(element('div', 'empty', 'Nothing has been moved aside.'));
    return;
  }
  if (!live.length) {
    container.appendChild(element('div', 'empty', 'Quarantine is empty — everything here is already deleted.'));
    return;
  }
  live.forEach(function (record) {
    const row = element('div', 'file-row');
    row.appendChild(element('span', 'hint', record.moved_at));
    row.appendChild(element('span', 'path', record.to));
    row.appendChild(element('span', 'hint', bytes(record.bytes)));
    const del = element('button', 'secondary', 'Delete…');
    del.type = 'button';
    del.addEventListener('click', function () { purgeQuarantined(record, del); });
    row.appendChild(del);
    container.appendChild(row);
  });
  if (gone.length) {
    container.appendChild(element('p', 'hint', gone.length + ' previously quarantined file' + (gone.length === 1 ? '' : 's') + ' permanently deleted.'));
  }
}

async function purgeQuarantined(record, button) {
  state.pending = record;
  state.pendingKind = 'quarantine-delete';
  fillPlanDialog(
    'Delete permanently?',
    [
      ['File', record.to],
      ['Size', bytes(record.bytes)],
      ['Quarantined', record.moved_at],
    ],
    'This moves the file to the Trash and marks the ledger entry deleted. It cannot be undone from here.',
  );
}

async function quarantine(path, button) {
  button.disabled = true;
  try {
    await api('/api/quarantine', { body: { path: path } });
    await rescan({ force: true });
    await renderQuarantined();
    return true;
  } catch (error) {
    notify(error.message);
    button.disabled = false;
    return false;
  }
}

function renderJobs(data) {
  const body = $('jobs');
  body.textContent = '';
  const jobs = data.jobs || [];
  const servers = data.servers || [];
  const lora = data.lora || [];
  const fuse = data.fuse || [];
  const queueErrorNode = $('convert-queue-error');
  const queueErrors = [
    data.convert_queue_load_error,
    data.convert_queue_error,
    data.convert_worker_result && data.convert_worker_result.error,
    data.convert_worker_result && data.convert_worker_result.persistence_error,
  ].filter(Boolean).map(function (value) {
    const detail = value.error || value;
    return [detail.message || detail.code || 'Conversion queue recovery needs attention.', detail.remediation]
      .filter(Boolean).join(' ');
  });
  if (data.errors) {
    Object.keys(data.errors).forEach(function (name) {
      const detail = data.errors[name] || {};
      queueErrors.push(
        ['Agent ' + name + ' status probe failed: ' + (detail.message || detail.code || 'unknown error'), detail.remediation]
          .filter(Boolean).join(' ')
      );
    });
  }
  queueErrorNode.textContent = queueErrors.join('\n');
  queueErrorNode.hidden = queueErrors.length === 0;
  const convertQueue = data.convert_queue || [];
  renderConvertQueue(convertQueue);
  const runningConvert = jobs.find(function (job) { return job.state === 'running'; });
  state.jobBusy = Boolean(runningConvert) || convertQueue.some(function (item) {
    return item.state === 'queued' || item.state === 'starting';
  });
  if (runningConvert && runningConvert.log_path && !state.logManual) {
    state.selectedLog = runningConvert.log_path;
  }
  if (!jobs.length && !servers.length && !lora.length && !fuse.length) {
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
  lora.forEach(function (job) {
    body.appendChild(jobRow('lora', job.state, job.repo || '—', job.out || '—', job.started_at, job.log_path));
  });
  fuse.forEach(function (job) {
    body.appendChild(jobRow('fuse', job.state, job.repo || '—', job.out || '—', job.started_at, job.log_path));
  });
}

function renderConvertQueue(queue) {
  const node = $('convert-queue');
  if (!node) return;
  node.textContent = '';
  if (!queue.length) {
    node.hidden = true;
    return;
  }
  node.hidden = false;
  const pendingCount = queue.filter(function (item) { return item.state === 'queued'; }).length;
  const startingCount = queue.filter(function (item) { return item.state === 'starting'; }).length;
  const failedCount = queue.filter(function (item) { return item.state === 'failed'; }).length;
  const counts = [];
  if (pendingCount) counts.push(pendingCount + ' pending');
  if (startingCount) counts.push(startingCount + ' starting');
  if (failedCount) counts.push(failedCount + ' failed');
  node.appendChild(element('strong', null, 'Conversion queue (' + counts.join(' · ') + ')'));
  const queuedIds = queue.filter(function (item) {
    return item.state === 'queued';
  }).map(function (item) { return item.id; });

  function action(row, label, endpoint, body, disabled, title) {
    const button = element('button', null, label);
    button.disabled = Boolean(disabled);
    if (title) button.title = title;
    button.addEventListener('click', async function () {
      button.disabled = true;
      try {
        await api(endpoint, { body: body });
        await refreshJobs();
      } catch (error) {
        notify(error.message);
        button.disabled = Boolean(disabled);
      }
    });
    row.appendChild(button);
  }

  queue.forEach(function (item) {
    const row = element('div', 'queue-item');
    row.appendChild(element('span', 'path', item.label || item.path || item.repo || item.id));
    if (item.state === 'failed') {
      const failure = item.failure || {};
      row.appendChild(element(
        'span',
        'hint',
        [item.q_bits + '-bit · failed', failure.message, failure.remediation]
          .filter(Boolean).join(' · ')
      ));
      action(row, 'Retry', '/api/convert/queue/retry', { id: item.id });
      action(row, 'Remove', '/api/convert/queue/cancel', { id: item.id });
    } else if (item.state === 'starting') {
      row.appendChild(element(
        'span', 'hint', item.q_bits + '-bit · starting · reconciling accepted launch'
      ));
      action(
        row,
        'Reconciling',
        '/api/convert/queue/cancel',
        { id: item.id },
        true,
        'This launch is being reconciled with its mlx-agent receipt.'
      );
    } else {
      row.appendChild(element('span', 'hint', item.q_bits + '-bit · queued'));
      const queuedIndex = queuedIds.indexOf(item.id);
      action(
        row, 'Up', '/api/convert/queue/move', { id: item.id, direction: 'up' },
        queuedIndex === 0
      );
      action(
        row, 'Down', '/api/convert/queue/move', { id: item.id, direction: 'down' },
        queuedIndex === queuedIds.length - 1
      );
      action(row, 'Cancel', '/api/convert/queue/cancel', { id: item.id });
    }
    node.appendChild(row);
  });
  const clear = element('button', null, 'Clear pending and failed');
  clear.addEventListener('click', async function () {
    clear.disabled = true;
    try {
      await api('/api/convert/queue/clear', { body: {} });
      await refreshJobs();
    } catch (error) {
      notify(error.message);
      clear.disabled = false;
    }
  });
  node.appendChild(clear);
}

function jobRow(kind, status, source, target, started, logPath) {
  const row = element('tr');
  if (logPath) {
    row.className = 'clickable';
    if (state.selectedLog === logPath) row.className += ' is-selected';
    row.title = 'Show log';
    row.addEventListener('click', function () {
      state.selectedLog = logPath;
      state.logManual = true;
      refreshJobs();
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
  const progress = $('job-progress');
  if (!state.selectedLog) {
    node.textContent = 'Select a job with a log path.';
    if (progress) {
      progress.hidden = true;
      progress.textContent = '';
    }
    return;
  }
  try {
    const data = await api('/api/jobs/log?path=' + encodeURIComponent(state.selectedLog));
    node.textContent = data.text || '(empty)';
    if (progress) {
      const summary = (data.progress && data.progress.summary) || '';
      const last = (data.progress && data.progress.last_line) || '';
      if (summary || last) {
        progress.hidden = false;
        progress.textContent = summary + (last && last !== summary ? ' — ' + last : '');
      } else {
        progress.hidden = true;
        progress.textContent = '';
      }
    }
  } catch (error) {
    node.textContent = error.message;
  }
}

async function openConvertPlan(path) {
  notify('');
  if (warnConvertDeps()) return;
  try {
    const data = await api('/api/convert/preview', { body: { path: path, q_bits: quantBits() } });
    state.pending = data.plan;
    state.pendingKind = 'convert';
    state.pendingBatch = null;
    fillPlanDialog('Review this conversion', [
      ['Source', (data.plan.source && data.plan.source.path) || data.plan.repo],
      ['Output', data.plan.out],
      ['Quantization', data.plan.q_bits + '-bit'],
      ['Command', (data.plan.argv || []).join(' ')],
      ['Preview hash', data.plan.preview_hash],
    ], 'Runs detached. The intermediate checkpoint is full precision — free disk should be roughly twice the source model\'s fp16 size.');
  } catch (error) {
    notify(error.message);
  }
}

async function openHfConvertPlan(event) {
  event.preventDefault();
  notify('');
  if (warnConvertDeps()) return;
  const repo = $('hf-repo').value.trim();
  if (!repo) {
    notify('Enter a publisher/model repo id from the local HF cache.');
    return;
  }
  const qBits = Number($('hf-q_bits').value) || 4;
  const out = $('hf-out').value.trim() || undefined;
  try {
    const body = { repo: repo, q_bits: qBits };
    if (out) body.out = out;
    const data = await api('/api/convert/preview', { body: body });
    state.pending = data.plan;
    state.pendingKind = 'convert';
    state.pendingBatch = null;
    fillPlanDialog('Review HF-cache conversion', [
      ['Repo', data.plan.repo],
      ['Source', (data.plan.source && data.plan.source.kind) || 'hf-cache'],
      ['Output', data.plan.out],
      ['Quantization', data.plan.q_bits + '-bit'],
      ['Command', (data.plan.argv || []).join(' ')],
      ['Preview hash', data.plan.preview_hash],
    ], 'Model must already be in the local Hugging Face cache. Convert never downloads.');
  } catch (error) {
    notify(error.message);
  }
}

async function queueSelectedModels() {
  notify('');
  if (warnConvertDeps()) return;
  const paths = selectedModelPaths();
  if (!paths.length) {
    notify('Select one or more convertible models first.');
    return;
  }
  const button = $('queue-selected') || $('convert-selected');
  button.disabled = true;
  try {
    const plans = [];
    for (let i = 0; i < paths.length; i += 1) {
      const data = await api('/api/convert/preview', {
        body: { path: paths[i], q_bits: quantBits() },
      });
      plans.push(data.plan);
    }
    state.pending = plans[0];
    state.pendingKind = 'convert-batch';
    state.pendingBatch = plans;
    const pairs = [
      ['Count', String(plans.length)],
      ['Quantization', quantBits() + '-bit'],
    ];
    plans.forEach(function (plan, index) {
      pairs.push([
        '#' + (index + 1),
        ((plan.source && plan.source.path) || plan.repo) + ' → ' + plan.out,
      ]);
    });
    fillPlanDialog(
      'Queue ' + plans.length + ' conversion(s)',
      pairs,
      'First job starts now if idle; the rest wait in the workbench queue (mlx-agent runs one convert at a time).'
    );
  } catch (error) {
    notify(error.message);
  } finally {
    button.disabled = false;
  }
}

function convertStartBody(plan) {
  return MLXWorkbenchPayloads.convertStartBody(plan);
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
    if (state.pendingKind === 'quarantine') {
      const pending = state.pending;
      const moved = await quarantine(pending.path, pending.button);
      closeDialog();
      if (moved) {
        notify('Duplicate moved to quarantine.');
        selectPanel('duplicates');
        await scanDuplicates();
      }
      return;
    } else if (state.pendingKind === 'quarantine-delete') {
      await api('/api/quarantine/delete', { body: { path: state.pending.to } });
      closeDialog();
      notify('Moved to Trash.');
      await renderQuarantined();
      return;
    } else if (state.pendingKind === 'serve-preset-save') {
      await saveServePreset(state.pending);
      closeDialog();
      return;
    } else if (state.pendingKind === 'serve-preset-delete') {
      await api('/api/serve/presets/delete', { body: { id: state.pending.id } });
      await refreshPresets();
      closeDialog();
      notify('Preset deleted.');
      return;
    } else if (state.pendingKind === 'convert') {
      await api('/api/convert/start', { body: convertStartBody(state.pending) });
    } else if (state.pendingKind === 'convert-batch') {
      const plans = state.pendingBatch || [];
      for (let i = 0; i < plans.length; i += 1) {
        await api('/api/convert/start', { body: convertStartBody(plans[i]) });
      }
    } else if (state.pendingKind === 'serve') {
      await api('/api/serve/start', {
        body: {
          repo: state.pending.repo || state.pending.source && state.pending.source.repo,
          runtime: state.pending.runtime,
          port: state.pending.port,
          max_tokens: state.pending.max_tokens,
          adapter_path: state.pending.adapter_path,
          preview_hash: state.pending.preview_hash,
        },
      });
    } else if (state.pendingKind === 'prune') {
      await api('/api/doctor/prune/confirm', {
        body: {
          preview_hash: state.pending.preview_hash,
          hf_cache: $('doctor-hf').value.trim() || null,
        },
      });
    } else if (state.pendingKind === 'lora') {
      await api('/api/lora/start', {
        body: {
          repo: state.pending.repo,
          data: state.pending.data,
          iters: state.pending.iters,
          out: state.pending.out,
          preview_hash: state.pending.preview_hash,
        },
      });
    } else if (state.pendingKind === 'fuse') {
      await api('/api/fuse/start', {
        body: {
          repo: state.pending.repo,
          adapter: state.pending.adapter,
          out: state.pending.out,
          preview_hash: state.pending.preview_hash,
        },
      });
    }
    const kind = state.pendingKind;
    closeDialog();
    if (kind === 'prune') {
      selectPanel('doctor');
      await runDoctor({ preventDefault: function () {}, target: $('doctor-form') });
    } else {
      state.logManual = false;
      selectPanel('jobs');
      await refreshJobs();
    }
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
  state.pendingBatch = null;
}

const SCAN_CACHE_KEY = 'mlx_workbench_scan_cache';

function readScanCache() {
  try {
    const raw = localStorage.getItem(SCAN_CACHE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed || !parsed.scan) return null;
    return parsed;
  } catch (error) {
    return null;
  }
}

function writeScanCache(scan) {
  try {
    localStorage.setItem(SCAN_CACHE_KEY, JSON.stringify({ scan: scan, at: Date.now() }));
  } catch (error) {
    // Storage full or unavailable; the cache is best-effort.
  }
}

function describeScanAge(cachedAt) {
  if (!cachedAt) return '';
  const minutes = Math.max(1, Math.round((Date.now() - cachedAt) / 60000));
  if (minutes < 60) return 'about ' + minutes + ' min ago';
  const hours = Math.round(minutes / 60);
  if (hours < 24) return hours + ' h ago';
  return Math.round(hours / 24) + ' d ago';
}

async function rescan(options) {
  const force = !!(options && options.force);
  const button = $('rescan');
  // Worst case: render the last-known inventory from local storage before
  // any network round trip, so the screen never loads empty.
  if (!state.scan) {
    const cached = readScanCache();
    if (cached) {
      state.scan = cached.scan;
      renderModels();
      notify('Showing models from ' + describeScanAge(cached.at) + ' — rescanning…');
    }
  }
  button.disabled = true;
  button.textContent = 'Scanning…';
  try {
    state.scan = await api('/api/scan' + (force ? '?refresh=1' : ''));
    writeScanCache(state.scan);
    if (state.scan.stale) {
      notify('Cached scan from ' + describeScanAge(cachedAt()) + ' — a fresh scan is running.');
    } else {
      notify('');
    }
    renderModels();
    updateServeSuggestions();
    renderDuplicateScan(state.duplicateScan);
  } catch (error) {
    if (!state.scan) notify(error.message);
  } finally {
    button.disabled = false;
    button.textContent = 'Rescan';
  }
}

function cachedAt() {
  const cached = readScanCache();
  return cached ? cached.at : null;
}

async function refreshJobs() {
  try {
    const data = await api('/api/jobs');
    renderJobs(data);
    renderServers(data.servers || []);
    if (state.selectedLog) await refreshLog();
    scheduleJobPoll();
  } catch (error) {
    notify(error.message);
  }
}

function scheduleJobPoll() {
  const jobsPanel = $('panel-jobs');
  if (!jobsPanel || jobsPanel.hidden) return;
  if (state.jobTimer) clearInterval(state.jobTimer);
  const ms = state.jobBusy ? 1500 : 2500;
  state.jobTimer = setInterval(refreshJobs, ms);
}

function renderServers(servers) {
  const body = $('serve-servers');
  if (!body) return;
  body.textContent = '';
  if (!servers.length) {
    const empty = element('tr');
    empty.appendChild(element('td', 'empty', 'No serve receipts yet.')).colSpan = 6;
    body.appendChild(empty);
    return;
  }
  servers.forEach(function (server) {
    const row = element('tr');
    row.appendChild(element('td')).appendChild(pill(server.state || 'unknown'));
    row.appendChild(element('td', 'path', server.repo || '—'));
    row.appendChild(element('td', 'mono', server.runtime || '—'));
    row.appendChild(element('td', 'mono', server.port != null ? String(server.port) : '—'));
    row.appendChild(element('td', 'hint', server.started_at || '—'));
    const actions = element('td');
    if (server.state === 'running' && server.port != null) {
      const copy = element('button', 'secondary', 'Copy URL');
      copy.type = 'button';
      copy.addEventListener('click', function () {
        const url = 'http://127.0.0.1:' + server.port + '/v1';
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(url).then(function () {
            notify('Endpoint URL copied.');
          }, function () {
            notify(url);
          });
        } else {
          notify(url);
        }
      });
      actions.appendChild(copy);
      const stop = element('button', null, 'Stop');
      stop.addEventListener('click', async function () {
        stop.disabled = true;
        try {
          await api('/api/serve/stop', { body: { port: server.port } });
          notify('');
          await refreshJobs();
        } catch (error) {
          notify(error.message);
          stop.disabled = false;
        }
      });
      actions.appendChild(stop);
    }
    row.appendChild(actions);
    body.appendChild(row);
    
  });
  
}

function hostLine(host, fast) {
  if (!host || typeof host !== 'object') return '';
  const parts = [];
  if (host.chip) parts.push(host.chip);
  if (host.ram_gb != null) parts.push(host.ram_gb + 'GB RAM');
  parts.push('Ollama ' + (host.ollama ? '✓' : '✗'));
  parts.push('LM Studio ' + (host.lmstudio ? '✓' : '✗'));
  if (fast) parts.push('fast mode');
  return parts.join(' · ');
}

function yesNo(value) {
  if (value === true) return 'yes';
  if (value === false) return 'no';
  return '—';
}

function renderScout(data) {
  const hostNode = $('scout-host');
  const results = $('scout-results');
  results.textContent = '';
  const host = data.host || {};
  hostNode.hidden = false;
  hostNode.textContent = hostLine(host, data.fast);

  const roles = data.roles || {};
  const roleNames = Object.keys(roles);
  if (!roleNames.length) {
    results.appendChild(element('div', 'empty', 'No candidates returned.'));
    return;
  }

  roleNames.forEach(function (role) {
    const models = roles[role] || [];
    results.appendChild(element('h3', null, role + ' (' + models.length + ')'));
    const table = element('table', 'grid');
    const head = element('thead');
    const headRow = element('tr');
    ['Model', 'RAM', 'Fits', 'Reasoning', 'License', '↓', ''].forEach(function (label) {
      headRow.appendChild(element('th', label === '↓' ? 'num' : null, label));
    });
    head.appendChild(headRow);
    table.appendChild(head);
    const body = element('tbody');
    if (!models.length) {
      const empty = element('tr');
      empty.appendChild(element('td', 'empty', 'Nothing in this role.')).colSpan = 7;
      body.appendChild(empty);
    } else {
      models.forEach(function (model) {
        const row = element('tr');
        const name = element('td');
        const title = element('div', null, model.repo || '—');
        if (model.trusted) title.appendChild(document.createTextNode(' ★'));
        name.appendChild(title);
        if (model.base) name.appendChild(element('span', 'hint', model.base));
        row.appendChild(name);

        const ram = model.est_ram_gb != null ? model.est_ram_gb + 'GB' : '—';
        const ramCell = element('td', 'mono', ram);
        if (model.ram_src) ramCell.title = model.ram_src;
        row.appendChild(ramCell);
        row.appendChild(element('td', 'mono', yesNo(model.fits)));

        let reasoning = yesNo(model.reasoning);
        if (model.reasoning && model.reason_src) reasoning = '⚠ ' + model.reason_src;
        row.appendChild(element('td', 'mono', reasoning));

        let license = model.license || '—';
        if (model.gated) license += ' 🔒';
        row.appendChild(element('td', 'mono', license));
        row.appendChild(element('td', 'num', model.downloads != null ? String(model.downloads) : '—'));

        const actions = element('td');
        const serve = element('button', null, 'Serve');
        serve.addEventListener('click', function () {
          useRepoForServe(model.repo, model.role === 'vision' ? 'mlx-vlm' : 'mlx_lm');
        });
        actions.appendChild(serve);
        row.appendChild(actions);
        body.appendChild(row);
    
  });
  
    }
    table.appendChild(body);
    results.appendChild(table);
  });
}

function useRepoForServe(repo, runtime) {
  if (!repo) return;
  $('serve-repo').value = repo;
  if (runtime) $('serve-runtime').value = runtime;
  selectPanel('serve');
  notify('Repo loaded into Serve. Preview to confirm launch.');
}

function setSection(headingId, tableId, visible) {
  const heading = $(headingId);
  const table = $(tableId);
  if (heading) heading.hidden = !visible;
  if (table) table.hidden = !visible;
}

function renderDoctor(data) {
  const summary = data.summary || {};
  const summaryNode = $('doctor-summary');
  summaryNode.hidden = false;
  summaryNode.textContent =
    (summary.models != null ? summary.models + ' models' : '—') +
    ' · ' + bytes(summary.hf_cache_bytes) + ' in HF cache' +
    ' · ' + (summary.wired_configs != null ? summary.wired_configs : 0) + ' wired' +
    ' · ' + (summary.findings != null ? summary.findings : (data.findings || []).length) + ' findings';

  const findings = data.findings || [];
  setSection('doctor-findings-heading', 'doctor-findings-table', true);
  const findingsBody = $('doctor-findings');
  findingsBody.textContent = '';
  if (!findings.length) {
    const empty = element('tr');
    empty.appendChild(element('td', 'empty', 'No findings.')).colSpan = 3;
    findingsBody.appendChild(empty);
  } else {
    findings.forEach(function (item) {
      const row = element('tr');
      row.appendChild(element('td')).appendChild(pill(item.code || 'finding'));
      const model = element('td', 'path', item.model || '—');
      if (item.path) model.title = item.path;
      row.appendChild(model);
      row.appendChild(element('td', null, item.remediation || '—'));
      findingsBody.appendChild(row);
    });
  }

  const inventory = data.inventory || [];
  setSection('doctor-inventory-heading', 'doctor-inventory-table', true);
  const inventoryBody = $('doctor-inventory');
  inventoryBody.textContent = '';
  if (!inventory.length) {
    const empty = element('tr');
    empty.appendChild(element('td', 'empty', 'Cache is empty or unscanned.')).colSpan = 4;
    inventoryBody.appendChild(empty);
  } else {
    inventory.forEach(function (item) {
      const row = element('tr');
      row.appendChild(element('td', 'path', item.id || '—'));
      row.appendChild(element('td', 'mono', item.source || '—'));
      row.appendChild(element('td', 'num', bytes(item.bytes)));
      row.appendChild(element('td')).appendChild(pill(item.complete ? 'complete' : 'incomplete'));
      inventoryBody.appendChild(row);
    });
  }

  const wired = data.wired || [];
  const wiredHeading = $('doctor-wired-heading');
  const wiredList = $('doctor-wired-list');
  wiredList.textContent = '';
  if (!wired.length) {
    wiredHeading.hidden = true;
  } else {
    wiredHeading.hidden = false;
    wired.forEach(function (item) {
      const row = element('div', 'file-row');
      row.appendChild(element('span', 'path', typeof item === 'string' ? item : (item.path || JSON.stringify(item))));
      wiredList.appendChild(row);
    });
  }

  const endpoints = data.endpoints || [];
  const endpointsHeading = $('doctor-endpoints-heading');
  const endpointsNode = $('doctor-endpoints');
  endpointsNode.textContent = '';
  if (!endpoints.length) {
    endpointsHeading.hidden = true;
  } else {
    endpointsHeading.hidden = false;
    endpoints.forEach(function (item) {
      const row = element('div', 'file-row');
      const label = typeof item === 'string' ? item :
        [(item.url || item.endpoint || ''), item.status || item.state || ''].filter(Boolean).join(' · ');
      row.appendChild(element('span', 'path', label || JSON.stringify(item)));
      endpointsNode.appendChild(row);
    });
  }
}

async function runScout(event) {
  event.preventDefault();
  notify('');
  const button = event.target.querySelector('[type="submit"]') || event.submitter;
  if (button) {
    button.disabled = true;
    button.textContent = 'Scouting…';
  }
  try {
    const data = await api('/api/scout', {
      body: {
        role: $('scout-role').value || null,
        limit: Number($('scout-limit').value) || null,
        fast: $('scout-fast').checked,
        new: $('scout-new').checked,
      },
    });
    renderScout(data);
  } catch (error) {
    notify(error.message);
  } finally {
    if (button) {
      button.disabled = false;
      button.textContent = 'Scout';
    }
  }
}

async function runDoctor(event) {
  event.preventDefault();
  notify('');
  const button = event.target.querySelector('[type="submit"]') || event.submitter;
  if (button) {
    button.disabled = true;
    button.textContent = 'Running…';
  }
  try {
    const data = await api('/api/doctor', {
      body: {
        wired_roots: lines($('doctor-wired')?.value || ''),
        hf_cache: $('doctor-hf').value.trim() || null,
      },
    });
    renderDoctor(data);
  } catch (error) {
    notify(error.message);
  } finally {
    if (button) {
      button.disabled = false;
      button.textContent = 'Run doctor';
    }
  }
}

async function previewPrune() {
  notify('');
  try {
    const data = await api('/api/doctor/prune/preview', {
      body: { hf_cache: $('doctor-hf').value.trim() || null },
    });
    const plan = data.plan || data;
    const candidates = plan.candidates || [];
    if (!candidates.length) {
      notify('Nothing to prune: no incomplete cache snapshots.');
      return;
    }
    state.pending = plan;
    state.pendingKind = 'prune';
    const list = candidates.map(function (item) {
      return (item.repo || item.path) + ' (' + bytes(item.bytes) + ')';
    }).join('\n');
    fillPlanDialog('Review incomplete cache prune', [
      ['Candidates', String(candidates.length)],
      ['Paths', list],
      ['Preview hash', plan.preview_hash],
    ], 'IRREVERSIBLE. Deletes incomplete HF cache directories only. Quarantine is unrelated.');
  } catch (error) {
    notify(error.message);
  }
}

async function previewLora(event) {
  event.preventDefault();
  notify('');
  const repo = $('lora-repo').value.trim();
  const dataDir = $('lora-data').value.trim();
  const itersValue = $('lora-iters').value.trim();
  const out = $('lora-out').value.trim();
  if (!repo || !dataDir) {
    notify('Base repo and dataset dir are required.');
    return;
  }
  try {
    const data = await api('/api/lora/preview', {
      body: {
        repo: repo,
        data: dataDir,
        iters: itersValue ? Number(itersValue) : null,
        out: out || null,
      },
    });
    const plan = data.plan || data;
    state.pending = {
      repo: repo,
      data: dataDir,
      iters: itersValue ? Number(itersValue) : null,
      out: out || null,
      preview_hash: plan.preview_hash,
    };
    state.pendingKind = 'lora';
    fillPlanDialog('Review LoRA training', [
      ['Repo', plan.repo || repo],
      ['Data', dataDir],
      ['Out', plan.out || out || 'default'],
      ['Command', (plan.argv || []).join(' ')],
      ['Preview hash', plan.preview_hash],
    ], 'Runs detached. Base model must already be in the HF cache; never downloads.');
  } catch (error) {
    notify(error.message);
  }
}

async function previewFuse(event) {
  event.preventDefault();
  notify('');
  const repo = $('fuse-repo').value.trim();
  const adapter = $('fuse-adapter').value.trim();
  const out = $('fuse-out').value.trim();
  if (!repo || !adapter) {
    notify('Base repo and adapter dir are required.');
    return;
  }
  try {
    const data = await api('/api/fuse/preview', {
      body: { repo: repo, adapter: adapter, out: out || null },
    });
    const plan = data.plan || data;
    state.pending = {
      repo: repo,
      adapter: adapter,
      out: out || null,
      preview_hash: plan.preview_hash,
    };
    state.pendingKind = 'fuse';
    fillPlanDialog('Review fuse', [
      ['Repo', plan.repo || repo],
      ['Adapter', adapter],
      ['Out', plan.out || out || 'default'],
      ['Command', (plan.argv || []).join(' ')],
      ['Preview hash', plan.preview_hash],
    ], 'Produces a standalone fused model. Never overwrites an existing out path.');
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
  if (!repo) {
    notify('Pick a converted model or enter a repo id already in the Hugging Face cache.');
    return;
  }
  const serve = state.runtime && state.runtime.serve;
  if (serve && !serve.ok) {
    notify(serve.message);
    return;
  }
  const maxTokensValue = $('serve-max-tokens').value.trim();
  const maxTokens = maxTokensValue ? Number(maxTokensValue) : null;
  const adapter = $('serve-adapter').value.trim() || null;
  try {
    const data = await api('/api/serve/preview', {
      body: {
        repo: repo, runtime: runtime, port: port,
        max_tokens: maxTokens, adapter_path: adapter,
      },
    });
    const plan = data.plan || data;
    state.pending = plan;
    state.pendingKind = 'serve';
    try { localStorage.setItem('mlx_workbench_serve_runtime', runtime); } catch (e) {}
    fillPlanDialog('Review this serve plan', [
      ['Model', plan.repo || repo],
      ['Runtime', plan.runtime || runtime],
      ['Port', String(plan.port || port || 'default')],
      ['Max tokens', String(plan.max_tokens || maxTokens || 'runtime default')],
      ['Adapter', plan.adapter_path || adapter || 'none'],
      ['Bind', plan.bind || '127.0.0.1'],
      ['Readiness', plan.readiness || '—'],
      ['Command', (plan.argv || []).join(' ')],
      ['Preview hash', plan.preview_hash],
    ], 'Loopback only. The model must already be in the Hugging Face cache; serve never downloads.');
  } catch (error) {
    notify(error.message);
  }
}

// Fill the serve model picker from the latest scan: converted MLX models
// become suggestions (their repo id when the model came from the HF cache,
// otherwise the local path), so the common case is pick-and-go.
function updateServeSuggestions() {
  const list = $('serve-model-options');
  if (!list) return;
  list.textContent = '';
  const scan = state.scan;
  if (!scan || !scan.models) return;
  const seen = {};
  scan.models.forEach(function (item) {
    if (item.status !== 'converted') return;
    const repo = (item.output && item.output.repo) || null;
    const value = repo || item.output_dir || null;
    if (!value || seen[value]) return;
    seen[value] = true;
    const option = element('option');
    option.value = value;
    option.label = item.name || value;
    list.appendChild(option);
  });
}

function restoreServeDefaults() {
  try {
    const runtime = localStorage.getItem('mlx_workbench_serve_runtime');
    if (runtime === 'mlx_lm' || runtime === 'mlx-vlm') {
      $('serve-runtime').value = runtime;
    }
  } catch (error) {
    // localStorage unavailable; defaults are fine.
  }
}

// MARK: serve presets (named endpoint profiles)

async function refreshPresets() {
  const select = $('serve-preset');
  if (!select) return;
  try {
    const data = await api('/api/serve/presets');
    const presets = data.presets || [];
    select.textContent = '';
    const blank = element('option');
    blank.value = '';
    blank.textContent = presets.length ? '— choose —' : '— no presets yet —';
    select.appendChild(blank);
    presets.forEach(function (preset) {
      const option = element('option');
      option.value = preset.id;
      option.textContent = preset.name + ' · ' + preset.model;
      option.dataset.preset = JSON.stringify(preset);
      select.appendChild(option);
    });
  } catch (error) {
    notify(error.message);
  }
}

function applyPreset() {
  const select = $('serve-preset');
  const option = select.selectedOptions[0];
  if (!option || !option.dataset.preset) {
    notify('Choose a preset to load first.');
    return;
  }
  const preset = JSON.parse(option.dataset.preset);
  $('serve-repo').value = preset.model;
  $('serve-runtime').value = preset.runtime;
  $('serve-port').value = preset.port != null ? String(preset.port) : '';
  $('serve-max-tokens').value = preset.max_tokens != null ? String(preset.max_tokens) : '';
  $('serve-adapter').value = preset.adapter_path || '';
  notify('Preset loaded: ' + preset.name + '. Review, then Preview & Start.');
}

function savePreset() {
  const repo = $('serve-repo').value.trim();
  const kind = repo.includes('/') && !repo.startsWith('/') ? 'repo' : 'path';
  if (!repo) {
    notify('Fill the form first — presets save the current model, runtime, port, and limits.');
    return;
  }
  const presetId = $('serve-preset').value || null;
  const preset = presetId
    ? JSON.parse($('serve-preset').selectedOptions[0].dataset.preset)
    : null;
  state.pending = {
    savePreset: true,
    id: presetId,
    previousName: preset ? preset.name : null,
    name: preset ? preset.name : '',
    model: repo,
    kind: preset ? preset.model_kind : kind,
    runtime: $('serve-runtime').value,
    port: $('serve-port').value.trim() ? Number($('serve-port').value) : null,
    max_tokens: $('serve-max-tokens').value.trim() ? Number($('serve-max-tokens').value) : null,
    adapter_path: $('serve-adapter').value.trim() || null,
  };
  state.pendingKind = 'serve-preset-save';
  fillPlanDialog(
    presetId ? 'Update preset' : 'Save serve preset',
    [
      ['Name', state.pending.name || '(you will be asked… actually edit below)'],
      ['Model', state.pending.model],
      ['Runtime', state.pending.runtime],
      ['Port', state.pending.port != null ? String(state.pending.port) : 'auto'],
      ['Max tokens', state.pending.max_tokens != null ? String(state.pending.max_tokens) : 'default'],
      ['Adapter', state.pending.adapter_path || 'none'],
    ],
    'Presets store model, runtime, port, max tokens, and adapter. Load one any time to relaunch in two clicks.',
  );
}

function deletePreset() {
  const select = $('serve-preset');
  const option = select.selectedOptions[0];
  if (!option || !option.dataset.preset) {
    notify('Choose a preset to delete first.');
    return;
  }
  const preset = JSON.parse(option.dataset.preset);
  state.pending = preset;
  state.pendingKind = 'serve-preset-delete';
  fillPlanDialog('Delete preset?', [
    ['Name', preset.name],
    ['Model', preset.model],
  ], 'The preset is removed. Running servers are untouched.');
}

async function suggestPort() {
  try {
    const data = await api('/api/serve/port');
    $('serve-port').value = String(data.port);
    notify('Free port found: ' + data.port);
  } catch (error) {
    notify(error.message);
  }
}

async function saveServePreset(pending) {
  const name = window.prompt('Preset name:', pending.previousName || pending.name || pending.model);
  if (name === null) return;
  if (!name.trim()) {
    notify('A preset needs a name.');
    return;
  }
  await api('/api/serve/presets', {
    body: {
      id: pending.id,
      name: name.trim(),
      model: pending.model,
      kind: pending.kind,
      runtime: pending.runtime,
      port: pending.port,
      max_tokens: pending.max_tokens,
      adapter_path: pending.adapter_path,
    },
  });
  await refreshPresets();
  notify('Preset saved.');
}

async function visualizeArchitecture(event) {
  event.preventDefault();
  notify('');
  const path = $('arch-path').value.trim();
  
  if (!path) {
    notify('Enter model path or repo.');
    return;
  }
  
  try {
    const data = await api('/api/model/arch', { 
      body: { path: path } 
    });
    renderArchitecture(data);
  } catch (error) {
    notify(error.message);
  }
}

function renderArchitecture(data) {
  const container = $('arch-structure');
  container.textContent = '';
  if (!data || !data.architecture) {
    container.appendChild(element('p', 'empty', 'Could not load model metadata.'));
    return;
  }

  const arch = data.architecture;
  const tree = element('div', 'arch-tree');
  tree.appendChild(element('h3', null, arch.name || arch.model_path || 'Model'));
  const facts = MLXWorkbenchArchitecture.architectureFacts(arch, bytes);
  if (facts.length) {
    const details = element('dl', 'arch-info');
    facts.forEach(function (fact) {
      details.appendChild(element('dt', null, fact[0]));
      details.appendChild(element('dd', null, fact[1]));
    });
    tree.appendChild(details);
  }
  tree.appendChild(element(
    'p',
    'hint',
    'Detailed transformer topology is not reported by the installed mlx-agent version.',
  ));
  container.appendChild(tree);
}

async function profileQuantizations(event) {
  event.preventDefault();
  notify('');
  const path = $('quant-path').value.trim();
  if (!path) {
    notify('Enter a model path or hf-cache repo.');
    return;
  }
  const targets = Array.prototype.map.call(
    document.querySelectorAll('#quant-targets option'),
    function (option) { return option.value; }
  ).filter(function (value) {
    return document.querySelector('#quant-targets option[value="' + value + '"]').selected;
  });
  if (!targets.length) {
    notify('Select at least one target format.');
    return;
  }
  try {
    const data = await api('/api/quant/profile', { body: { path: path, targets: targets } });
    renderQuantResults(data);
  } catch (error) {
    notify(error.message);
  }
}

function renderQuantResults(data) {
  const container = $('quant-results');
  container.textContent = '';
  if (!data || !data.profiles || !data.profiles.length) {
    container.appendChild(element('p', 'empty', 'No profiling data available.'));
    return;
  }

  const grid = element('div', 'grid quant-grid');
  grid.appendChild(element('h3', null, 'Quantization Profiles'));

  data.profiles.forEach(function (profile) {
    const card = element('div', 'quant-card');
    card.appendChild(element('h4', null, profile.target));
    const facts = element('dl');
    facts.appendChild(element('dt', null, 'Source size'));
    facts.appendChild(element('dd', null, bytes(profile.source_bytes)));
    facts.appendChild(element('dt', null, 'Destination'));
    facts.appendChild(element('dd', null, profile.output || '—'));
    facts.appendChild(element('dt', null, 'Preview'));
    facts.appendChild(element(
      'dd', null, profile.preview_hash ? 'Ready; confirmation required.' : '—'
    ));
    if (profile.command) {
      facts.appendChild(element('dt', null, 'Command'));
      const command = element('dd');
      command.appendChild(element('code', null, profile.command.join(' ')));
      facts.appendChild(command);
    }
    card.appendChild(facts);

    if (profile.actions && profile.actions.length) {
      const actions = element('div', 'quant-actions');
      profile.actions.forEach(function (action) {
        if (action.type === 'convert') {
          const button = element('button', 'quant-convert', action.label);
          button.dataset.path = action.path || '';
          button.dataset.target = profile.target;
          actions.appendChild(button);
        }
      });
      card.appendChild(actions);
    }
    grid.appendChild(card);
  });

  container.appendChild(grid);
}

function fillSettings(data) {
  const config = data.config;
  state.config = config;
  state.runtime = data.runtime || null;
  $('gguf_roots').value = (config.gguf_roots || []).join('\n');
  $('mlx_roots').value = (config.mlx_roots || []).join('\n');
  $('output_dir').value = config.output_dir || '';
  $('host').value = config.host || '127.0.0.1';
  $('port').value = String(config.port || 8765);
  $('mlx_agent_path').value = config.mlx_agent_path || '';
  $('quarantine_dir').value = config.quarantine_dir || '';
  $('q_bits').value = String(config.q_bits || 4);
  $('signatures').checked = Boolean(config.signatures);
  $('config-path').value = data.config_path;
  const health = data.agent || {};
  $('agent-health').textContent = health.ok
    ? 'Agent ready: ' + health.path
    : (health.message || 'Agent not configured.') +
      (data.vendor_agent_path ? ' Vendor path: ' + data.vendor_agent_path : '');
  const runtime = data.runtime || {};
  const convert = runtime.convert || {};
  const serve = runtime.serve || {};
  const runtimeNode = $('runtime-health');
  if (convert.ok && serve.ok) {
    runtimeNode.textContent = 'Convert + Serve runtimes ready in this interpreter.';
  } else {
    runtimeNode.textContent =
      (convert.message || '') +
      (serve.ok ? '' : ' ' + (serve.message || '')) +
      ' Optional — scan/Scout/Doctor work without them.';
  }
}

async function discardSettings(event) {
  if (event) {
    event.preventDefault();
  }
  try {
    const data = await api('/api/config');
    fillSettings(data);
    notify('');
  } catch (error) {
    notify(error.message);
  }
}

function warnConvertDeps() {
  const convert = state.runtime && state.runtime.convert;
  if (convert && !convert.ok) {
    notify(convert.message);
    return true;
  }
  return false;
}

function lines(value) {
  return value.split('\n').map(function (item) { return item.trim(); })
    .filter(function (item) { return item.length > 0; });
}

async function saveSettings(event) {
  event.preventDefault();
  try {
    const host = $('host').value.trim();
    const port = Number($('port').value);
    if (!['127.0.0.1', 'localhost', '::1'].includes(host)) {
      throw new Error('Host must be 127.0.0.1, localhost, or ::1.');
    }
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error('Port must be an integer between 1 and 65535.');
    }
    const data = await api('/api/config', {
      body: {
        gguf_roots: lines($('gguf_roots').value),
        mlx_roots: lines($('mlx_roots').value),
        output_dir: $('output_dir').value.trim(),
        host: host,
        port: port,
        mlx_agent_path: $('mlx_agent_path').value.trim(),
        quarantine_dir: $('quarantine_dir').value.trim(),
        q_bits: Number($('q_bits').value),
        signatures: $('signatures').checked,
      },
    });
    fillSettings({
      config: data.config,
      config_path: $('config-path').value,
      agent: data.agent,
      runtime: data.runtime,
      vendor_agent_path: data.vendor_agent_path,
    });
    notify('');
    await rescan({ force: true });
  } catch (error) {
    notify(error.message);
  }
}

function selectPanel(name) {
  MLXWorkbenchNavigation.selectPanel(document, name, PANELS);
  if (name === 'jobs') {
    refreshJobs();
  } else if (state.jobTimer) {
    clearInterval(state.jobTimer);
    state.jobTimer = null;
  }
  if (name === 'duplicates') renderQuarantined();
  if (name === 'serve') {
    refreshJobs();
    updateServeSuggestions();
    restoreServeDefaults();
    refreshPresets();
  }
}

async function scanDuplicates() {
  notify('');
  const panel = document.getElementById('panel-duplicates');
  if (panel.hidden) selectPanel('duplicates');
  
  try {
    const data = await api('/api/duplicates/scan', { body: {} });
    state.duplicateScan = data.duplicates || [];
    renderDuplicateScan(state.duplicateScan);
    
    notify('Duplicate scan complete');
  } catch (error) {
    notify(error.message);
  }
}

function renderDuplicateScan(dupes) {
  const container = document.getElementById('exact-duplicates');
  if (!container) return;
  container.textContent = '';
  const emptyMessage = MLXWorkbenchLibraryViews.duplicateScanMessage(dupes);
  if (emptyMessage) {
    container.appendChild(element('p', 'empty', emptyMessage));
    return;
  }

  const groups = MLXWorkbenchDuplicates.splitGroups(dupes);
  const exactGroups = groups.exact;
  const variantGroups = groups.variant;
  if (exactGroups.length) {
    container.appendChild(element(
      'p',
      'muted',
      'Only exact groups receive a quarantine action. Moving a file is recoverable and requires confirmation.',
    ));
    exactGroups.forEach(function (group) {
      const card = element('div', 'group');
      card.appendChild(element(
        'strong',
        null,
        group.model_key + ' · ' + group.quantization + ' · ' + bytes(group.reclaimable_bytes) + ' reclaimable',
      ));
      const keep = element('div', 'file-row');
      keep.appendChild(element('span', 'pill pill-converted', 'keep'));
      keep.appendChild(element('span', 'path', group.keep));
      card.appendChild(keep);
      group.redundant.forEach(function (path) {
        const row = element('div', 'file-row');
        row.appendChild(element('span', 'pill pill-pending', 'redundant'));
        row.appendChild(element('span', 'path', path));
        const move = element('button', 'danger', 'Move to quarantine');
        move.addEventListener('click', function () {
          state.pending = { path: path, button: move };
          state.pendingKind = 'quarantine';
          state.pendingBatch = null;
          fillPlanDialog('Review duplicate quarantine', [
            ['File', path],
            ['Action', 'Move to quarantine'],
          ], 'Recoverable action. The file will be moved aside and recorded, not permanently deleted.');
        });
        row.appendChild(move);
        card.appendChild(row);
      });
      container.appendChild(card);
    });
  }
  if (variantGroups.length) {
    container.appendChild(element('h4', null, 'Variants (informational)'));
    variantGroups.forEach(function (group) {
      const card = element('div', 'group');
      card.appendChild(element(
        'strong',
        null,
        group.model_key + ' · ' + group.quantizations.join(', '),
      ));
      card.appendChild(element('p', 'hint', 'Different quantizations are not removal recommendations.'));
      group.members.forEach(function (path) {
        card.appendChild(element('div', 'path', path));
      });
      container.appendChild(card);
    });
  }
}

function showModelDetails(path) {
  const modal = document.getElementById('model-details-modal');
  const title = document.getElementById('model-details-title');
  const contentDiv = document.getElementById('model-details-content');
  if (!path || !modal || !title || !contentDiv) return;
  const model = state.scan && (state.scan.models || []).find(function (item) {
    return item.path === path;
  });

  title.textContent = (model && model.name) || path.split('/').pop();
  contentDiv.textContent = '';
  if (!model) {
    contentDiv.appendChild(element('p', null, 'Details are unavailable until this path appears in the current scan.'));
    modal.hidden = false;
    return;
  }

  const facts = MLXWorkbenchLibraryViews.modelDetailsFacts(model, bytes);
  const list = element('dl');
  facts.forEach(function (fact) {
    list.appendChild(element('dt', null, fact[0]));
    list.appendChild(element('dd', fact[0] === 'Local path' ? 'path' : null, fact[1]));
  });
  contentDiv.appendChild(list);
  if (model.outputs && model.outputs.length) {
    contentDiv.appendChild(element('h3', null, 'Output paths'));
    const outputs = element('ul');
    model.outputs.forEach(function (output) {
      outputs.appendChild(element('li', 'path', output));
    });
    contentDiv.appendChild(outputs);
  }
  modal.hidden = false;
}

function init() {
  on('tabs', 'click', function (event) {
    if (event.target.dataset.panel) selectPanel(event.target.dataset.panel);
  });
  on('models', 'click', function (event) {
    const row = event.target.closest('.clickable');
    if (row && !event.target.closest('button, input')) showModelDetails(row.dataset.modelPath);
  });
  on('close-model-details', 'click', function () {
    $('model-details-modal').hidden = true;
  });
  on('rescan', 'click', function () { rescan({ force: true }); });
  on('pending-only', 'change', renderModels);
  on('queue-selected', 'click', queueSelectedModels);
  on('select-all-models', 'change', function () {
    const on = $('select-all-models').checked;
    Array.prototype.forEach.call(document.querySelectorAll('#models .model-select'), function (box) {
      box.checked = on;
    });
  });
  on('hf-convert-form', 'submit', openHfConvertPlan);
  on('settings', 'submit', saveSettings);
  on('settings-reset', 'click', discardSettings);
  on('scout-form', 'submit', runScout);
  on('doctor-form', 'submit', runDoctor);
  on('doctor-prune', 'click', previewPrune);
  on('lora-form', 'submit', previewLora);
  on('fuse-form', 'submit', previewFuse);
  on('serve-form', 'submit', previewServe);
  on('serve-preset-apply', 'click', applyPreset);
  on('serve-preset-save', 'click', savePreset);
  on('serve-preset-delete', 'click', deletePreset);
  on('serve-port-auto', 'click', suggestPort);
  on('serve-refresh', 'click', refreshJobs);
  on('quant-form', 'submit', profileQuantizations);
  on('arch-form', 'submit', visualizeArchitecture);
  on('confirm', 'click', confirmPlan);
  on('cancel', 'click', closeDialog);
  on('rescan-models', 'click', function () { rescan({ force: true }); });
  on('scan-duplicates', 'click', scanDuplicates);
  on('convert-selected', 'click', queueSelectedModels);

  // Dropdown menu toggle
  on('more-tabs-btn', 'click', function () {
    const dropdown = document.querySelector('.more-dropdown');
    if (dropdown) dropdown.hidden = !dropdown.hidden;
  });

  // Close dropdown when clicking outside
  document.addEventListener('click', function (event) {
    const moreMenu = document.querySelector('.more-menu');
    if (moreMenu && !moreMenu.contains(event.target)) {
      const dropdown = document.querySelector('.more-dropdown');
      if (dropdown && !dropdown.hidden) {
        dropdown.hidden = true;
      }
    }
  });

  api('/api/config').then(function (data) {
    fillSettings(data);
    
    // Check if we should auto-scan for duplicates on first run
    const hasRunBefore = sessionStorage.getItem('mlx_workbench_duplicates_scanned');
    if (!hasRunBefore && data.agent && data.agent.ok) {
      setTimeout(function() { scanDuplicates(); }, 500);
      sessionStorage.setItem('mlx_workbench_duplicates_scanned', 'true');
    }
    
    if (!data.agent || !data.agent.ok) {
      notify((data.agent && data.agent.message) ||
        'No mlx-agent checkout configured. Init the vendor submodule or set it under Settings.');
      selectPanel('settings');
      return;
    }
    if (data.runtime && data.runtime.convert && !data.runtime.convert.ok) {
      console.info(data.runtime.convert.message);
    }
    
    // Auto-rescan to populate models on first run
    setTimeout(function () { rescan({ force: false }); }, 100);
  }).catch(function (error) { notify(error.message); });
}

init();
