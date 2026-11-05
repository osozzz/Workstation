// The app only reads the reports and starts the repository's PowerShell scripts; every safety
// rule stays in those scripts (docs/policies/update-execution-safety.md).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde_json::{json, Value};
use std::{
    fs,
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::Command,
};
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::DialogExt;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const PERMISSION_DECLINED: i32 = 1223; // ERROR_CANCELLED

/// The folder that holds scripts/: the repository in development, the bundle when installed.
fn root(app: &AppHandle) -> Result<PathBuf, String> {
    if cfg!(debug_assertions) {
        return Ok(Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join(".."));
    }
    let resources = app.path().resource_dir().map_err(|e| e.to_string())?;
    // resource_dir() starts with \?\, and Windows PowerShell's Join-Path fails on that prefix.
    Ok(dunce::simplified(&resources).join("workstation"))
}

/// The folder that holds reports/ and the local configuration: the repository in development, the
/// user's app data when installed, because an app update replaces the bundle.
fn data_root(app: &AppHandle) -> Result<PathBuf, String> {
    if cfg!(debug_assertions) {
        return root(app);
    }
    app.path().app_local_data_dir().map_err(|e| e.to_string())
}

fn local_config(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(data_root(app)?.join("config").join("workstation.local.json"))
}

fn read_json(path: &Path) -> Value {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(text.trim_start_matches('\u{feff}')).ok())
        .unwrap_or(Value::Null)
}

#[tauri::command]
fn read_data(app: AppHandle, name: String) -> Result<Value, String> {
    let reports = data_root(&app)?.join("reports");
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
        "folders" => Ok(read_json(&local_config(&app)?).pointer("/projects/developmentRoots").cloned().unwrap_or_else(|| json!([]))),
        _ => Err(format!("Unknown data set: {name}")),
    }
}

/// Sets the folders the audit may scan and keeps every other setting. A whole drive is too broad, as in the audit.
fn with_folders(mut config: Value, folders: &[String]) -> Result<Value, String> {
    if let Some(folder) = folders.iter().find(|f| !Path::new(f).is_absolute() || Path::new(f).parent().is_none()) {
        return Err(format!("{folder} is too broad to scan. Choose a folder inside the drive."));
    }
    let invalid = || "The project settings file is not valid, so it was not changed.".to_string();
    config
        .as_object_mut()
        .ok_or_else(invalid)?
        .entry("projects")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or_else(invalid)?
        .insert("developmentRoots".to_string(), json!(folders));
    Ok(config)
}

#[tauri::command]
fn save_folders(app: AppHandle, folders: Vec<String>) -> Result<(), String> {
    let path = local_config(&app)?;
    let current = if path.exists() { read_json(&path) } else { json!({ "schemaVersion": "1.0" }) };
    let text = serde_json::to_string_pretty(&with_folders(current, &folders)?).map_err(|e| e.to_string())?;
    fs::create_dir_all(path.with_file_name("")).map_err(|e| e.to_string())?;
    fs::write(&path, text).map_err(|e| e.to_string())
}

/// Windows' folder picker. It blocks until closed, so it stays off the main thread.
#[tauri::command]
async fn pick_folder(app: AppHandle) -> Result<Option<String>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut picker = app.dialog().file();
        if let Some(window) = app.get_webview_window("main") {
            picker = picker.set_parent(&window);
        }
        picker.blocking_pick_folder().map(|folder| folder.to_string())
    })
    .await
    .map_err(|e| e.to_string())
}

/// Audit, evaluation and plan. Read-only, so it runs hidden and without elevation.
#[tauri::command]
async fn refresh(app: AppHandle) -> Result<(), String> {
    let script = root(&app)?.join("scripts").join("Refresh-Workstation.ps1");
    let data = data_root(&app)?;
    tauri::async_runtime::spawn_blocking(move || {
        // output() also gives the child an empty stdin, so nothing in the audit can wait for input.
        let output = Command::new("powershell.exe")
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(&script)
            .arg("-DataDirectory")
            .arg(&data)
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
    let data_path = data_root(&app)?;
    let quoted = |path: PathBuf| path.display().to_string().replace('\'', "''");
    let script = quoted(root(&app)?.join("scripts").join("Update-Workstation.ps1"));
    let plan = quoted(data_path.join("reports").join("update-plan").join("update-plan.json"));
    let data = quoted(data_path);
    let inner = format!(
        "-NoProfile -ExecutionPolicy Bypass -File \"{script}\" -Plan \"{plan}\" -DataDirectory \"{data}\" -Action {} -Apply -ConfirmedCount {}",
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
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![read_data, save_folders, pick_folder, refresh, update])
        .run(tauri::generate_context!())
        .expect("the Workstation window could not start");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saving_folders_keeps_the_other_settings() {
        let config = json!({ "projects": { "maxDiscoveryDepth": 3 }, "git": { "branchStaleDays": 30 } });
        let saved = with_folders(config, &[r"C:\code".to_string()]).unwrap();
        assert_eq!(saved["projects"]["developmentRoots"], json!([r"C:\code"]));
        assert_eq!(saved["projects"]["maxDiscoveryDepth"], 3);
        assert_eq!(saved["git"]["branchStaleDays"], 30);
    }

    #[test]
    fn a_whole_drive_or_a_relative_path_is_refused() {
        for folder in [r"C:\", r"D:\", r"\\server\share", "code", "C:"] {
            assert!(with_folders(json!({}), &[folder.to_string()]).is_err(), "{folder}");
        }
    }

    #[test]
    fn an_unreadable_settings_file_is_not_replaced() {
        assert!(with_folders(Value::Null, &[]).is_err());
        assert!(with_folders(json!({ "projects": [] }), &[]).is_err());
    }
}
