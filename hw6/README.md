# CS528 HW6: 3NF schema + 2 models on a VM

Builds on HW5. The request data in Cloud SQL (`hw5-db`, database `hw5`) is moved into a
3rd-normal-form schema (new database `hw6`), and a VM trains 2 models on it:

1. **client IP → country** (goal 99%+)
2. **age, gender, hour, country → income** (goal 35%+)

The test-set predictions are written to `gs://cs528hww2/hw6/`.

## Files

| File | What it is |
|---|---|
| `run_hw6.sh` | **The one script to run**: starts the DB, creates the VM, waits, stops the DB, deletes the VM, prints the outputs |
| `config.sh` | Shared names and settings (project ID hardcoded) |
| `startup.sh` | VM startup script: installs packages, runs `migrate.py` then `models.py`, uploads a log + `STATUS` |
| `schema_3nf.sql` | The new 3NF tables (database `hw6`) + a `request_details` view |
| `migrate.sql` | The queries that copy the HW5 data into the new tables |
| `migrate.py` | Runs the two SQL files in one transaction, then checks no rows were lost |
| `models.py` | Reads the data from Cloud SQL, trains + tests the 2 models, writes the outputs to the bucket |
| `db.py` | Database connection (Cloud SQL Python Connector) |
| `requirements-vm.txt` | Python packages installed on the VM |

## How to run

Needs: the `gcloud` CLI logged in (`gcloud auth login`) as Owner/Editor of the project,
and the HW5 Cloud SQL instance `hw5-db` holding the HW5 data.

```bash
cd hw6
DB_PASS='<hw5-user password>' bash run_hw6.sh
```

The database password is not stored in this repo. Pass it as shown.

It takes about 10 minutes:

1. Starts Cloud SQL `hw5-db` and waits until it is ready. It pauses the HW5 hourly watchdog so it doesn't stop the database mid-run.
2. Creates the service account `hw6-models-sa` with only two roles:
   - **Cloud SQL Client** on the project
   - **Storage Object User** on the bucket `cs528hww2` only
3. Deletes old outputs in `gs://cs528hww2/hw6/`. Then it creates the VM `hw6-models` (e2-medium, Debian 12). The code goes in through VM metadata.
4. The VM's startup script installs Python packages, runs `migrate.py`, then runs `models.py`. It then uploads `vm_log.txt` and a `STATUS` file (`OK` or `FAILED`).
5. The script waits for `STATUS`, then **stops the database and deletes the VM**. This also happens if something fails or you press Ctrl+C.
6. It prints the bucket's files on the terminal:
   - `summary.txt` in full
   - the first 20 rows of each predictions file (`FULL=1` prints every row)

Options:
- `SEED=7 DB_PASS=... bash run_hw6.sh` uses a different train/test split seed. The default is 528.
- `FULL=1` prints every row of the prediction files.

## Output (in `gs://cs528hww2/hw6/`)

| File | Contents |
|---|---|
| `model1_ip_to_country_test_predictions.csv` | `client_ip, actual_country, predicted_country, correct`: one row per test row |
| `model2_income_test_predictions.csv` | `request_id, age, gender, hour, country, actual_income, predicted_income, correct` |
| `summary.txt` | Row counts, accuracies, model details |
| `vm_log.txt` | Everything the VM printed (migration + models) |
| `STATUS` | `OK` or `FAILED` |

## Local test

`db.py` can use a local MySQL 8 instead of Cloud SQL (`DB_HOST`, `DB_PORT`), and
`OUTPUT_DIR=folder` writes the outputs locally instead of to the bucket:

```bash
DB_HOST=127.0.0.1 DB_USER=root python migrate.py
DB_HOST=127.0.0.1 DB_USER=root OUTPUT_DIR=out python models.py
```
