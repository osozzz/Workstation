import { ArrowRight, Check, ClockCounterClockwise, CornersOut, DownloadSimple, Folder, FolderPlus, GearSix, HardDrives, Minus, MagnifyingGlass, SquaresFour, Trash, WarningCircle, X } from "@phosphor-icons/react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type ComponentType } from "react";
import { ageInHours, describeAge, inApp, loadFolders, loadLatestLog, loadSnapshot, pickFolder, refresh, runUpdate, saveFolders, sourceNames, sourceOrder, type Action, type ActionResult, type LogAction, type Risk, type RunLog, type Snapshot } from "./data";

type View = "overview" | "updates" | "history" | "settings";

interface Run {
  total: number;
  log: RunLog | null;
}

function tickState(entry: LogAction | undefined) {
  if (!entry) return undefined;
  if (entry.result === "succeeded") return "done";
  if (entry.result === "failed") return "failed";
  if (entry.startedAt && !entry.finishedAt) return "running";
  return undefined;
}

// Web approximation of Apple's Liquid Glass, which has no web version. Each map pushes the backdrop
// outward near the edges and leaves the middle alone, so the glass bends what is behind it at its rim.
function lensMap(insetX: number, insetY: number) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400"><defs><linearGradient id="r"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#f00"/></linearGradient><linearGradient id="g" x2="0" y2="1"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#0f0"/></linearGradient><filter id="b" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="14"/></filter></defs><rect width="400" height="400" fill="url(#r)"/><rect width="400" height="400" fill="url(#g)" style="mix-blend-mode:screen"/><rect x="${insetX}" y="${insetY}" width="${400 - 2 * insetX}" height="${400 - 2 * insetY}" fill="#808000" filter="url(#b)"/></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

function GlassFilters() {
  const lenses: [string, number, number, number][] = [["lens-bar", 16, 120, 46], ["lens-pill", 60, 120, 38]];
  return (
    <svg className="filters" aria-hidden="true">
      {lenses.map(([id, insetX, insetY, scale]) => (
        <filter key={id} id={id} x="0" y="0" width="1" height="1" colorInterpolationFilters="sRGB">
          <feImage href={lensMap(insetX, insetY)} x="0" y="0" width="100%" height="100%" preserveAspectRatio="none" result="map" />
          <feDisplacementMap in="SourceGraphic" in2="map" scale={scale} xChannelSelector="R" yChannelSelector="G" />
        </filter>
      ))}
    </svg>
  );
}

export function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [view, setView] = useState<View>("overview");
  const [auditing, setAuditing] = useState(false);
  const [run, setRun] = useState<Run | null>(null);

  const reload = () => loadSnapshot().then(setSnapshot, (reason) => setError(`The reports could not be read: ${reason}`));
  useEffect(() => {
    void reload();
  }, []);

  const audit = async () => {
    setAuditing(true);
    setError(null);
    try {
      await refresh();
      await reload();
    } catch (reason) {
      setError(String(reason));
    } finally {
      setAuditing(false);
    }
  };

  const install = async (actionIds: string[]) => {
    const startedAfter = Date.now();
    setError(null);
    setRun({ total: actionIds.length, log: null });
    setView("overview");
    // The log is rewritten as each action starts and ends, so reading it shows live progress.
    const timer = window.setInterval(() => {
      void loadLatestLog().then((log) => {
        if (log && new Date(log.startedAt).getTime() >= startedAfter - 5000) setRun({ total: actionIds.length, log });
      });
    }, 2000);
    try {
      await runUpdate(actionIds);
      const log = await loadLatestLog();
      const entries = log && new Date(log.startedAt).getTime() >= startedAfter - 5000 ? log.actions : [];
      if (entries.some((a) => a.startedAt)) {
        setView("history");
      } else {
        const reason = entries.find((a) => a.reason)?.reason;
        setError(`Nothing was installed. ${reason ?? "Audit this PC and try again."}`);
      }
    } catch (reason) {
      setError(String(reason));
    } finally {
      window.clearInterval(timer);
      setRun(null);
      await reload();
    }
  };

  const plan = snapshot?.plan ?? null;
  const ready = plan?.actions.filter((a) => a.command !== null).length ?? 0;

  return (
    <>
      <GlassFilters />
      <div className="scene" aria-hidden="true" />
      <Bar host={plan?.report.host.name ?? "This PC"} view={view} ready={ready} onSelect={setView} />
      <main className="page">
        <div className="page-inner">
          {error && (
            <p className="notice" data-tone="alert" role="alert">
              <WarningCircle size={20} aria-hidden="true" />
              <span>{error}</span>
            </p>
          )}
          {!error && snapshot === null && view !== "settings" && <div className="pane skeleton" role="status" aria-label="Reading the last audit" />}
          <div className="view" key={view}>
            {snapshot && view === "overview" && <Overview snapshot={snapshot} run={run} auditing={auditing} onAudit={audit} onOpenUpdates={() => setView("updates")} onOpenSettings={() => setView("settings")} />}
            {snapshot && view === "updates" && <Updates snapshot={snapshot} busy={run !== null || auditing} onInstall={install} />}
            {snapshot && view === "history" && <History logs={snapshot.logs} />}
            {view === "settings" && <Settings onError={setError} />}
          </div>
        </div>
      </main>
    </>
  );
}

const tabs: { view: View; label: string; Icon: ComponentType<{ size?: number; weight?: "regular" | "fill"; "aria-hidden"?: "true" }> }[] = [
  { view: "overview", label: "Overview", Icon: SquaresFour },
  { view: "updates", label: "Updates", Icon: DownloadSimple },
  { view: "history", label: "History", Icon: ClockCounterClockwise },
  { view: "settings", label: "Settings", Icon: GearSix },
];

/** The floating bar is also the window's title bar, so it can be dragged and holds the window buttons. */
function Bar({ host, view, ready, onSelect }: { host: string; view: View; ready: number; onSelect(view: View): void }) {
  const row = useRef<HTMLElement>(null);
  const [lens, setLens] = useState<CSSProperties>({ opacity: 0 });

  // The droplet follows the current tab; its size comes from the tab, which depends on the font and the count.
  useLayoutEffect(() => {
    const measure = () => {
      const tab = row.current?.querySelector<HTMLElement>('[aria-current="page"]');
      if (tab) setLens({ "--x": `${tab.offsetLeft}px`, "--w": `${tab.offsetWidth}px` } as CSSProperties);
    };
    measure();
    void document.fonts.ready.then(measure);
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, [view, ready]);

  return (
    <header className="bar" data-tauri-drag-region>
      <div className="bar-host" data-tauri-drag-region>
        <HardDrives size={20} aria-hidden="true" />
        <span data-tauri-drag-region>{host}</span>
      </div>
      <nav className="tabs" ref={row} aria-label="Sections">
        <span className="tabs-lens" style={lens} aria-hidden="true" />
        {tabs.map(({ view: target, label, Icon }) => (
          <button key={target} className="tab" aria-label={label} title={label} aria-current={view === target ? "page" : undefined} onClick={() => onSelect(target)}>
            <Icon size={18} weight={view === target ? "fill" : "regular"} aria-hidden="true" />
            <span>{label}</span>
            {target === "updates" && ready > 0 && <b>{ready}</b>}
          </button>
        ))}
      </nav>
      <div className="bar-window">
        {inApp && (
          <>
            <button className="window-button" aria-label="Minimize" onClick={() => void getCurrentWindow().minimize()}><Minus size={16} /></button>
            <button className="window-button" aria-label="Maximize" onClick={() => void getCurrentWindow().toggleMaximize()}><CornersOut size={16} /></button>
            <button className="window-button" data-close aria-label="Close" onClick={() => void getCurrentWindow().close()}><X size={16} /></button>
          </>
        )}
      </div>
    </header>
  );
}

function groupBySource(actions: Action[]) {
  const groups = new Map<string, Action[]>();
  for (const action of actions) {
    groups.set(action.source.type, [...(groups.get(action.source.type) ?? []), action]);
  }
  return [...groups.entries()].sort(([a], [b]) => sourceOrder.indexOf(a) - sourceOrder.indexOf(b));
}

function versionsOf(action: Action) {
  if (!action.currentVersion && !action.targetVersion) return null;
  return (
    <span className="versions">
      {action.currentVersion} <ArrowRight size={12} aria-label="to" /> <b>{action.targetVersion}</b>
    </span>
  );
}

function Strip({ actions, log }: { actions: Action[]; log: RunLog | null }) {
  const [focused, setFocused] = useState<Action | null>(null);
  const entries = new Map(log?.actions.map((entry) => [entry.actionId, entry]));
  return (
    <>
      <div className="strip" onMouseLeave={() => setFocused(null)}>
        {groupBySource(actions).map(([source, items]) => (
          <div className="strip-group" key={source} style={{ "--count": items.length } as CSSProperties}>
            <div className="strip-ticks">
              {items.map((action) => (
                <button
                  key={action.actionId}
                  className="tick"
                  data-risk={action.risk}
                  data-manual={action.command === null}
                  data-state={tickState(entries.get(action.actionId))}
                  aria-label={`${action.title}, ${action.risk} risk`}
                  onMouseEnter={() => setFocused(action)}
                  onFocus={() => setFocused(action)}
                />
              ))}
            </div>
            <div className="strip-label">
              <b>{items.length}</b> <span>{sourceNames[source] ?? source}</span>
            </div>
          </div>
        ))}
      </div>
      <div className="strip-foot">
        <p className="tick-detail" aria-live="polite">
          {focused ? focused.title : "Each mark is one update. Hover over a mark to see which."}
        </p>
        <div className="legend">
          <span><i data-risk="low" />Low risk</span>
          <span><i data-risk="medium" />Medium risk</span>
          <span><i data-risk="high" />High risk</span>
          <span><i data-manual="true" />Needs you</span>
        </div>
      </div>
    </>
  );
}

const resultLabels: Record<ActionResult, string> = { succeeded: "Installed", failed: "Failed", skipped: "Skipped", "not-run": "Waiting" };

function RunRows({ log }: { log: RunLog }) {
  return (
    <section className="pane">
      <ul className="rows">
        {log.actions.map((action) => (
          <li className="row" key={action.actionId}>
            <span className="row-title">{action.title}</span>
            <span className="result" data-result={action.startedAt && !action.finishedAt ? "running" : action.result}>
              {action.startedAt && !action.finishedAt ? "Installing" : resultLabels[action.result]}
            </span>
            {action.reason && action.result !== "succeeded" && <p>{action.reason}</p>}
          </li>
        ))}
      </ul>
    </section>
  );
}

function Overview(props: { snapshot: Snapshot; run: Run | null; auditing: boolean; onAudit(): void; onOpenUpdates(): void; onOpenSettings(): void }) {
  const { snapshot, run, auditing, onAudit, onOpenUpdates, onOpenSettings } = props;
  const { plan, evaluation } = snapshot;
  const auditButton = (primary: boolean) => (
    <button className={primary ? "button button-primary" : "button"} disabled={!inApp || auditing || run !== null} onClick={onAudit}>
      <MagnifyingGlass size={18} aria-hidden="true" />
      {auditing ? "Auditing, this takes a few minutes" : "Audit this PC"}
    </button>
  );
  if (!plan) {
    return (
      <section className="pane hero" data-scanning={auditing || undefined}>
        <div>
          <h1 className="headline">Audit this PC to see what can be updated</h1>
          <p className="subline">The audit only reads; it changes nothing. It checks projects only in the folders you choose.</p>
        </div>
        <div className="hero-actions">
          {auditButton(true)}
          <button className="button" onClick={onOpenSettings}><Folder size={18} aria-hidden="true" />Choose project folders</button>
        </div>
      </section>
    );
  }

  const ready = plan.actions.filter((a) => a.command !== null);
  const manual = plan.actions.filter((a) => a.command === null);
  const stale = ageInHours(plan.report.generatedAt) > 24;
  const deviations = evaluation?.findings.filter((f) => f.status === "deviation" && !f.subjectId) ?? [];
  // Skipped actions never start, so "not-run" is what still counts as waiting.
  const waiting = run?.log?.actions.filter((a) => a.result === "not-run").length ?? run?.total ?? 0;
  const current = run?.log?.actions.find((a) => a.startedAt && !a.finishedAt);
  const verifying = run?.log != null && waiting === 0;

  return (
    <>
      <section className="pane hero" data-scanning={auditing || verifying || undefined}>
        <div className="hero-head">
          <div>
            {run ? (
              <>
                <h1 className="headline">{verifying ? "Checking what was installed" : `Installing ${run.total - waiting + 1} of ${run.total}`}</h1>
                <p className="subline">
                  {verifying
                    ? "Auditing this PC again. This takes a few minutes."
                    : run.log
                      ? `${current ? `${current.title}.` : "Starting the next update."} You can keep working; some apps may close while they update.`
                      : "Waiting for Windows to give permission."}
                </p>
              </>
            ) : (
              <>
                <h1 className="headline">{ready.length === 0 ? "Everything that can update is up to date" : `${ready.length} updates ready to install`}</h1>
                <p className="subline">
                  {manual.length} more need you. Last audit {describeAge(plan.report.generatedAt)}.
                </p>
              </>
            )}
          </div>
          {!run && (
            <div className="hero-actions">
              {auditButton(stale)}
              {ready.length > 0 && !stale && (
                <button className="button button-primary" onClick={onOpenUpdates}>
                  Review updates
                  <span className="button-island"><ArrowRight size={14} weight="bold" aria-hidden="true" /></span>
                </button>
              )}
            </div>
          )}
        </div>

        {stale && !run && (
          <p className="notice">
            <WarningCircle size={20} aria-hidden="true" />
            <span>This list is more than a day old, so updates are locked until you audit again.</span>
          </p>
        )}

        {run?.log?.preflight?.blockingApps.length ? (
          <p className="notice">
            <WarningCircle size={20} aria-hidden="true" />
            <span>Close these apps, or their updates will fail: {run.log.preflight.blockingApps.map((b) => b.app).join(", ")}.</span>
          </p>
        ) : null}

        <Strip actions={plan.actions} log={run?.log ?? null} />
      </section>

      {run?.log && <RunRows log={run.log} />}

      {!run && (
        <div className="bento">
          <section className="pane">
            <div className="pane-head">
              <h2 className="section-title">Needs you</h2>
              {manual.length > 6 && <button className="link" onClick={onOpenUpdates}>See all {manual.length}</button>}
            </div>
            <ul className="rows">
              {manual.slice(0, 6).map((action) => (
                <li className="row" key={action.actionId}>
                  <span className="row-title">{action.title}</span>
                  {versionsOf(action)}
                </li>
              ))}
            </ul>
            {manual.length === 0 && <p className="empty">Nothing needs you right now.</p>}
          </section>
          <section className="pane">
            <h2 className="section-title">Your standard</h2>
            {evaluation ? (
              <>
                <div className="score">
                  <strong>{evaluation.summary.compliantCount}</strong>
                  <span>rules met, {evaluation.summary.deviationCount} not met</span>
                </div>
                <div className="rule-ticks" aria-hidden="true">
                  {Array.from({ length: evaluation.summary.compliantCount }, (_, i) => <i key={`met-${i}`} data-met="true" />)}
                  {Array.from({ length: evaluation.summary.deviationCount }, (_, i) => <i key={`not-${i}`} />)}
                </div>
                <ul className="rows">
                  {deviations.slice(0, 5).map((finding) => (
                    <li className="row" key={finding.policyKey}>
                      <span className="row-note">{finding.message}</span>
                    </li>
                  ))}
                </ul>
              </>
            ) : (
              <p className="empty">Audit this PC to compare it with your standard.</p>
            )}
          </section>
        </div>
      )}
    </>
  );
}

type Filter = "ready" | "manual" | Risk;

function ActionDetail({ action }: { action: Action }) {
  const blocked = action.command !== null && action.risk === "high";
  return (
    <>
      <p className="detail-facts">
        <span data-risk={action.risk}>{action.risk} risk</span>
        <span>{action.reversible ? "Can be undone" : "Cannot be undone"}</span>
        <span>{sourceNames[action.source.type] ?? action.source.type}</span>
      </p>
      <p>{action.message}</p>
      {action.command ? <code className="command">{action.command}</code> : <p className="detail-note">This one has no command. You do it yourself.</p>}
      {blocked && <p className="detail-note">High-risk updates do not run from here.</p>}
    </>
  );
}

function Updates({ snapshot, busy, onInstall }: { snapshot: Snapshot; busy: boolean; onInstall(actionIds: string[]): void }) {
  const actions = snapshot.plan?.actions ?? [];
  const stale = snapshot.plan ? ageInHours(snapshot.plan.report.generatedAt) > 24 : true;
  const dialog = useRef<HTMLDialogElement>(null);
  const [filter, setFilter] = useState<Filter>("ready");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [focusedId, setFocusedId] = useState<string | null>(null);

  const visible = useMemo(
    () =>
      actions.filter((a) => {
        if (filter === "ready") return a.command !== null;
        if (filter === "manual") return a.command === null;
        return a.risk === filter;
      }),
    [actions, filter],
  );

  const toggle = (id: string) =>
    setSelected((current) => {
      const next = new Set(current);
      if (!next.delete(id)) next.add(id);
      return next;
    });

  const selectable = visible.filter((a) => a.command !== null && a.risk !== "high");
  const chosen = actions.filter((a) => selected.has(a.actionId));
  const focused = visible.find((a) => a.actionId === focusedId) ?? visible[0] ?? null;
  const filters: [Filter, string][] = [["ready", "Ready"], ["manual", "Needs you"], ["low", "Low risk"], ["medium", "Medium risk"], ["high", "High risk"]];

  return (
    <>
      <div className="page-head">
        <h1 className="page-title">Updates</h1>
        <div className="segments" role="group" aria-label="Filter updates">
          {filters.map(([value, label]) => (
            <button key={value} className="segment" aria-pressed={filter === value} onClick={() => setFilter(value)}>{label}</button>
          ))}
        </div>
      </div>
      {stale && (
        <p className="notice">
          <WarningCircle size={20} aria-hidden="true" />
          <span>This list is more than a day old. Audit this PC from Overview to install updates.</span>
        </p>
      )}

      <div className="master">
        <section className="pane update-list">
          {visible.length === 0 && <p className="empty">Nothing here. Audit again to refresh this list.</p>}
          {groupBySource(visible).map(([source, items]) => (
            <div className="update-group" key={source}>
              <h2 className="group-title">
                {sourceNames[source] ?? source}
                <span>{items.length}</span>
              </h2>
              {items.map((action) => {
                const runnable = action.command !== null && action.risk !== "high";
                const isFocused = focused?.actionId === action.actionId;
                return (
                  <div className="update" key={action.actionId} data-focused={isFocused || undefined}>
                    <input
                      type="checkbox"
                      aria-label={`Select ${action.title}`}
                      disabled={!runnable}
                      checked={selected.has(action.actionId)}
                      onChange={() => toggle(action.actionId)}
                    />
                    <button className="update-open" aria-expanded={isFocused} onClick={() => setFocusedId(action.actionId)}>
                      <i className="risk-mark" data-risk={action.risk} data-manual={action.command === null} title={`${action.risk} risk`} />
                      <span className="row-title">{action.title}</span>
                      {versionsOf(action)}
                    </button>
                    {isFocused && <div className="update-inline"><ActionDetail action={action} /></div>}
                  </div>
                );
              })}
            </div>
          ))}
        </section>

        {focused && (
          <aside className="pane inspector" aria-label="Selected update">
            <h2 className="inspector-title">{focused.title}</h2>
            {versionsOf(focused)}
            <ActionDetail action={focused} />
          </aside>
        )}
      </div>

      <div className="dock" data-active={selected.size > 0 || undefined}>
        <span className="dock-count">{selected.size === 0 ? "Choose updates to install" : `${selected.size} selected`}</span>
        {selected.size > 0 && <button className="link" onClick={() => setSelected(new Set())}>Clear</button>}
        <button className="button" onClick={() => setSelected(new Set(selectable.map((a) => a.actionId)))}>Select all shown</button>
        <button className="button button-primary" disabled={!inApp || busy || stale || selected.size === 0} onClick={() => dialog.current?.showModal()}>
          Install {selected.size} selected
        </button>
      </div>

      <dialog className="sheet" ref={dialog} aria-labelledby="confirm-title">
        <h2 className="sheet-title" id="confirm-title">Install {selected.size} updates?</h2>
        <ul className="rows sheet-list">
          {chosen.map((action) => (
            <li className="row" key={action.actionId}>
              <span className="row-title">{action.title}</span>
              {versionsOf(action) ?? <span />}
              <p>
                {action.risk} risk, {action.reversible ? "can be undone" : "cannot be undone"}
                <code className="command">{action.command}</code>
              </p>
            </li>
          ))}
        </ul>
        <div className="sheet-foot">
          <p>
            Windows asks for permission once. Close the apps being updated first, or their updates can fail. If one fails, the rest still run.
            {chosen.some((a) => a.command?.startsWith("winget")) && " Installing accepts the package and source agreements of the WinGet packages listed."}
          </p>
          <p>When it finishes, this PC is audited again to verify the result.</p>
          <form method="dialog" className="sheet-actions">
            <button className="button">Cancel</button>
            <button className="button button-primary" onClick={() => onInstall([...selected])}>Install {selected.size} updates</button>
          </form>
        </div>
      </dialog>
    </>
  );
}

function History({ logs }: { logs: RunLog[] }) {
  const runs = logs.filter((log) => log.mode !== "dry-run");
  return (
    <>
      <div className="page-head">
        <h1 className="page-title">History</h1>
      </div>
      {runs.length === 0 && <section className="pane"><p className="empty">No updates have been installed from here yet.</p></section>}
      {runs.map((log) => {
        const count = (result: string) => log.actions.filter((a) => a.result === result).length;
        const failed = log.actions.filter((a) => a.result === "failed");
        const started = new Date(log.startedAt);
        return (
          <section className="pane run" key={log.startedAt}>
            <div className="run-when">
              <h2 className="section-title">{started.toLocaleDateString(undefined, { dateStyle: "long" })}</h2>
              <p>{started.toLocaleTimeString(undefined, { timeStyle: "short" })}</p>
            </div>
            <div className="run-body">
              <div className="run-ticks" aria-hidden="true">
                {log.actions.map((action) => <i key={action.actionId} data-result={action.result} />)}
              </div>
              <p className="run-counts">
                <b>{count("succeeded")}</b> installed, <b>{count("failed")}</b> failed, <b>{count("skipped")}</b> skipped
              </p>
              {failed.length > 0 && (
                <ul className="rows">
                  {failed.map((action) => (
                    <li className="row" key={action.actionId}>
                      <span className="row-title">{action.title}</span>
                      <span className="result" data-result="failed">Failed</span>
                      {action.reason && <p>{action.reason}</p>}
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </section>
        );
      })}
    </>
  );
}

function Settings({ onError }: { onError(message: string | null): void }) {
  const [folders, setFolders] = useState<string[] | null>(null);
  const [changed, setChanged] = useState(false);
  const report = (reason: unknown) => onError(String(reason));

  useEffect(() => {
    void loadFolders().then(setFolders, report);
  }, []);

  const save = async (next: string[]) => {
    onError(null);
    await saveFolders(next);
    setFolders(next);
    setChanged(true);
  };

  const add = async () => {
    const folder = await pickFolder();
    if (folder && !folders?.includes(folder)) await save([...(folders ?? []), folder]);
  };

  return (
    <>
      <div className="page-head">
        <h1 className="page-title">Settings</h1>
      </div>
      <section className="pane settings">
        <div className="pane-head">
          <div>
            <h2 className="section-title">Project folders</h2>
            <p className="pane-note">The audit checks projects and Git repositories in these folders, and nowhere else.</p>
          </div>
          <button className="button" disabled={!inApp || folders === null} onClick={() => add().catch(report)}>
            <FolderPlus size={18} aria-hidden="true" />
            Add folder
          </button>
        </div>
        <ul className="rows">
          {folders?.map((folder) => (
            <li className="row folder" key={folder}>
              <Folder size={20} aria-hidden="true" />
              <span className="row-title">{folder}</span>
              <button className="icon-button" aria-label={`Remove ${folder}`} onClick={() => save(folders.filter((f) => f !== folder)).catch(report)}>
                <Trash size={18} aria-hidden="true" />
              </button>
            </li>
          ))}
        </ul>
        {folders?.length === 0 && <p className="empty">No folders yet, so the audit skips projects and Git repositories.</p>}
        {changed && (
          <p className="saved">
            <Check size={16} weight="bold" aria-hidden="true" />
            Saved. Audit this PC from Overview to apply this change.
          </p>
        )}
      </section>
    </>
  );
}
