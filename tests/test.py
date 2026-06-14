import pandas as pd
from datetime import datetime
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────
BASE_DIR    = Path("datasets")          # change if your root folder differs
FOLDERS     = ["source_crm", "source_erp"]
COLUMN_NAME = "ingested_at"             # name of the new timestamp column
# ─────────────────────────────────────────────────────────────────────────────

timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

for folder in FOLDERS:
    folder_path = BASE_DIR / folder

    if not folder_path.exists():
        print(f"[SKIP] Folder not found: {folder_path}")
        continue

    csv_files = list(folder_path.glob("*.csv"))

    if not csv_files:
        print(f"[INFO] No CSV files in: {folder_path}")
        continue

    for csv_file in csv_files:
        df = pd.read_csv(csv_file)
        df[COLUMN_NAME] = timestamp          # add timestamp column
        df.to_csv(csv_file, index=False)     # overwrite in place
        print(f"[OK] {csv_file.name}  →  added '{COLUMN_NAME}' = {timestamp}")

print("\nDone ✓")