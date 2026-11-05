import { invoke } from "@tauri-apps/api/core";

export type Risk = "low" | "medium" | "high";

export interface Action {
  order: number;
  actionId: string;
  kind: string;
  source: { type: string; policyKey: string | null };
  title: string;
  currentVersion: string | null;
  targetVersion: string | null;
  command: string | null;
  risk: Risk;
  reversible: boolean;
  message: string;
}

export interface Plan {
  report: { generatedAt: string; audit: { toolVersion: string }; host: { name: string } };
  summary: { actionCount: number; lowRiskCount: number; mediumRiskCount: number; highRiskCount: number; manualCount: number };
  actions: Action[];
}

export interface Finding {
  policyKey: string;
  status: "compliant" | "deviation" | "unknown" | "not-evaluable";
  subjectId: string | null;
  message: string;
}

export interface Evaluation {
  summary: { findingCount: number; compliantCount: number; deviationCount: number; unknownCount: number; notEvaluableCount: number };
  findings: Finding[];
}

export type ActionResult = "succeeded" | "failed" | "skipped" | "not-run";

export interface LogAction {
  order: number;
  actionId: string;
  title: string;
  risk: Risk;
  result: ActionResult;
  reason: string | null;
  startedAt: string | null;
  finishedAt: string | null;
}

export interface RunLog {
  startedAt: string;
  mode: "dry-run" | "apply" | "apply-confirm-all";
  actions: LogAction[];
  preflight?: { blockingApps: { app: string; packageId: string }[] };
}

export interface Snapshot {
  plan: Plan | null;
  evaluation: Evaluation | null;
  logs: RunLog[];
}

export const inApp = "__TAURI_INTERNALS__" in window;

async function read<T>(name: "plan" | "evaluation" | "logs"): Promise<T> {
  if (inApp) return invoke<T>("read_data", { name });
  const response = await fetch(`/__data/${name}`);
  return response.json() as Promise<T>;
}

export async function loadSnapshot(): Promise<Snapshot> {
  const [plan, evaluation, logs] = await Promise.all([read<Plan | null>("plan"), read<Evaluation | null>("evaluation"), read<RunLog[]>("logs")]);
  return { plan, evaluation, logs: logs ?? [] };
}

export const refresh = () => invoke<void>("refresh");
export const runUpdate = (actionIds: string[]) => invoke<void>("update", { actionIds });

export async function loadLatestLog(): Promise<RunLog | null> {
  const logs = await read<RunLog[]>("logs");
  return logs?.find((log) => log.mode !== "dry-run") ?? null;
}

export const sourceNames: Record<string, string> = {
  winget: "WinGet",
  chocolatey: "Chocolatey",
  "npm-registry": "npm and pnpm",
  toolchain: "Developer tools",
  editor: "Editors",
  wsl: "WSL",
  "windows-update": "Windows Update",
  policy: "Your standard",
  consolidation: "Duplicates",
};

export const sourceOrder = Object.keys(sourceNames);

export function ageInHours(iso: string): number {
  return (Date.now() - new Date(iso).getTime()) / 3_600_000;
}

export function describeAge(iso: string): string {
  const hours = ageInHours(iso);
  if (hours < 1) return "less than an hour ago";
  if (hours < 24) return `${Math.floor(hours)} hours ago`;
  const days = Math.floor(hours / 24);
  return days === 1 ? "yesterday" : `${days} days ago`;
}
