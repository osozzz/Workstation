// The app only reads the reports and starts the repository's PowerShell scripts; every safety
// rule stays in those scripts (docs/policies/update-execution-safety.md).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde_json::Value;
use std::{
    fs,
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::Command,
};
use tauri::{AppHandle, Manager};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const PERMISSION_DECLINED: i32 = 1223; // ERROR_CANCELLED

/// The folder that holds scripts/ and reports/: the repository in development, the bundle when installed.
fn root(app: &AppHandle) -> Result<PathBuf, String> {
    if cfg!(debug_assertions) {
        return Ok(Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join(".."));
    }
    let resources = app.path().resource_dir().map_err(|e| e.to_string())?;
    // resource_dir() starts with \?\, and Windows PowerShell's Join-Path fails on that prefix.
    Ok(dunce::simplified(&resources).join("workstation"))
}

fn read_json(path: &Path) -> Value {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(text.trim_start_matches('\u{feff}')).ok())
        .unwrap_or(Value::Null)
}

#[tauri::command]
fn read_data(app: AppHandle, name: String) -> Result<Value, String> {
    let reports = root(&app)?.join("reports");
    match name.as_str() {
        "plan" => Ok(read_json(&reports.join("update-plan").join("update-plan.json"))),
        "evaluation" => Ok(read_json(&reports.join("evaluation").join("evaluation.json"))),
        // ponytail: every poll rereads all logs (about 40 KB each); read only the newest once they pile up.
        "logs" => {
            let mut paths: Vec<PathBuf> = fs::read_dir(reports.join("update-log"))
                .map(|entries| entries.flatten().map(|e| e.path()).collect())
                .unwrap_or_default();
            paths.retain(|p| p.extension().is_some_and(|e| e == "json"));
            paths.sort();
            paths.reverse();
            Ok(Value::Array(paths.iter().map(|p| read_json(p)).filter(|v| !v.is_null()).collect()))
        }
        _ => Err(format!("Unknown data set: {name}")),
    }
}

/// Audit, evaluation and plan. Read-only, so it runs hidden and without elevation.
#[tauri::command]
async fn refresh(app: AppHandle) -> Result<(), String> {
    let script = root(&app)?.join("scripts").join("Refresh-Workstation.ps1");
    tauri::async_runtime::spawn_blocking(move || {
        // output() also gives the child an empty stdin, so nothing in the audit can wait for input.
        let output = Command::new("powershell.exe")
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(&script)
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map_err(|e| e.to_string())?;
        if output.status.success() {
            Ok(())
        } else {
            let detail = String::from_utf8_lossy(&output.stderr);
            Err(format!("The audit did not finish. {}", detail.trim()))
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Action IDs reach a command line, so only the characters the plan contract allows get through.
fn is_action_id(id: &str) -> bool {
    !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || "._+:-".contains(c))
}

/// Runs the selected actions with one UAC prompt. The script rechecks the plan, the allow-list and the count.
#[tauri::command]
async fn update(app: AppHandle, action_ids: Vec<String>) -> Result<(), String> {
    if action_ids.is_empty() || !action_ids.iter().all(|id| is_action_id(id)) {
        return Err("The selection is not valid.".to_string());
    }
    let base = root(&app)?;
    let quoted = |path: PathBuf| path.display().to_string().replace('\'', "''");
    let script = quoted(base.join("scripts").join("Update-Workstation.ps1"));
    let plan = quoted(base.join("reports").join("update-plan").join("update-plan.json"));
    let inner = format!(
        "-NoProfile -ExecutionPolicy Bypass -File \"{script}\" -Plan \"{plan}\" -Action {} -Apply -ConfirmedCount {}",
        action_ids.join(","),
        action_ids.len()
    );
    // Start-Process -Wait drops the exit code; reading Handle keeps it on Windows PowerShell 5.1.
    let elevate = format!(
        "try {{ $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop -ArgumentList '{inner}' }} \
         catch {{ exit {PERMISSION_DECLINED} }}; $null = $p.Handle; $p.WaitForExit(); exit $p.ExitCode"
    );

    tauri::async_runtime::spawn_blocking(move || {
        let output = Command::new("powershell.exe")
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", &elevate])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map_err(|e| e.to_string())?;
        match output.status.code() {
            Some(0) => Ok(()),
            Some(PERMISSION_DECLINED) => Err("Windows permission was declined, so nothing was installed.".to_string()),
            _ => Err("The update stopped early. Check History, then audit this PC again.".to_string()),
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![read_data, refresh, update])
        .run(tauri::generate_context!())
        .expect("the Workstation window could not start");
}
