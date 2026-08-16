defmodule ScenicRg40xxv.Web.Page do
  @moduledoc """
  The one page, as one string.

  No template engine, no asset pipeline, no build step. The page is small
  enough to read in full, it changes when this file changes, and there is
  nothing between the source and what the phone renders.

  Everything is inline because the alternative is serving four more files
  from a device that has no static file plug and no reason to grow one.

  Laid out for a phone held in one hand, because that is the machine it will
  be opened from -- large tap targets, one column, no hover states.
  """

  @doc """
  The page.
  """
  def render, do: html()

  defp html do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>RG40XXV</title>
    <style>#{css()}</style>
    </head>
    <body>
    <header>
      <h1>RG40XXV</h1>
      <p id="free"></p>
    </header>

    <main id="app">
      <p class="muted">Loading…</p>
    </main>

    <div id="toast" hidden></div>

    <script>#{js()}</script>
    </body>
    </html>
    """
  end

  defp css do
    """
    :root {
      --bg: #14161a; --panel: #1d2026; --line: #2c313a;
      --fg: #e8eaed; --muted: #9aa3ad; --accent: #6ea8fe;
      --ok: #5fd08a; --bad: #ff6b6b;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--bg); color: var(--fg);
      font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
      padding: env(safe-area-inset-top) 0 3rem;
    }
    header {
      padding: 1.25rem 1rem 0.75rem; border-bottom: 1px solid var(--line);
      position: sticky; top: 0; background: var(--bg); z-index: 2;
    }
    h1 { margin: 0; font-size: 1.25rem; letter-spacing: 0.02em; }
    h2 {
      margin: 1.75rem 1rem 0.5rem; font-size: 0.8rem; text-transform: uppercase;
      letter-spacing: 0.08em; color: var(--muted); font-weight: 600;
    }
    p { margin: 0.25rem 0 0; }
    .muted { color: var(--muted); font-size: 0.875rem; }
    .panel {
      background: var(--panel); border: 1px solid var(--line);
      border-radius: 12px; margin: 0 0.75rem; overflow: hidden;
    }
    .row {
      display: flex; align-items: center; gap: 0.75rem;
      padding: 0.75rem 0.9rem; border-top: 1px solid var(--line);
    }
    .row:first-child { border-top: 0; }
    .row .name { flex: 1; min-width: 0; overflow-wrap: anywhere; }
    .row .size { color: var(--muted); font-size: 0.8rem; white-space: nowrap; }
    .empty { padding: 0.9rem; color: var(--muted); font-size: 0.875rem; }
    button {
      font: inherit; font-size: 0.875rem; border-radius: 8px; padding: 0.5rem 0.85rem;
      border: 1px solid var(--line); background: #262b33; color: var(--fg);
      min-height: 40px; cursor: pointer;
    }
    button.primary { background: var(--accent); border-color: var(--accent); color: #10131a; font-weight: 600; }
    button[disabled] { opacity: 0.45; cursor: default; }
    button.danger { color: var(--bad); }
    label.upload {
      display: block; margin: 0.75rem; padding: 1.1rem; text-align: center;
      border: 1px dashed var(--line); border-radius: 12px; color: var(--accent);
      font-weight: 600; cursor: pointer;
    }
    label.upload input { display: none; }
    progress { width: 100%; height: 6px; margin-top: 0.5rem; }
    .tag {
      font-size: 0.7rem; padding: 0.15rem 0.45rem; border-radius: 999px;
      border: 1px solid var(--line); color: var(--muted); white-space: nowrap;
    }
    .tag.on { color: var(--ok); border-color: var(--ok); }
    #toast {
      position: fixed; left: 0.75rem; right: 0.75rem; bottom: 0.75rem;
      background: var(--panel); border: 1px solid var(--line); border-radius: 10px;
      padding: 0.75rem 0.9rem; font-size: 0.875rem; z-index: 3;
    }
    #toast.bad { border-color: var(--bad); color: var(--bad); }
    """
  end

  defp js do
    """
    const app = document.getElementById('app');
    const toastEl = document.getElementById('toast');
    let state = null;

    const esc = s => String(s).replace(/[&<>"']/g, c =>
      ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

    const size = n => {
      if (n === null || n === undefined) return '';
      const u = ['B','KB','MB','GB'];
      let i = 0; while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
      return (i === 0 ? n : n.toFixed(1)) + ' ' + u[i];
    };

    let toastTimer;
    function toast(msg, bad) {
      toastEl.textContent = msg;
      toastEl.className = bad ? 'bad' : '';
      toastEl.hidden = false;
      clearTimeout(toastTimer);
      toastTimer = setTimeout(() => { toastEl.hidden = true; }, 4000);
    }

    async function load() {
      const r = await fetch('/api/library');
      state = await r.json();
      render();
    }

    function render() {
      const free = state.free_bytes ? size(state.free_bytes) + ' free' : '';
      document.getElementById('free').textContent = free;
      document.getElementById('free').className = 'muted';

      let html = '';

      for (const sys of state.systems) {
        html += '<h2>' + esc(sys.name) + '</h2><div class="panel">';
        html += '<label class="upload">Add a game' +
          '<input type="file" multiple accept="' + esc(sys.extensions.join(',')) + '"' +
          ' data-system="' + esc(sys.key) + '"></label>';
        if (sys.entries.length === 0) {
          html += '<div class="empty">Nothing here yet. ' +
            esc(sys.extensions.join(', ')) + '</div>';
        }
        for (const e of sys.entries) {
          html += '<div class="row"><span class="name">' + esc(e.name) + '</span>' +
            '<span class="size">' + size(e.size) + '</span>' +
            '<button class="danger" data-delete="' + esc(e.name) + '"' +
            ' data-system="' + esc(sys.key) + '">Delete</button></div>';
        }
        html += '</div>';
      }

      if (state.cores.length) {
        html += '<h2>Emulator cores</h2><div class="panel">';
        for (const c of state.cores) {
          const tag = c.available
            ? '<span class="tag on">installed</span>'
            : '<span class="tag">' + esc(c.version) + '</span>';
          const btn = c.available
            ? ''
            : '<button class="primary" data-core="' + esc(c.key) + '">Install</button>';
          html += '<div class="row"><span class="name">' + esc(c.label) + '</span>' +
            tag + btn + '</div>';
        }
        html += '</div>';
      }

      app.innerHTML = html;
      wire();
    }

    function wire() {
      app.querySelectorAll('input[type=file]').forEach(input => {
        input.addEventListener('change', () => {
          const files = Array.from(input.files);
          input.value = '';
          queue(input.dataset.system, files);
        });
      });
      app.querySelectorAll('[data-delete]').forEach(b => {
        b.addEventListener('click', () => del(b.dataset.system, b.dataset.delete, b));
      });
      app.querySelectorAll('[data-core]').forEach(b => {
        b.addEventListener('click', () => installCore(b.dataset.core, b));
      });
    }

    // One at a time. Parallel uploads to a four-core handheld writing to f2fs
    // are slower in total and make the progress bar meaningless.
    async function queue(system, files) {
      for (const f of files) {
        try { await upload(system, f); }
        catch (e) { toast(f.name + ': ' + e.message, true); }
      }
      await load();
    }

    // XHR rather than fetch: fetch has no upload progress event, and on a
    // 700 MB image over WiFi a page with no progress looks like a page that
    // has crashed.
    function upload(system, file) {
      return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open('PUT', '/api/roms/' + encodeURIComponent(system) + '/' +
                 encodeURIComponent(file.name));
        xhr.upload.onprogress = e => {
          if (e.lengthComputable) {
            const pct = Math.round(e.loaded / e.total * 100);
            toast(file.name + ' — ' + pct + '%');
          }
        };
        xhr.onload = () => {
          if (xhr.status >= 200 && xhr.status < 300) { toast(file.name + ' — done'); resolve(); }
          else {
            let msg = 'HTTP ' + xhr.status;
            try { msg = JSON.parse(xhr.responseText).error || msg; } catch (_) {}
            reject(new Error(msg));
          }
        };
        xhr.onerror = () => reject(new Error('connection lost'));
        xhr.send(file);
      });
    }

    async function del(system, name, btn) {
      btn.disabled = true;
      const r = await fetch('/api/roms/' + encodeURIComponent(system) + '/' +
                            encodeURIComponent(name), { method: 'DELETE' });
      if (!r.ok) { toast('Could not delete ' + name, true); btn.disabled = false; return; }
      toast('Deleted ' + name);
      await load();
    }

    async function installCore(key, btn) {
      btn.disabled = true;
      btn.textContent = 'Installing…';
      try {
        const r = await fetch('/api/cores/' + encodeURIComponent(key) + '/install',
                              { method: 'POST' });
        const body = await r.json();
        if (!r.ok) throw new Error(body.error || ('HTTP ' + r.status));
        toast(body.changed === false ? 'Already installed' : 'Installed');
      } catch (e) {
        toast('Install failed: ' + e.message, true);
      }
      await load();
    }

    load().catch(e => { app.innerHTML = '<p class="muted">Could not load: ' +
      esc(e.message) + '</p>'; });
    """
  end
end
