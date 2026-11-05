import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";

const reports = resolve(__dirname, "..", "reports");

// Browser preview only: serves the local reports folder the way the Tauri commands do in the app.
function reportsBridge(): Plugin {
  const send = (res: { setHeader(k: string, v: string): void; end(b: string): void }, path: string) => {
    res.setHeader("Content-Type", "application/json");
    res.end(existsSync(path) ? readFileSync(path, "utf8") : "null");
  };
  return {
    name: "workstation-reports-bridge",
    configureServer(server) {
      server.middlewares.use("/__data/plan", (_req, res) => send(res, join(reports, "update-plan", "update-plan.json")));
      server.middlewares.use("/__data/evaluation", (_req, res) => send(res, join(reports, "evaluation", "evaluation.json")));
      server.middlewares.use("/__data/logs", (_req, res) => {
        const dir = join(reports, "update-log");
        const names = existsSync(dir) ? readdirSync(dir).filter((n) => n.endsWith(".json")).sort().reverse() : [];
        res.setHeader("Content-Type", "application/json");
        res.end(`[${names.map((n) => readFileSync(join(dir, n), "utf8")).join(",")}]`);
      });
    },
  };
}

export default defineConfig({
  plugins: [react(), reportsBridge()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
});
