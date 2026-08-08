'use strict';

const TOKEN = document.querySelector('meta[name="mlx-token"]').content;
const PANELS = [
  'models', 'convert', 'duplicates', 'scout', 'adopt', 'wire', 'doctor', 'serve', 'train',
  'quant', 'jobs', 'advanced', 'settings',
];
const state = {
  scan: null,
  config: null,
  runtime: null,
  pending: null,
  pendingKind: null,
  pendingBatch: null,
  selectedLog: null,
  logManual: false,
  jobTimer: null,
  jobBusy: false,
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
    empty.appendChild(element('td', 'empty', 'Nothing to show.')).colSpan = 8;
    body.appendChild(empty);
    return;
  }
  rows.forEach(function (item) {
    const row = element('tr');
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
  queueErrorNode.textContent = queueErrors.join('\n');
  queueErrorNode.hidden = queueErrors.length === 0;
  renderConvertQueue(data.convert_queue || []);
  const runningConvert = jobs.find(function (job) { return job.state === 'running'; });
  state.jobBusy = Boolean(runningConvert) || (data.convert_queue || []).length > 0;
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
  node.appendChild(element('strong', null, 'Conversion queue (' + queue.length + ')'));
  queue.forEach(function (item) {
    const row = element('div', 'queue-item');
    row.appendChild(element('span', 'path', item.label || item.path || item.repo || item.id));
    const stateHint = item.state === 'starting'
      ? 'starting · reconciling accepted launch'
      : 'queued';
    row.appendChild(element('span', 'hint', item.q_bits + '-bit · ' + stateHint));
    const cancel = element('button', null, 'Cancel');
    if (item.state === 'starting') {
      cancel.disabled = true;
      cancel.title = 'This launch is being reconciled with its mlx-agent receipt.';
    }
    cancel.addEventListener('click', async function () {
      cancel.disabled = true;
      try {
        await api('/api/convert/queue/cancel', { body: { id: item.id } });
        await refreshJobs();
      } catch (error) {
        notify(error.message);
        cancel.disabled = false;
      }
    });
    row.appendChild(cancel);
    node.appendChild(row);
  });
  const clear = element('button', null, 'Clear queue');
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
  const button = $('queue-selected');
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
  const body = {
    q_bits: plan.q_bits,
    out: plan.out,
    preview_hash: plan.preview_hash,
  };
  if (plan.source && plan.source.path) {
    body.path = plan.source.path;
  } else if (plan.repo) {
    body.repo = plan.repo;
  }
  return body;
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
    } else if (state.pendingKind === 'wire') {
      await api('/api/wire/apply', {
        body: {
          model: state.pending.model,
          path: state.pending.path,
          target: state.pending.target,
          preview_hash: state.pending.preview_hash,
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
    } else if (kind === 'wire' || kind === 'adopt') {
      notify('Done.');
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
        const wire = element('button', null, 'Wire');
        wire.addEventListener('click', function () {
          $('wire-model').value = model.repo || '';
          selectPanel('wire');
          notify('Repo loaded into Wire.');
        });
        actions.appendChild(serve);
        actions.appendChild(wire);
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
    ' · ' + bytes(summary.hf_cache_bytes || 0) + ' in HF cache' +
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
      row.appendChild(element('td', 'num', bytes(item.bytes || 0)));
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
        wired_roots: lines($('doctor-wired').value),
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
      return (item.repo || item.path) + ' (' + bytes(item.bytes || 0) + ')';
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

async function runAdopt(event) {
  event.preventDefault();
  notify('');
  try {
    const data = await api('/api/adopt/start', {
      body: {
        role: $('adopt-role').value || null,
        state: $('adopt-state').value.trim() || null,
        fast: $('adopt-fast').checked,
        offline: $('adopt-offline').checked,
      },
    });
    showJson($('adopt-out'), data);
    const pick = data.recommendation && data.recommendation.repo;
    if (pick) {
      $('wire-model').value = pick;
      notify('Adopt finished. Recommendation loaded into Wire: ' + pick);
    }
  } catch (error) {
    notify(error.message);
  }
}

async function previewWire(event) {
  event.preventDefault();
  notify('');
  const model = $('wire-model').value.trim();
  const path = $('wire-path').value.trim();
  const target = $('wire-target').value;
  if (!model || !path) {
    notify('Model and config path are required.');
    return;
  }
  try {
    const data = await api('/api/wire/preview', {
      body: { model: model, path: path, target: target },
    });
    const plan = data.plan || data.preview || data;
    state.pending = {
      model: model,
      path: path,
      target: target,
      preview_hash: plan.preview_hash || (plan.preview && plan.preview.preview_hash),
      raw: plan,
    };
    state.pendingKind = 'wire';
    fillPlanDialog('Review wire apply', [
      ['Model', model],
      ['Target', target],
      ['Path', path],
      ['Preview hash', state.pending.preview_hash || '—'],
    ], 'Applies a confirmation-gated config transaction. Receipt-owned files only.');
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
    notify('Enter a repo id that is already in the Hugging Face cache.');
    return;
  }
  const serve = state.runtime && state.runtime.serve;
  if (serve && !serve.ok) {
    notify(serve.message);
    return;
  }
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
      ['Bind', plan.bind || '127.0.0.1'],
      ['Readiness', plan.readiness || '—'],
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
  if (!data || !data.profiles || !data.profiles.length) {
    container.innerHTML = '<p class="empty">No profiling data available.</p>';
    return;
  }
  
  let html = '<div class="grid quant-grid">';
  html += '<h3>Quantization Profiles</h3>';
  
  data.profiles.forEach(function (profile, index) {
    html += '<div class="quant-card">';
    html += '<h4>' + profile.target + '</h4>';
    html += '<dl>';
    html += '<dt>Size</dt><dd>' + bytes(profile.size) + '</dd>';
    html += '<dt>Estimated Tokens/Sec</dt><dd>' + (profile.tokens_per_sec || '—') + '</dd>';
    html += '<dt>Estimated VRAM</dt><dd>' + (profile.vram || '—') + '</dd>';
    if (profile.comparison) {
      html += '<dt>Quality vs Base</dt><dd>' + profile.comparison.quality_percent + '</dd>';
    }
    if (profile.command) {
      html += '<dt>Command</dt><dd><code>' + profile.command.join(' ') + '</code></dd>';
    }
    html += '</dl>';
    
    if (profile.actions && profile.actions.length) {
      html += '<div class="quant-actions">';
      profile.actions.forEach(function (action) {
        if (action.type === 'convert') {
          html += '<button class="quant-convert" data-path="' + (action.path || '') + '" ' +
            'data-target="' + profile.target + '">' + action.label + '</button>';
        }
      });
      html += '</div>';
    }
    html += '</div>';
  });
  
  html += '</div>';
  container.innerHTML = html;
}

function fillSettings(data) {
  const config = data.config;
  state.config = config;
  state.runtime = data.runtime || null;
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
      runtime: data.runtime,
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
  $('queue-selected').addEventListener('click', queueSelectedModels);
  $('select-all-models').addEventListener('change', function () {
    const on = $('select-all-models').checked;
    Array.prototype.forEach.call(document.querySelectorAll('#models .model-select'), function (box) {
      box.checked = on;
    });
  });
  $('hf-convert-form').addEventListener('submit', openHfConvertPlan);
  $('settings').addEventListener('submit', saveSettings);
  $('scout-form').addEventListener('submit', runScout);
  $('doctor-form').addEventListener('submit', runDoctor);
  $('doctor-prune').addEventListener('click', previewPrune);
  $('adopt-form').addEventListener('submit', runAdopt);
  $('wire-form').addEventListener('submit', previewWire);
  $('lora-form').addEventListener('submit', previewLora);
  $('fuse-form').addEventListener('submit', previewFuse);
  $('serve-form').addEventListener('submit', previewServe);
  $('serve-refresh').addEventListener('click', refreshJobs);
  $('quant-form').addEventListener('submit', profileQuantizations);
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
    if (data.runtime && data.runtime.convert && !data.runtime.convert.ok) {
      // Soft hint once; scan still works.
      console.info(data.runtime.convert.message);
    }
    return rescan();
  }).catch(function (error) { notify(error.message); });
}

init();
