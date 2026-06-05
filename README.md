# bcgov-release-tracker

> A set of bash utilities to track GitHub Actions deployments and generate pending release candidate lists across BC Gov repositories.

## Overview

This toolkit consists of two scripts that work together to track GitHub Action deployments, identify where code is deployed (dev, test, or prod), and generate lists of pending release candidates (merged Pull Requests).

---

### 🛠 Prerequisites

To run these scripts, you must have the following installed on your machine:
* **GitHub CLI (`gh`)**: Must be installed and authenticated (`gh auth login`) with access to the target repositories.
* **`jq`**: A lightweight command-line JSON processor used to read version numbers.
* **`curl`**: Used to fetch files directly from GitHub.

---

### ⚙️ How It Works

#### 1. The Core Tool (`release-watch.sh`)
This is the heavy lifter. When executed, it talks to GitHub to figure out exactly what is going on with your deployments.
* **Deployment History**: It grabs the last few manual GitHub Action runs and reads their logs to determine exactly which environment (`dev`, `test`, `sandbox`, `prod`) the code was deployed to.
* **Release Candidates (`test-release`)**: If you pass the `test-release` flag, it finds the exact commit currently sitting in the `test` environment, and then prints a neat table of all Pull Requests that have been merged *after* that commit.
* **Monorepo Filtering (`--in-dirs`)**: It can check if a PR modified files in a specific directory (useful for monorepos like `business-ui`).
* **Output**: It generates both a terminal text table and a raw HTML table so you can easily copy and paste the release notes.

#### 2. The Wrapper Script (`release-output-script.sh`)
This script automates the core tool to give you a bird's-eye view of your entire project suite.
* It runs the core `release-watch.sh` tool sequentially across multiple BC Gov repositories (e.g., `lear`, `business-filings-ui`, `business-create-ui`, `business-edit-ui`, and `business-dashboard-ui`).
* After generating the release notes for all repositories, it uses `curl` and `jq` to fetch the live, current version numbers directly from the `package.json` and `version.py` files on GitHub's main branch.

---

### 🚀 Usage

To get a full report, simply run your wrapper script in the terminal:

```bash
# This will output deployment tables, PRs pending release, and current versions
./release-output-script.sh
```
If you want to use the core tool manually on a specific repository to see the last 6 runs and unreleased PRs, use:

```bash
~/Desktop/release-watch.sh 2 cd.yml bcgov/business-filings-ui test-release

```
