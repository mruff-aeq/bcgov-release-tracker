// Turns a generated report (headings, run logs, lists, and the inline data each
// <pre> carries; see emit_view_data in report-data.sh) into the styled page.
//   Dynamic (default): a custom range, bounded by the `test` runs in the section's
//     run log. Starts on the same range as optimistic wherever the log allows.
//     Post-release picks both ends; pre-release picks a start, ending at main.
//   Optimistic: the list the report has always shown.
// Report text only ever goes in via textContent: PR titles are untrusted.
(function () {
  const REPORT = document.body.dataset.report;
  const REPORT_LINKS = { pre: "../pre-release-report/pre-release-report.html", post: "../post-release-report/post-release-report.html" };
  const HEAD_CACHE_MS = 5 * 60 * 1000;
  const MISC_TITLE = "Miscellaneous business-ui";
  let dynamic = true;

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function externalLink(text, href) {
    const a = el("a", null, text);
    a.href = href;
    a.target = "_blank";
    a.rel = "noopener";
    return a;
  }

  // Section = an <h2> plus its siblings up to the next <hr>.
  function readSections() {
    return [...document.querySelectorAll("h2")].map((h2) => {
      const section = { title: h2.textContent.trim(), pre: null, list: null };
      for (let n = h2.nextElementSibling; n && n.tagName !== "HR"; n = n.nextElementSibling) {
        if (n.tagName === "PRE") section.pre = n;
        if (n.tagName === "UL") section.list = n;
      }
      return section;
    });
  }

  // Latest push, wrapped in a green span; run logs are newest-first.
  function markRunLine(pre, pattern) {
    const text = pre.firstChild;
    const match = text && text.textContent.match(pattern);
    if (!match) return;
    text.splitText(match.index + match[0].length);
    const line = text.splitText(match.index);
    const mark = el("span", "test-line", line.textContent);
    pre.replaceChild(mark, line);
  }

  function makeView(section, index) {
    const { pre } = section;
    const d = pre.prData || null;
    const script = pre.querySelector("script");
    if (script) script.remove();
    pre.textContent = pre.textContent.trim();
    pre.className = "runlog";
    const parts = section.title.match(/^(bcgov\/\S+)(?:\s+\((.+)\))?$/);
    const view = {
      d, pre,
      id: "s-" + index,
      misc: section.title === MISC_TITLE,
      name: parts ? parts[1] : section.title,
      path: parts && parts[2] ? parts[2] : "",
      latest: d ? d.points.map((p) => p.date).sort().pop() || null : null,
      from: 0, to: 0, usable: false,
    };
    if (d) {
      const at = (sha) => d.points.findIndex((p) => p.sha === sha);
      const from = at(d.from);
      const to = d.kind === "post" ? at(d.to) : 0;
      view.to = to >= 0 ? to : 0;
      view.from = from >= 0 ? from : (d.kind === "post" ? 1 : 0);
      view.usable = d.points.length >= (d.kind === "post" ? 2 : 1);
    }
    return view;
  }

  const sections = readSections();
  const logSections = sections.filter((s) => s.pre);
  const views = logSections.map(makeView);
  const mainViews = views.filter((v) => !v.misc);
  const LATEST = mainViews.map((v) => v.latest).filter(Boolean).sort().pop() || null;

  function currentRows(v) {
    const { d } = v;
    if (!d) return [];
    if (!dynamic || !v.usable) return d.optimistic;
    const a = d.points[v.from].newer;
    const b = d.kind === "post" ? d.points[v.to].newer : 0;
    return d.dynamic.slice(Math.min(a, b), Math.max(a, b));
  }

  const inCurrentCycle = (v) => v.latest !== null && v.latest === LATEST;

  function isQuiet(v) {
    if (dynamic || v.misc) return false;
    return REPORT === "pre" ? currentRows(v).length === 0 : !inCurrentCycle(v);
  }

  function statusLabel(v) {
    const count = currentRows(v).length;
    if (REPORT === "pre") return count ? count + " pending" : "";
    return inCurrentCycle(v) ? "latest test push · " + v.latest : "";
  }

  function pointLabel(p) {
    const parts = ["#" + p.run, p.date, p.sha];
    if (p.result !== "success") parts.push(p.result);
    if (!p.onMain) parts.push("not on main");
    return parts.join(" · ");
  }

  function picker(v, key) {
    const select = el("select");
    v.d.points.forEach((p, i) => {
      const option = el("option", null, pointLabel(p));
      option.value = i;
      select.appendChild(option);
    });
    select.value = v[key];
    select.addEventListener("change", () => {
      v[key] = Number(select.value);
      renderRows(v);
      renderSummary();
    });
    return select;
  }

  function renderRange(v) {
    const { d, rangeEl } = v;
    rangeEl.replaceChildren();
    if (!d) return;
    if (dynamic && !v.usable) {
      rangeEl.textContent = "Custom range needs " + (d.kind === "post" ? "two test runs" : "a test run")
        + " in the log above; showing the default list.";
    } else if (dynamic && d.kind === "post") {
      rangeEl.append("Showing PRs between", picker(v, "from"), "and", picker(v, "to"));
    } else if (dynamic) {
      rangeEl.append("Showing PRs merged after", picker(v, "from"), "up to latest main");
    } else if (!d.from) {
      rangeEl.textContent = "No default range: not enough test deploys found in recent runs.";
    } else if (d.kind === "post") {
      rangeEl.append("Showing PRs between", el("code", null, d.from), "and", el("code", null, d.to));
    } else {
      rangeEl.append("Merged since last test push", el("code", null, d.from));
    }
  }

  function tableRow(rowTag, cells) {
    const tr = el("tr");
    for (const cell of cells) {
      const c = cell && cell.td;
      const td = el(rowTag, cell && cell.className);
      td.append(c === undefined ? cell : c);
      tr.appendChild(td);
    }
    return tr;
  }

  function renderRows(v) {
    const { d, bodyEl, card } = v;
    const rows = currentRows(v);
    bodyEl.replaceChildren();
    card.classList.toggle("empty", isQuiet(v));
    if (!v.misc) {
      v.statusEl.textContent = dynamic ? rows.length + (rows.length === 1 ? " PR" : " PRs") + " in range" : statusLabel(v);
      v.statusEl.classList.toggle("blue", dynamic);
      v.noteEl.textContent = !isQuiet(v) ? ""
        : REPORT === "pre" ? "nothing pending"
        : v.latest ? "not in this cycle · last push " + v.latest : "not in this cycle";
    }
    if (v.copyEl) v.copyEl.disabled = rows.length === 0;
    if (!d) return;
    if (!rows.length) {
      bodyEl.appendChild(el("div", "none", !dynamic && REPORT === "pre" ? "No PRs pending" : "No PRs in this range"));
      return;
    }
    const repo = "https://github.com/" + d.repo;
    const scroller = bodyEl.appendChild(el("div", "scroll"));
    const table = scroller.appendChild(el("table"));
    table.appendChild(tableRow("th", ["Title", "Author", "PR", "Ticket", "Merged", "Commit"]));
    for (const r of rows) {
      const ticket = r.ticket === "NA"
        ? el("span", "na", "NA")
        : externalLink(r.ticket, "https://github.com/bcgov/entity/issues/" + r.ticket.slice(1));
      table.appendChild(tableRow("td", [
        { td: r.title, className: "t" },
        { td: r.author, className: "nw" },
        { td: r.pr === "-" ? "-" : externalLink(r.pr, repo + "/pull/" + r.pr.slice(1)), className: "m" },
        { td: ticket, className: "m" },
        { td: r.date, className: "nw" },
        { td: externalLink(r.commit, repo + "/commit/" + r.commit), className: "m" },
      ]));
    }
  }

  const escapeHtml = (text) => text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  function plainTable(v) {
    const repo = "https://github.com/" + v.d.repo;
    const a = (href, text) => '<a href="' + escapeHtml(href) + '">' + escapeHtml(text) + "</a>";
    const lines = currentRows(v).map((r) => "  <tr>" + [
      escapeHtml(r.title),
      escapeHtml(r.author),
      r.pr === "-" ? "-" : a(repo + "/pull/" + r.pr.slice(1), r.pr),
      r.ticket === "NA" ? "NA" : a("https://github.com/bcgov/entity/issues/" + r.ticket.slice(1), r.ticket),
      escapeHtml(r.date),
      a(repo + "/commit/" + r.commit, r.commit),
    ].map((cell) => "<td>" + cell + "</td>").join("") + "</tr>");
    return ['<table border="1">', "  <tr><th>Title</th><th>Author</th><th>PR</th><th>Ticket</th><th>Merged_Date</th><th>Commit</th></tr>", ...lines, "</table>"].join("\n");
  }

  async function copyToClipboard(text) {
    try {
      await navigator.clipboard.write([new ClipboardItem({
        "text/html": new Blob([text], { type: "text/html" }),
        "text/plain": new Blob([text], { type: "text/plain" }),
      })]);
    } catch {
      const area = el("textarea");
      area.value = text;
      document.body.appendChild(area);
      area.select();
      document.execCommand("copy");
      area.remove();
    }
  }

  function buildCard(v) {
    const card = el("section", "card");
    card.id = v.id;
    v.card = card;
    const header = card.appendChild(el("div", "card-h"));
    const h2 = header.appendChild(el("h2", null, v.misc ? MISC_TITLE : v.name));
    if (v.path) h2.append(" ", el("span", null, "/ " + v.path));
    if (!v.misc) v.statusEl = header.appendChild(el("span", "pill"));
    if (v.d) {
      v.headEl = header.appendChild(el("span", "head"));
      setHead(v.headEl, "checking");
    }
    header.appendChild(el("span", "grow"));
    v.noteEl = header.appendChild(el("span", "quiet", v.misc ? "every PR across the monorepo" : ""));
    if (v.d) {
      const copy = header.appendChild(el("button", "copy", "Copy HTML table"));
      copy.type = "button";
      v.copyEl = copy;
      copy.addEventListener("click", async () => {
        await copyToClipboard(plainTable(v));
        copy.textContent = "Copied";
        copy.dataset.done = "";
        setTimeout(() => { copy.textContent = "Copy HTML table"; delete copy.dataset.done; }, 1500);
      });
    }
    card.appendChild(v.pre);
    v.rangeEl = card.appendChild(el("div", "range"));
    v.bodyEl = card.appendChild(el("div"));
    const isLatestPush = v.d && (REPORT === "pre" || inCurrentCycle(v));
    if (isLatestPush) {
      markRunLine(v.pre, REPORT === "pre"
        ? /^#\d+\s{2,}test\s{2,}.*$/m
        : new RegExp("^#\\d+\\s{2,}test\\s{2,}.*" + v.latest + ".*$", "m"));
    }
    return card;
  }

  // --- repo-head check: has main moved on since this report's snapshot? --------
  const HEAD_TEXT = {
    checking: () => "Determining if behind repo head…",
    current: () => "Up to date with main",
    unknown: () => "Couldn't check repo head",
    behind: (n) => n === null ? "Warning: behind main" : "Warning: " + n + (n === 1 ? " commit" : " commits") + " behind main",
  };

  function setHead(node, status, behind) {
    node.dataset.headStatus = status;
    node.textContent = HEAD_TEXT[status](behind);
  }

  function readCache(key) {
    try {
      const hit = JSON.parse(sessionStorage.getItem(key));
      return hit && Date.now() - hit.at < HEAD_CACHE_MS ? hit.behind : null;
    } catch { return null; }
  }

  function writeCache(key, behind) {
    try { sessionStorage.setItem(key, JSON.stringify({ at: Date.now(), behind })); } catch {}
  }

  function githubApi(path, accept) {
    return fetch("https://api.github.com/repos/" + path, { headers: { Accept: accept } });
  }

  // GitHub's compare endpoint intermittently answers 500 under load: retry once.
  // Null = main has moved, but GitHub couldn't say by how many commits.
  async function compareCount(d) {
    for (let attempt = 0; attempt < 2; attempt++) {
      const response = await githubApi(d.repo + "/compare/" + d.head + "..." + d.branch + "?per_page=1", "application/vnd.github+json");
      if (response.ok) {
        const body = await response.json();
        return typeof body.ahead_by === "number" ? body.ahead_by : null;
      }
      if (response.status < 500) break;
    }
    return null;
  }

  // Anonymous API is 60 calls/hour per IP, so one check per repo snapshot, cached
  // briefly because switching tabs is a page load. The sha lookup is cheap and
  // settles the usual case without computing a diff.
  async function commitsBehind(d) {
    const key = "repo-head:" + d.repo + "@" + d.head;
    const cached = readCache(key);
    if (cached !== null) return cached;
    const latest = await githubApi(d.repo + "/commits/" + d.branch, "application/vnd.github.sha");
    if (!latest.ok) throw new Error("GitHub API " + latest.status);
    const sha = (await latest.text()).trim();
    const behind = sha === d.head ? 0 : await compareCount(d);
    if (behind !== null) writeCache(key, behind);
    return behind;
  }

  function checkHeads() {
    const groups = new Map();
    for (const v of views) {
      if (!v.d || !v.d.head) {
        if (v.headEl) setHead(v.headEl, "unknown");
        continue;
      }
      const key = v.d.repo + "@" + v.d.head;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(v);
    }
    for (const group of groups.values()) {
      commitsBehind(group[0].d).then(
        (behind) => group.forEach((v) => setHead(v.headEl, behind === 0 ? "current" : "behind", behind)),
        () => group.forEach((v) => setHead(v.headEl, "unknown")),
      );
    }
  }

  // --- page shell ---------------------------------------------------------------
  function bulletKeys(v) {
    if (v.path) return [v.path, v.path.split("/").pop()];
    return [v.name === "bcgov/lear" ? "legal-api" : v.name.replace("bcgov/", "")];
  }

  function buildTiles(section, tiles) {
    const grid = el("div", "grid");
    for (const li of section.list.children) {
      const name = li.querySelector("strong").textContent.trim();
      const link = li.querySelector("a");
      const value = li.querySelector("ul li");
      const tile = link ? externalLink("", link.href) : el("div");
      tile.className = "tile";
      const label = tile.appendChild(el("span", "tile-name", name));
      label.title = name;
      const side = tile.appendChild(el("span", "tile-side"));
      const pill = side.appendChild(el("span", "pill"));
      side.appendChild(link ? el("span", "na", "↗") : el("span", "m", value ? value.textContent.trim() : ""));
      tiles.push({ name, pill });
      grid.appendChild(tile);
    }
    return grid;
  }

  const generated = (document.querySelector("h1 + p") || { textContent: "" }).textContent.replace(/^Generated:\s*/, "");
  const tiles = [];
  const main = el("main");
  const hero = main.appendChild(el("div", "hero"));
  hero.appendChild(el("h1", null, REPORT === "pre" ? "Waiting to go to TEST" : LATEST ? "Shipped to TEST (" + LATEST + " cycle)" : "Shipped to TEST"));
  const heroSub = hero.appendChild(el("p"));
  const cards = main.appendChild(el("div"));
  mainViews.forEach((v) => cards.appendChild(buildCard(v)));
  for (const section of sections) {
    if (section.list) {
      main.appendChild(el("div", "sec-t", section.title));
      main.appendChild(buildTiles(section, tiles));
    } else if (section.title === MISC_TITLE && section.pre) {
      main.appendChild(el("div", "sec-t", "Miscellaneous"));
      main.appendChild(buildCard(views.find((v) => v.misc)));
    }
  }

  const nav = el("nav");

  function renderSummary() {
    const total = mainViews.reduce((n, v) => n + currentRows(v).length, 0);
    const active = mainViews.filter((v) => !isQuiet(v)).length;
    const count = mainViews.length;
    heroSub.textContent = dynamic ? "Custom ranges: " + total + " PRs across " + count + " components"
      : REPORT === "pre" ? total + " merged PRs pending across " + active + " of " + count + " components"
      : active + " of " + count + " components were part of the latest push";

    nav.replaceChildren(el("h4", null, "Components"));
    for (const v of mainViews) {
      const a = nav.appendChild(el("a", isQuiet(v) ? "dim" : ""));
      a.href = "#" + v.id;
      const shown = v.path ? v.path.split("/").pop() : v.name.replace("bcgov/", "");
      a.appendChild(el("span", null, shown));
      const n = currentRows(v).length;
      if (n && !isQuiet(v)) a.appendChild(el("span", "n", String(n)));
    }

    const labels = new Map();
    for (const v of mainViews) {
      if (dynamic || isQuiet(v)) continue;
      for (const key of bulletKeys(v)) labels.set(key, statusLabel(v));
    }
    for (const t of tiles) t.pill.textContent = labels.get(t.name) || "";
  }

  function renderAll() {
    views.forEach((v) => { renderRange(v); renderRows(v); });
    renderSummary();
  }

  function buildTopBar() {
    const top = el("header", "top");
    const bar = top.appendChild(el("div", "top-in"));
    const brand = bar.appendChild(externalLink("BC Gov Release Reports", "https://github.com/mruff-aeq/bcgov-release-tracker"));
    brand.className = "brand";
    const tabs = bar.appendChild(el("div", "seg"));
    for (const [key, text] of [["pre", "Pre-release"], ["post", "Post-release"]]) {
      const a = tabs.appendChild(el("a", null, text));
      a.href = REPORT_LINKS[key];
      if (key === REPORT) a.setAttribute("aria-current", "page");
    }
    bar.appendChild(el("div", "grow"));
    bar.appendChild(el("div", "gen", generated));
    const modes = bar.appendChild(el("div", "seg"));
    const buttons = [["Optimistic", false], ["Dynamic", true]].map(([text, value]) => {
      const button = modes.appendChild(el("button", null, text));
      button.type = "button";
      button.setAttribute("aria-pressed", String(value === dynamic));
      button.addEventListener("click", () => {
        dynamic = value;
        buttons.forEach(([b, v]) => b.setAttribute("aria-pressed", String(v === dynamic)));
        renderAll();
      });
      return [button, value];
    });
    return top;
  }

  const top = buildTopBar();
  const wrap = el("div", "wrap");
  wrap.append(nav, main);
  document.body.replaceChildren(top, wrap);
  renderAll();
  checkHeads();
  try { localStorage.setItem("release-report-tab", REPORT); } catch {}
})();
