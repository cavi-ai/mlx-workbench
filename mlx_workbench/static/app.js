'use strict';

const TOKEN = document.querySelector('meta[name="mlx-token"]').content;
const state = { scan: null, config: null, pending: null };

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
      convert.addEventListener('click', function () { openPlan(item.path); });
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

function renderJobs(jobs) {
  const body = $('jobs');
  body.textContent = '';
  if (!jobs.length) {
    const empty = element('tr');
    empty.appendChild(element('td', 'empty', 'No conversion receipts yet.')).colSpan = 5;
    body.appendChild(empty);
    return;
  }
  jobs.forEach(function (job) {
    const row = element('tr');
    row.appendChild(element('td')).appendChild(pill(job.state));
    const source = element('td');
    source.appendChild(element('span', 'path', job.repo));
    row.appendChild(source);
    row.appendChild(element('td', 'path', job.out));
    row.appendChild(element('td', 'hint', job.started_at || '—'));
    row.appendChild(element('td', 'path', job.log_path || '—'));
    body.appendChild(row);
  });
}

async function openPlan(path) {
  notify('');
  try {
    const data = await api('/api/convert/preview', { body: { path: path, q_bits: quantBits() } });
    state.pending = data.plan;
    const list = $('plan');
    list.textContent = '';
    [
      ['Source', data.plan.source.path || data.plan.repo],
      ['Output', data.plan.out],
      ['Quantization', data.plan.q_bits + '-bit'],
      ['Command', data.plan.argv.join(' ')],
      ['Preview hash', data.plan.preview_hash],
    ].forEach(function (pair) {
      list.appendChild(element('dt', null, pair[0]));
      list.appendChild(element('dd', null, pair[1]));
    });
    $('dialog').hidden = false;
  } catch (error) {
    notify(error.message);
  }
}

function quantBits() {
  return Number($('q_bits').value) || 4;
}

async function confirmPlan() {
  if (!state.pending) return;
  const button = $('confirm');
  button.disabled = true;
  try {
    await api('/api/convert/start', {
      body: {
        path: state.pending.source.path,
        q_bits: state.pending.q_bits,
        out: state.pending.out,
        preview_hash: state.pending.preview_hash,
      },
    });
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
    renderJobs((await api('/api/jobs')).jobs || []);
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
    fillSettings({ config: data.config, config_path: $('config-path').textContent });
    notify('');
    await rescan();
  } catch (error) {
    notify(error.message);
  }
}

function selectPanel(name) {
  ['models', 'duplicates', 'jobs', 'settings'].forEach(function (panel) {
    $('panel-' + panel).hidden = panel !== name;
  });
  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (tab) {
    tab.classList.toggle('is-active', tab.dataset.panel === name);
  });
  if (name === 'jobs') refreshJobs();
  if (name === 'duplicates') renderQuarantined();
}

function init() {
  $('tabs').addEventListener('click', function (event) {
    if (event.target.dataset.panel) selectPanel(event.target.dataset.panel);
  });
  $('rescan').addEventListener('click', rescan);
  $('pending-only').addEventListener('change', renderModels);
  $('settings').addEventListener('submit', saveSettings);
  $('confirm').addEventListener('click', confirmPlan);
  $('cancel').addEventListener('click', closeDialog);

  api('/api/config').then(function (data) {
    fillSettings(data);
    if (!data.config.mlx_agent_path) {
      notify('No mlx-agent checkout configured. Set it under Settings before scanning.');
      selectPanel('settings');
      return;
    }
    return rescan();
  }).catch(function (error) { notify(error.message); });
}

init();
