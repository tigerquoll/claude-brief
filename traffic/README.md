# traffic/ — clone & view history

GitHub's traffic stats (clones, views) are a rolling **14-day** window, visible only
to repo admins under **Insights → Traffic**. The
[`traffic` workflow](../.github/workflows/traffic.yml) snapshots them **daily** and
appends them to a dedicated **`traffic` branch**, so the history accrues indefinitely
without cluttering `main`.

The data lives on the orphan **`traffic`** branch (data only, at its root):

- **`clones.json`** / **`views.json`** — `{ "YYYY-MM-DD": { "count": N, "uniques": M } }`,
  one entry per day. `count` = total clones/views; `uniques` = distinct
  cloners/visitors — the more meaningful figure, since CI and mirrors inflate `count`.

For a clone-installed tool, **unique cloners is your best "installs" proxy.**

## Setup (one-time)

The Traffic API needs push access **and the built-in `GITHUB_TOKEN` cannot read it**,
so add a token:

1. Create a token — a **classic PAT with the `repo` scope**, or a fine-grained PAT
   with **Administration: read** on this repo.
2. Repo → **Settings → Secrets and variables → Actions → New repository secret**,
   named **`TRAFFIC_TOKEN`**.
3. Ensure Actions are enabled. The workflow runs daily and has a manual **Run
   workflow** button (Actions tab) for the first snapshot — which also creates the
   `traffic` branch.
