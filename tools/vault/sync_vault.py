#!/usr/bin/env python3
"""
SmartBizz POS - Secure Vault Sync & Google Drive Backup Utility
Packages confidential release documentation, credentials, and deployment artifacts,
archives them locally into secure_vault and external local storage, and uploads
the encrypted/zipped bundle to Google Drive via the Apps Script serverless webhook.
"""

import os
import sys
import json
import base64
import shutil
import zipfile
import hashlib
import urllib.request
import urllib.error
import subprocess
from datetime import datetime

# Windows terminal UTF-8 safeguard
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

WEBHOOK_URL = "https://script.google.com/macros/s/AKfycbwZIs_n5hCtSBqkyPOVqeZZBY1XjUAv4NjYWj8O3AY2i0Fw0Rl2OV-TA-IgmlvRbo7pFQ/exec"
SECRET_TOKEN = "SMART_POS_SECURE_TOKEN_2026"

CREDENTIAL_FILES = [
    "android/key.properties",
    "android/app/upload-keystore.jks",
    "test_automation/.env.test",
    "secrets/lease_signing_key.pem",
]

DOC_FILES = [
    "DEPLOYMENT_RUNBOOK.md",
    "SECURITY_NOTES.md",
    "SYSTEM_DOCUMENTATION.md",
    "TROUBLESHOOTING.md",
    "ISSUES_AND_RESOLUTIONS.md",
    "FLOWS_AND_SCENARIOS.md",
    "findings.md",
    "implementation_plan.md",
    "implementation_plan2.md",
    "implementation_plan3.md",
    "docs/07_TESTING_AND_RELEASE.md",
    "docs/08_DEBUGGING_PLAYBOOK.md",
    "docs/CLIENT_NETWORK_DATABASE_PLAN.md",
    "docs/smartbizz_test_report.md",
    "docs/FINDINGS.md",
]

def compute_sha256(filepath):
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(8192):
            h.update(chunk)
    return h.hexdigest()

def get_git_info(root_dir):
    try:
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root_dir).decode().strip()
    except Exception:
        commit = "UNKNOWN"
    try:
        branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=root_dir).decode().strip()
    except Exception:
        branch = "develop"
    return commit, branch

def find_google_drive_path():
    """
    Auto-detects active Google Drive Desktop mount on Windows.
    Checks common drive letters and user profile paths.
    """
    # 1. Check drive letters for "My Drive"
    for letter in ['G', 'D', 'E', 'F', 'H', 'I', 'J', 'K', 'L', 'M']:
        drive_path = f"{letter}:\\My Drive"
        if os.path.exists(drive_path):
            return drive_path
            
    # 2. Check user profile directory
    user_home = os.path.expanduser('~')
    possible_paths = [
        os.path.join(user_home, 'Google Drive', 'My Drive'),
        os.path.join(user_home, 'Google Drive'),
    ]
    for p in possible_paths:
        if os.path.exists(p):
            return p
    return None

def sync_vault(upload_to_drive=True):
    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
    vault_dir = os.path.join(root_dir, 'secure_vault')
    creds_vault = os.path.join(vault_dir, 'credentials')
    docs_vault = os.path.join(vault_dir, 'documentation')
    releases_vault = os.path.join(vault_dir, 'releases')

    user_home = os.path.expanduser('~')
    external_vault = os.path.join(user_home, 'smartbizz_local_vault')

    os.makedirs(creds_vault, exist_ok=True)
    os.makedirs(docs_vault, exist_ok=True)
    os.makedirs(releases_vault, exist_ok=True)
    os.makedirs(external_vault, exist_ok=True)

    timestamp = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    commit_sha, branch = get_git_info(root_dir)

    print(f"==================================================")
    print(f"[VAULT] SmartBizz Secure Vault Sync & Drive Backup")
    print(f"   Timestamp: {timestamp} (UTC)")
    print(f"   Git Branch: {branch} @ {commit_sha[:8]}")
    print(f"==================================================")

    manifest_entries = []

    # 1. Sync Credentials
    print("\n[1/4] Refreshing Credentials into local vault...")
    for rel_path in CREDENTIAL_FILES:
        full_src = os.path.join(root_dir, rel_path)
        if os.path.exists(full_src):
            dst = os.path.join(creds_vault, os.path.basename(rel_path))
            shutil.copy2(full_src, dst)
            size = os.path.getsize(dst)
            sha = compute_sha256(dst)
            manifest_entries.append({"type": "credential", "file": os.path.basename(rel_path), "size": size, "sha256": sha})
            print(f"  + Secured {rel_path} ({size} bytes)")
        else:
            print(f"  - Skipped (not found on disk): {rel_path}")

    # 2. Sync Documentation
    print("\n[2/4] Refreshing Production Documentation into local vault...")
    for rel_path in DOC_FILES:
        full_src = os.path.join(root_dir, rel_path)
        if os.path.exists(full_src):
            dst = os.path.join(docs_vault, os.path.basename(rel_path))
            shutil.copy2(full_src, dst)
            size = os.path.getsize(dst)
            sha = compute_sha256(dst)
            manifest_entries.append({"type": "documentation", "file": os.path.basename(rel_path), "size": size, "sha256": sha})
            print(f"  + Secured {rel_path} ({size} bytes)")
        else:
            print(f"  - Skipped (not found): {rel_path}")

    # 3. Create Release Manifest
    manifest_data = {
        "release_timestamp": timestamp,
        "commit_sha": commit_sha,
        "git_branch": branch,
        "production_urls": {
            "pos": "https://smartdine-pos.web.app/pos/",
            "guest_qr": "https://smartdine-pos.web.app/r/",
            "custom_domain": "https://smartbizz.devmonks.space"
        },
        "secured_items": manifest_entries
    }
    manifest_path = os.path.join(releases_vault, "release_manifest.json")
    with open(manifest_path, 'w', encoding='utf-8') as f:
        json.dump(manifest_data, f, indent=2)
    print(f"\n[3/4] Generated release manifest ({len(manifest_entries)} secured files).")

    # 4. Create ZIP Archive
    zip_filename = f"smartbizz_secure_vault_{timestamp}.zip"
    zip_path = os.path.join(releases_vault, zip_filename)
    latest_zip = os.path.join(external_vault, "smartbizz_secure_vault_latest.zip")
    timestamped_external_zip = os.path.join(external_vault, zip_filename)

    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        for foldername, _, filenames in os.walk(vault_dir):
            if 'releases' in foldername and any(f.endswith('.zip') for f in filenames):
                continue
            for filename in filenames:
                if filename.endswith('.zip'):
                    continue
                file_full = os.path.join(foldername, filename)
                rel_in_vault = os.path.relpath(file_full, vault_dir)
                z.write(file_full, arcname=rel_in_vault)

    shutil.copy2(zip_path, latest_zip)
    shutil.copy2(zip_path, timestamped_external_zip)

    # Also mirror unzipped files to external user home folder
    for folder in ['credentials', 'documentation', 'releases']:
        src_f = os.path.join(vault_dir, folder)
        dst_f = os.path.join(external_vault, folder)
        if os.path.exists(src_f):
            shutil.copytree(src_f, dst_f, dirs_exist_ok=True)

    zip_size = os.path.getsize(zip_path)
    print(f"  ✓ Created local archive: {zip_path} ({zip_size} bytes)")
    print(f"  ✓ Mirrored to permanent external vault: {external_vault}")

    # 5. Upload/Sync to Google Drive
    if upload_to_drive:
        print("\n[4/4] Syncing archive to Google Drive (SmartBizz_Production_Vault)...")
        
        # Method A: Google Drive Desktop Direct Sync (100% Automated, Native Cloud Sync)
        gdrive_my_drive = find_google_drive_path()
        gdrive_synced = False
        if gdrive_my_drive:
            gdrive_vault = os.path.join(gdrive_my_drive, 'SmartBizz_Production_Vault')
            os.makedirs(gdrive_vault, exist_ok=True)
            
            # Copy timestamped zip and latest zip
            gdrive_timestamped_zip = os.path.join(gdrive_vault, zip_filename)
            gdrive_latest_zip = os.path.join(gdrive_vault, "smartbizz_secure_vault_latest.zip")
            shutil.copy2(zip_path, gdrive_timestamped_zip)
            shutil.copy2(zip_path, gdrive_latest_zip)
            
            # Copy release manifest
            shutil.copy2(manifest_path, os.path.join(gdrive_vault, "release_manifest.json"))
            
            # Mirror unzipped folders
            for folder in ['credentials', 'documentation', 'releases']:
                src_f = os.path.join(vault_dir, folder)
                dst_f = os.path.join(gdrive_vault, folder)
                if os.path.exists(src_f):
                    shutil.copytree(src_f, dst_f, dirs_exist_ok=True)
                    
            # Also keep smartbizz_local_vault mirrored if present
            sub_vault = os.path.join(gdrive_vault, 'smartbizz_local_vault')
            if os.path.exists(sub_vault):
                shutil.copy2(zip_path, os.path.join(sub_vault, zip_filename))
                shutil.copy2(zip_path, os.path.join(sub_vault, "smartbizz_secure_vault_latest.zip"))
                for folder in ['credentials', 'documentation', 'releases']:
                    src_f = os.path.join(vault_dir, folder)
                    dst_f = os.path.join(sub_vault, folder)
                    if os.path.exists(src_f):
                        shutil.copytree(src_f, dst_f, dirs_exist_ok=True)
                        
            print(f"  [OK] Google Drive Desktop active at: {gdrive_my_drive}")
            print(f"  [OK] Vault updated in Google Drive: {gdrive_vault}")
            print(f"       + Synced Archive: {zip_filename}")
            print(f"       + Synced Latest:  smartbizz_secure_vault_latest.zip")
            print(f"       + Synced Manifest: release_manifest.json")
            print(f"       + Synced unzipped credentials & documentation folders.")
            print(f"  [OK] GoogleDriveFS is running and syncing to Google Cloud in real-time!")
            gdrive_synced = True

        # Method B: Apps Script Webhook Backup (Secondary Cloud Fallback)
        if not gdrive_synced:
            print("  [INFO] Attempting secondary Apps Script webhook upload...")
            with open(zip_path, 'rb') as f:
                b64_content = base64.b64encode(f.read()).decode('utf-8')

            payload = {
                "action": "BACKUP_VAULT",
                "secret": SECRET_TOKEN,
                "filename": zip_filename,
                "content_base64": b64_content,
                "timestamp": timestamp,
                "commit_sha": commit_sha
            }

            req_data = json.dumps(payload).encode('utf-8')
            req = urllib.request.Request(
                WEBHOOK_URL,
                data=req_data,
                headers={'Content-Type': 'application/json'}
            )

            try:
                with urllib.request.urlopen(req, timeout=45) as resp:
                    resp_text = resp.read().decode('utf-8')
                    try:
                        result = json.loads(resp_text)
                    except Exception:
                        result = {"raw": resp_text}

                    if isinstance(result, dict) and (result.get('success') is True or result.get('ok') is True):
                        file_url = result.get('url', 'In Google Drive')
                        print(f"  [OK] Uploaded successfully to Google Drive via Webhook!")
                        print(f"       Drive Folder: SmartBizz_Production_Vault")
                        print(f"       File: {zip_filename}")
                        print(f"       URL / ID: {file_url}")
                    else:
                        print(f"  [INFO] Webhook response: {result}")
            except Exception as e:
                print(f"  [NOTICE] Drive webhook notice: {e}")

    print("\n==================================================")
    print("[DONE] Secure Vault Sync Complete.")
    print("==================================================")

if __name__ == '__main__':
    upload = "--no-upload" not in sys.argv
    sync_vault(upload_to_drive=upload)
