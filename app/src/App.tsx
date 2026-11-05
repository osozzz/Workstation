import { useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { ageInHours, describeAge, inApp, loadFolders, loadLatestLog, loadSnapshot, pickFolder, refresh, runUpdate, saveFolders, sourceNames, sourceOrder, type Action, type ActionResult, type LogAction, type Risk, type RunLog, type Snapshot } from "./data";

type View = "overview" | "updates" | "history" | "settings";

const riskColor: Record<Risk, string> = { low: "var(--low)", medium: "var(--medium)", high: "var(--high)" };

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
    <div className="shell">
      <nav className="rail" aria-label="Sections">
        <div className="rail-host">
          {plan?.report.host.name ?? "This PC"}
          <small>Workstation</small>
        </div>
        <NavLink label="Overview" view="overview" current={view} onSelect={setView} />
        <NavLink label="Updates" count={ready} view="updates" current={view} onSelect={setView} />
        <NavLink label="History" view="history" current={view} onSelect={setView} />
        <NavLink label="Settings" view="settings" current={view} onSelect={setView} />
      </nav>
      <main className="page">
        <div className="page-inner">
          {error && <p className="notice" role="alert">{error}</p>}
          {!error && snapshot === null && <p className="empty">Reading the last audit…</p>}
          {snapshot && view === "overview" && <Overview snapshot={snapshot} run={run} auditing={auditing} onAudit={audit} onOpenUpdates={() => setView("updates")} onOpenSettings={() => setView("settings")} />}
          {snapshot && view === "updates" && <Updates snapshot={snapshot} busy={run !== null || auditing} onInstall={install} />}
          {snapshot && view === "history" && <History logs={snapshot.logs} />}
          {view === "settings" && <Settings onError={setError} />}
        </div>
      </main>
    </div>
  );
}

function NavLink(props: { label: string; count?: number; view: View; current: View; onSelect(view: View): void }) {
  return (
    <button className="rail-link" aria-current={props.current === props.view ? "page" : undefined} onClick={() => props.onSelect(props.view)}>
      {props.label}
      {props.count ? <span>{props.count}</span> : null}
    </button>
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
      {action.currentVersion} to <b>{action.targetVersion}</b>
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
      <p className="tick-detail" aria-live="polite">
        {focused ? focused.title : "Each mark is one update. Hover over a mark to see which."}
      </p>
      <div className="legend">
        <span><i style={{ background: "var(--low)" }} />Low risk</span>
        <span><i style={{ background: "var(--medium)" }} />Medium risk</span>
        <span><i style={{ background: "var(--high)" }} />High risk</span>
        <span><i style={{ boxShadow: "inset 0 0 0 1.5px var(--manual)" }} />Needs you</span>
      </div>
    </>
  );
}

const resultLabels: Record<ActionResult, string> = { succeeded: "Installed", failed: "Failed", skipped: "Skipped", "not-run": "Waiting" };

function RunRows({ log }: { log: RunLog }) {
  return (
    <ul className="rows" style={{ marginTop: 36 }}>
      {log.actions.map((action) => (
        <li className="row" key={action.actionId}>
          <span className="row-title">{action.title}</span>
          <span className="result" data-result={action.result}>
            {action.startedAt && !action.finishedAt ? "Installing" : resultLabels[action.result]}
          </span>
          {action.reason && action.result !== "succeeded" && <p>{action.reason}</p>}
        </li>
      ))}
    </ul>
  );
}

function Overview(props: { snapshot: Snapshot; run: Run | null; auditing: boolean; onAudit(): void; onOpenUpdates(): void; onOpenSettings(): void }) {
  const { snapshot, run, auditing, onAudit, onOpenUpdates, onOpenSettings } = props;
  const { plan, evaluation } = snapshot;
  const auditButton = (
    <button className="button" disabled={!inApp || auditing || run !== null} onClick={onAudit}>
      {auditing ? "Auditing, this takes a few minutes" : "Audit this PC"}
    </button>
  );
  if (!plan) {
    return (
      <>
        <h1 className="headline">Audit this PC to see what can be updated</h1>
        <p className="subline">The audit only reads; it changes nothing. It checks projects only in the folders you choose.</p>
        <div className="toolbar">
          {auditButton}
          <button className="button" onClick={onOpenSettings}>Choose project folders</button>
        </div>
      </>
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

      {stale && !run && (
        <div className="notice">
          <span>This list is more than a day old, so updates are locked until you audit again.</span>
          {auditButton}
        </div>
      )}

      {run?.log?.preflight?.blockingApps.length ? (
        <div className="notice">
          <span>Close these apps, or their updates will fail: {run.log.preflight.blockingApps.map((b) => b.app).join(", ")}.</span>
        </div>
      ) : null}

      <Strip actions={plan.actions} log={run?.log ?? null} />

      {run?.log && <RunRows log={run.log} />}

      {!run && <div className="columns">
        <section>
          <h2 className="section-title">Needs you</h2>
          <ul className="rows">
            {manual.slice(0, 6).map((action) => (
              <li className="row" key={action.actionId}>
                <span className="row-title">{action.title}</span>
                {versionsOf(action)}
              </li>
            ))}
          </ul>
          {manual.length > 6 && <button className="button" style={{ marginTop: 12 }} onClick={onOpenUpdates}>See all {manual.length}</button>}
        </section>
        <section>
          <h2 className="section-title">Your standard</h2>
          {evaluation ? (
            <>
              <div className="score">
                <strong>{evaluation.summary.compliantCount}</strong>
                <span>rules met, {evaluation.summary.deviationCount} not met</span>
              </div>
              <ul className="rows">
                {deviations.slice(0, 5).map((finding) => (
                  <li className="row" key={finding.policyKey}>
                    <span className="row-title">{finding.message}</span>
                  </li>
                ))}
              </ul>
            </>
          ) : (
            <p className="empty">Run an evaluation to compare this PC with your standard.</p>
          )}
        </section>
      </div>}
    </>
  );
}

type Filter = "ready" | "manual" | Risk;

function Updates({ snapshot, busy, onInstall }: { snapshot: Snapshot; busy: boolean; onInstall(actionIds: string[]): void }) {
  const actions = snapshot.plan?.actions ?? [];
  const stale = snapshot.plan ? ageInHours(snapshot.plan.report.generatedAt) > 24 : true;
  const dialog = useRef<HTMLDialogElement>(null);
  const [filter, setFilter] = useState<Filter>("ready");
  const [selected, setSelected] = useState<Set<string>>(new Set());

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
  const filters: [Filter, string][] = [["ready", "Ready"], ["manual", "Needs you"], ["low", "Low risk"], ["medium", "Medium risk"], ["high", "High risk"]];

  return (
    <>
      <h1 className="page-title">Updates</h1>
      <div className="toolbar">
        {filters.map(([value, label]) => (
          <button key={value} className="chip" aria-pressed={filter === value} onClick={() => setFilter(value)}>{label}</button>
        ))}
        <span className="spacer" />
        <button className="button" onClick={() => setSelected(new Set(selectable.map((a) => a.actionId)))}>Select all shown</button>
        <button className="button button-primary" disabled={!inApp || busy || stale || selected.size === 0} onClick={() => dialog.current?.showModal()}>
          Install {selected.size} selected
        </button>
      </div>
      {stale && <p className="empty" style={{ marginTop: 8 }}>This list is more than a day old. Audit this PC from Overview to install updates.</p>}
      <dialog className="confirm" ref={dialog}>
        <h2 className="section-title">Install {selected.size} updates?</h2>
        <ul className="rows confirm-list">
          {chosen.map((action) => (
            <li className="row" key={action.actionId}>
              <span className="row-title">{action.title}</span>
              {versionsOf(action) ?? <span />}
              <p>
                {action.risk} risk, {action.reversible ? "can be undone" : "cannot be undone"}
                <code>{action.command}</code>
              </p>
            </li>
          ))}
        </ul>
        <p>
          Windows asks for permission once. Close the apps being updated first, or their updates can fail. If one fails, the rest still run.
          {chosen.some((a) => a.command?.startsWith("winget")) && " Installing accepts the package and source agreements of the WinGet packages listed."}
        </p>
        <p>When it finishes, this PC is audited again to verify the result.</p>
        <form method="dialog" className="confirm-actions">
          <button className="button">Cancel</button>
          <button className="button button-primary" onClick={() => onInstall([...selected])}>Install {selected.size} updates</button>
        </form>
      </dialog>
      {visible.length === 0 && <p className="empty">Nothing here. Audit again to refresh this list.</p>}
      {visible.map((action) => {
        const runnable = action.command !== null && action.risk !== "high";
        return (
          <div className="update" key={action.actionId}>
            <input
              type="checkbox"
              aria-label={`Select ${action.title}`}
              disabled={!runnable}
              checked={selected.has(action.actionId)}
              onChange={() => toggle(action.actionId)}
            />
            <span className="risk-bar" style={{ background: riskColor[action.risk] }} title={`${action.risk} risk`} />
            <span className="row-title">{action.title}</span>
            {versionsOf(action) ?? <span />}
            <details>
              <summary>{sourceNames[action.source.type] ?? action.source.type}</summary>
              {action.message}
              {action.command && <code>{action.command}</code>}
            </details>
          </div>
        );
      })}
    </>
  );
}

function History({ logs }: { logs: RunLog[] }) {
  const runs = logs.filter((log) => log.mode !== "dry-run");
  return (
    <>
      <h1 className="page-title">History</h1>
      {runs.length === 0 && <p className="empty">No updates have been installed from here yet.</p>}
      {runs.map((log) => {
        const count = (result: string) => log.actions.filter((a) => a.result === result).length;
        const failed = log.actions.filter((a) => a.result === "failed");
        return (
          <section key={log.startedAt} style={{ marginTop: 28 }}>
            <h2 className="section-title">
              {new Date(log.startedAt).toLocaleString(undefined, { dateStyle: "long", timeStyle: "short" })}
            </h2>
            <p className="subline" style={{ fontSize: 15, marginTop: 0, marginBottom: 8 }}>
              {count("succeeded")} installed, {count("failed")} failed, {count("skipped")} skipped
            </p>
            <ul className="rows">
              {failed.map((action) => (
                <li className="row" key={action.actionId}>
                  <span className="row-title">{action.title}</span>
                  <span className="result" data-result="failed">Failed</span>
                  {action.reason && <p>{action.reason}</p>}
                </li>
              ))}
            </ul>
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
      <h1 className="page-title">Settings</h1>
      <section style={{ marginTop: 28 }}>
        <h2 className="section-title">Project folders</h2>
        <p className="subline" style={{ fontSize: 15, marginTop: 0, marginBottom: 12 }}>
          The audit checks projects and Git repositories in these folders, and nowhere else.
        </p>
        <ul className="rows">
          {folders?.map((folder) => (
            <li className="row" key={folder}>
              <span className="row-title">{folder}</span>
              <button className="button" aria-label={`Remove ${folder}`} onClick={() => save(folders.filter((f) => f !== folder)).catch(report)}>Remove</button>
            </li>
          ))}
        </ul>
        {folders?.length === 0 && <p className="empty" style={{ marginTop: 0 }}>No folders yet, so the audit skips projects and Git repositories.</p>}
        <div className="toolbar">
          <button className="button" disabled={!inApp || folders === null} onClick={() => add().catch(report)}>Add folder</button>
        </div>
        {changed && <p className="empty" style={{ marginTop: 8 }}>Audit this PC from Overview to apply this change.</p>}
      </section>
    </>
  );
}
