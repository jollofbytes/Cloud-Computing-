"""CS528 HW6 part 3: two models trained on the request data in Cloud SQL.

    python models.py

Model 1: client IP -> country   (decision tree on the IP written as one number)
Model 2: age, gender, hour, country -> income   (best of 3 candidates, picked on training data only)

For each model: 80% of the rows train it, the other 20% (the test set) score it.
The test-set predictions are written as separate CSV files to the cloud bucket,
plus a summary.txt with the accuracies. (OUTPUT_DIR=folder writes them locally instead.)
"""
import io
import os
import statistics

import pandas as pd
from sklearn.base import clone
from sklearn.dummy import DummyClassifier
from sklearn.metrics import accuracy_score
from sklearn.model_selection import cross_val_score, train_test_split
from sklearn.tree import DecisionTreeClassifier

import db

SEED = int(os.environ.get("SEED", "528"))          # random seed for the train/test split
BUCKET = os.environ.get("BUCKET_NAME", "cs528hww2")
OUT_PREFIX = os.environ.get("OUT_PREFIX", "hw6")    # folder inside the bucket
OUTPUT_DIR = os.environ.get("OUTPUT_DIR")           # local testing only
TEST_SIZE = 0.2

AGES = ["0-16", "17-25", "26-35", "36-45", "46-55", "56-65", "66-75", "76+"]
INCOMES = ["0-10k", "10k-20k", "20k-40k", "40k-60k", "60k-100k", "100k-150k", "150k-250k", "250k+"]

summary = []  # lines for summary.txt


def say(line=""):
    print(line, flush=True)
    summary.append(line)


# ------------------------------------------------------------------ data
def load_data():
    """Reads every client request from the 3NF tables (through the request_details view)."""
    conn = db.connect("hw6")
    with conn.cursor() as cur:
        cur.execute("SELECT request_id, client_ip, country, gender, age, income, time_of_day,"
                    " requested_file FROM request_details ORDER BY request_id")
        df = pd.DataFrame(cur.fetchall(), columns=[d[0] for d in cur.description])
    conn.close()
    db.close()
    say(f"Rows read from Cloud SQL (hw6.request_details): {len(df)}")

    # Keep only rows sent by the course client: internet scanners send no headers.
    df = df.dropna(subset=["client_ip", "country", "gender", "age", "income", "time_of_day"])
    df = df[df["age"].isin(AGES) & df["income"].isin(INCOMES)]
    say(f"Rows with all fields (client requests):         {len(df)}")

    # A request copied twice would let the test set contain rows the model already saw.
    # (Every client request picks its fields at random, so a true copy is very unlikely.)
    cols = ["client_ip", "country", "gender", "age", "income", "time_of_day", "requested_file"]
    dupes = int(df.duplicated(subset=cols).sum())
    df = df.drop_duplicates(subset=cols)
    say(f"Exact duplicate rows removed:                    {dupes}")
    return df.reset_index(drop=True)


def ip_to_number(ip):
    """'12.34.56.78' -> 12*256^3 + 34*256^2 + 56*256 + 78. Nearby IPs get nearby numbers."""
    a, b, c, d = (int(part) for part in ip.split("."))
    return ((a * 256 + b) * 256 + c) * 256 + d


def save(name, frame):
    """Writes one CSV of test-set predictions to the bucket (or to OUTPUT_DIR)."""
    text = frame.to_csv(index=False)
    write_text(name, text)
    return name


def write_text(name, text):
    if OUTPUT_DIR:
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        with open(os.path.join(OUTPUT_DIR, name), "w") as f:
            f.write(text)
        say(f"  wrote {os.path.join(OUTPUT_DIR, name)}")
        return
    from google.cloud import storage
    blob = storage.Client().bucket(BUCKET).blob(f"{OUT_PREFIX}/{name}")
    blob.upload_from_file(io.BytesIO(text.encode()), content_type="text/plain")
    say(f"  wrote gs://{BUCKET}/{OUT_PREFIX}/{name}")


# ------------------------------------------------------------------ model 1
def country_model(df):
    say()
    say("=" * 70)
    say("MODEL 1: client IP -> country")
    say("=" * 70)
    df = df[df["client_ip"].str.count(r"\.") == 3]          # IPv4 only
    X = df["client_ip"].map(ip_to_number).to_frame("ip_number")
    y = df["country"]
    X_train, X_test, y_train, y_test, ip_train, ip_test = train_test_split(
        X, y, df["client_ip"], test_size=TEST_SIZE, random_state=SEED)

    model = DecisionTreeClassifier(random_state=SEED)
    model.fit(X_train, y_train)
    pred = model.predict(X_test)
    acc = accuracy_score(y_test, pred)

    unseen = (~ip_test.isin(set(ip_train))).mean()
    say(f"Train rows: {len(X_train)}   Test rows: {len(X_test)}   Countries: {y.nunique()}")
    say(f"Test IPs never seen in training: {unseen:.1%} (so the model is not just memorising IPs)")
    say(f"Decision tree: {model.get_n_leaves()} leaves, depth {model.get_depth()}")
    say(f"TEST ACCURACY: {acc:.4%}   (goal: at least 99%)")

    out = pd.DataFrame({"client_ip": ip_test.values, "actual_country": y_test.values,
                        "predicted_country": pred, "correct": y_test.values == pred})
    wrong = out[~out["correct"]]
    if len(wrong):
        say(f"Wrong predictions ({len(wrong)}), first 10:")
        for row in wrong.head(10).itertuples():
            say(f"  {row.client_ip}: actual {row.actual_country}, predicted {row.predicted_country}")
    save("model1_ip_to_country_test_predictions.csv", out)
    return acc


# ------------------------------------------------------------------ model 2
def income_features(df, columns):
    """Turns the chosen fields into numbers the tree can use (one 0/1 column per value)."""
    feats = pd.DataFrame(index=df.index)
    if "age" in columns:
        feats = feats.join(pd.get_dummies(df["age"], prefix="age", dtype=int))
    if "gender" in columns:
        feats["is_male"] = (df["gender"] == "Male").astype(int)
    if "hour" in columns:
        feats["hour"] = pd.to_datetime(df["time_of_day"]).dt.hour
    if "country" in columns:
        feats = feats.join(pd.get_dummies(df["country"], prefix="country", dtype=int))
    return feats


def income_model(df):
    say()
    say("=" * 70)
    say("MODEL 2: age, gender, hour, country -> income")
    say("=" * 70)
    y = df["income"]
    train_idx, test_idx = train_test_split(df.index, test_size=TEST_SIZE, random_state=SEED)
    say(f"Train rows: {len(train_idx)}   Test rows: {len(test_idx)}   Income groups: {y.nunique()}")

    # Three candidates, compared with 5-fold cross-validation on the TRAINING rows only.
    # The test rows are not touched until the winner is chosen.
    candidates = {
        "baseline: always guess the most common income":
            (["age"], DummyClassifier(strategy="most_frequent")),
        "decision tree on age only":
            (["age"], DecisionTreeClassifier(random_state=SEED)),
        "decision tree on age + gender + hour + country":
            (["age", "gender", "hour", "country"],
             DecisionTreeClassifier(min_samples_leaf=200, random_state=SEED)),
    }
    say("Candidates (5-fold cross-validation accuracy on the training rows):")
    best_name, best_score = None, -1.0
    for name, (columns, model) in candidates.items():
        X_train = income_features(df, columns).loc[train_idx]
        score = cross_val_score(model, X_train, y.loc[train_idx], cv=5).mean()
        say(f"  {score:.2%}  {name}")
        if score > best_score:
            best_name, best_score = name, score
    say(f"Chosen: {best_name}")

    columns, model = candidates[best_name]
    X = income_features(df, columns)
    model.fit(X.loc[train_idx], y.loc[train_idx])
    pred = model.predict(X.loc[test_idx])
    acc = accuracy_score(y.loc[test_idx], pred)
    say(f"TEST ACCURACY: {acc:.2%}   (goal: 35%+)")

    # What the chosen model learned: one income guess per age group.
    if columns == ["age"]:
        say("What the model learned (one income guess per age group):")
        for age in AGES:
            row = income_features(pd.DataFrame({"age": [age]}), ["age"])
            row = row.reindex(columns=X.columns, fill_value=0)
            say(f"  age {age:<6} -> income {model.predict(row)[0]}")

    # How much the score moves with the random seed of the train/test split.
    scores = []
    for seed in range(1, 11):
        tr, te = train_test_split(df.index, test_size=TEST_SIZE, random_state=seed)
        m = clone(model)
        m.fit(X.loc[tr], y.loc[tr])
        scores.append(accuracy_score(y.loc[te], m.predict(X.loc[te])))
    say(f"Same model, 10 other split seeds: min {min(scores):.2%}, "
        f"mean {statistics.mean(scores):.2%}, max {max(scores):.2%}")

    # The ceiling: how often is income one of the 3 groups next to the age group?
    age_i = df["age"].map(AGES.index)
    inc_i = df["income"].map(INCOMES.index)
    shift = ((inc_i - age_i + 1) % len(INCOMES)) - 1          # -1, 0 or +1 if "next to"
    say("Income group compared with the age group (same position in the two lists):")
    for s, label in [(-1, "one lower"), (0, "same"), (1, "one higher")]:
        say(f"  {label:<11} {(shift == s).mean():.2%}")
    say(f"  other       {(~shift.isin([-1, 0, 1])).mean():.2%}")
    say("So income = age group + a random step of -1, 0 or +1. Even a perfect model can only")
    say("guess one of the 3 steps, so the best possible accuracy is about 33.3%.")

    test = df.loc[test_idx]
    out = pd.DataFrame({"request_id": test["request_id"].values, "age": test["age"].values,
                        "gender": test["gender"].values,
                        "hour": pd.to_datetime(test["time_of_day"]).dt.hour.values,
                        "country": test["country"].values, "actual_income": test["income"].values,
                        "predicted_income": pred, "correct": test["income"].values == pred})
    save("model2_income_test_predictions.csv", out)
    return acc


def main():
    say("CS528 HW6 - models")
    say(f"Train/test split seed: {SEED}, test set = {TEST_SIZE:.0%} of the rows")
    df = load_data()
    acc1 = country_model(df)
    acc2 = income_model(df)
    say()
    say("=" * 70)
    say(f"RESULT  model 1 (IP -> country) test accuracy: {acc1:.4%}")
    say(f"RESULT  model 2 (-> income)     test accuracy: {acc2:.2%}")
    say("=" * 70)
    write_text("summary.txt", "\n".join(summary) + "\n")


if __name__ == "__main__":
    main()
